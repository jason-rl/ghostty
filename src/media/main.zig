//! Shared background media playback. Renderers hold immutable, reference-counted frames.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
pub const Settings = @import("Settings.zig");
const Process = @import("Process.zig");
const Cache = @import("Cache.zig");
const Http = @import("Http.zig");
const log = std.log.scoped(.background_media);
const alloc = std.heap.c_allocator;

pub const Viewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};
pub const Frame = struct {
    refs: std.atomic.Value(usize) = .init(1),
    sequence: u64,
    width: u32,
    height: u32,
    nv12: bool,
    data: []u8,
    timestamp: f64,
    pub fn retain(self: *Frame) *Frame {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *Frame) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            alloc.free(self.data);
            alloc.destroy(self);
        }
    }
};

const UpcomingArtwork = struct {
    id: []const u8,
    live_status: ?[]const u8 = null,
    thumbnail: ?[]const u8 = null,

    fn url(self: UpcomingArtwork, expected_id: []const u8) ![]const u8 {
        if (!std.mem.eql(u8, self.id, expected_id)) return error.UnexpectedYoutubeVideo;
        if (!optionalStringEql(self.live_status, "is_upcoming")) return error.StreamNotUpcoming;
        const address = self.thumbnail orelse return error.MissingArtwork;
        const uri = std.Uri.parse(address) catch return error.InvalidArtworkUrl;
        if ((!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) or
            uri.host == null or uri.host.?.isEmpty() or uri.user != null or uri.password != null or
            std.mem.indexOfAny(u8, address, "\x00\r\n") != null) return error.InvalidArtworkUrl;
        return address;
    }
};

pub const Manager = struct {
    mutex: std.Thread.Mutex = .{},
    players: std.ArrayList(*Player) = .empty,
    key: ?[]u8 = null,
    key_error: bool = false,
    sequence: std.atomic.Value(u64) = .init(0),
    revision: u64 = 0,

    pub fn deinit(self: *Manager) void {
        std.debug.assert(self.players.items.len == 0);
        self.players.deinit(alloc);
        if (self.key) |key| {
            @memset(key, 0);
            alloc.free(key);
        }
    }
    pub fn acquire(self: *Manager, settings: Settings) !?*Player {
        if (settings.source == .none) return null;
        try settings.validate();
        var identity_settings = settings;
        identity_settings.opacity = 1; // compositing does not change playback
        const serialized = try std.json.Stringify.valueAlloc(alloc, identity_settings, .{});
        defer alloc.free(serialized);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.players.items) |player| {
            if (std.mem.eql(u8, serialized, player.identity) and player.revision == (if (settings.source == .holodex) self.revision else 0)) {
                player.users += 1;
                return player;
            }
        }
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const parsed = try std.json.parseFromSlice(Settings, arena.allocator(), serialized, .{ .allocate = .alloc_always });
        const player = try alloc.create(Player);
        errdefer alloc.destroy(player);
        var key: ?[]const u8 = null;
        if (settings.source == .holodex) {
            if (self.key_error) return error.HolodexCredentialStoreUnavailable;
            key = if (self.key) |value| try arena.allocator().dupe(u8, value) else std.process.getEnvVarOwned(arena.allocator(), "HOLODEX_API_KEY") catch null;
        }
        const identity = try arena.allocator().dupe(u8, serialized);
        player.* = .{
            .arena = arena,
            .settings = parsed.value,
            .identity = identity,
            .revision = if (settings.source == .holodex) self.revision else 0,
            .key = key,
            .manager = self,
        };
        try self.players.append(alloc, player);
        errdefer _ = self.players.pop();
        player.thread = try std.Thread.spawn(.{}, Player.run, .{player});
        return player;
    }
    pub fn release(self: *Manager, player: *Player) void {
        self.mutex.lock();
        player.users -= 1;
        if (player.users != 0) {
            self.mutex.unlock();
            return;
        }
        for (self.players.items, 0..) |p, i| if (p == player) {
            _ = self.players.swapRemove(i);
            break;
        };
        self.mutex.unlock();
        player.stop.store(true, .release);
        if (player.thread) |thread| thread.join();
        if (player.frame) |frame| frame.release();
        if (player.key) |key| @memset(@constCast(key), 0);
        player.viewports.deinit(alloc);
        player.arena.deinit();
        alloc.destroy(player);
    }
    /// Frontends resolve the native credential store asynchronously, then reload config.
    pub fn setKey(self: *Manager, key: ?[]const u8, failed: bool) !void {
        const copy = if (key) |k| try alloc.dupe(u8, try validateKey(k)) else null;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.key) |old| {
            @memset(old, 0);
            alloc.free(old);
        }
        self.key = copy;
        self.key_error = failed;
        self.revision +%= 1;
    }
};

pub fn validateKey(key: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, key, " \r\n\t");
    if (value.len == 0 or value.len > 4096) return error.InvalidHolodexKey;
    for (value) |c| if (c < 33 or c > 126) return error.InvalidHolodexKey;
    return value;
}

pub const Player = struct {
    arena: std.heap.ArenaAllocator,
    settings: Settings,
    identity: []const u8,
    revision: u64,
    key: ?[]const u8,
    manager: *Manager,
    users: usize = 1,
    mutex: std.Thread.Mutex = .{},
    frame: ?*Frame = null,
    failure: ?anyerror = null,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    viewports: std.AutoHashMapUnmanaged(usize, struct { viewport: Viewport, seen: i64 }) = .{},
    sequence: u64 = 0,

    pub fn snapshot(self: *Player) ?*Frame {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.frame) |frame| frame.retain() else null;
    }
    pub fn getError(self: *Player) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failure;
    }
    pub fn viewport(self: *Player, id: usize, value: Viewport) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.viewports.put(alloc, id, .{ .viewport = value, .seen = std.time.milliTimestamp() }) catch {};
    }
    pub fn removeViewport(self: *Player, id: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.viewports.remove(id);
    }
    fn target(self: *Player, width: u32, height: u32) u32 {
        if (self.settings.max_height) |limit| return limit;
        self.mutex.lock();
        defer self.mutex.unlock();
        var result: u32 = 0;
        var it = self.viewports.valueIterator();
        while (it.next()) |v| {
            if (std.time.milliTimestamp() - v.seen > 2000) continue;
            result = @max(result, Settings.desiredHeight(@intFromFloat(@max(1, v.viewport.width)), @intFromFloat(@max(1, v.viewport.height)), width, height, self.settings.fit));
        }
        return if (result == 0) 720 else result;
    }
    fn publish(self: *Player, frame: *Frame, clear_failure: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.frame) |old| old.release();
        if (frame.sequence == 0) frame.sequence = self.manager.sequence.fetchAdd(1, .monotonic) +% 1;
        self.frame = frame;
        if (clear_failure) self.failure = null;
    }
    fn run(self: *Player) void {
        lowerPriority();
        if (self.settings.source == .image) {
            while (!self.stop.load(.acquire)) {
                self.image() catch |err| {
                    self.recordFailure(err);
                    for (0..100) |_| {
                        if (self.stop.load(.acquire)) return;
                        std.Thread.sleep(100 * std.time.ns_per_ms);
                    }
                    continue;
                };
                return;
            }
            return;
        }
        self.play() catch |err| self.recordFailure(err);
    }
    fn recordFailure(self: *Player, err: anyerror) void {
        if (err == error.MediaCancelled or err == error.BroadcastUnchanged) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failure = err;
        log.warn("playback failed: {s}", .{@errorName(err)});
    }
    fn play(self: *Player) !void {
        var current: ?*Pipeline = null;
        defer if (current) |pipeline| pipeline.destroy();
        var candidate: ?*Pipeline = try Pipeline.start(self, self.target(16, 9), null, null, false, false);
        defer if (candidate) |pipeline| pipeline.destroy();
        var artwork: ?*Artwork = null;
        defer if (artwork) |task| task.destroy();
        var artwork_loaded = false;
        var artwork_retry_at: i64 = 0;
        var playback_started = false;
        var epoch: ?std.time.Instant = null;
        var retry_at: i64 = 0;
        var next_poll = std.time.milliTimestamp() + 60000;
        var observed_target: u32 = self.target(16, 9);
        var changed_at: i64 = std.time.milliTimestamp();
        while (!self.stop.load(.acquire)) {
            const now = std.time.milliTimestamp();
            if (candidate) |pipeline| {
                if (pipeline.snapshot()) |frame| {
                    // A late cover must never replace a decoded livestream frame.
                    playback_started = true;
                    if (artwork) |task| task.destroy();
                    artwork = null;
                    if (epoch == null or !optionalStringEql(pipeline.live_id, if (current) |old| old.live_id else null))
                        epoch = try std.time.Instant.now();
                    if (current) |old| old.destroy();
                    current = pipeline;
                    candidate = null;
                    self.publish(frame, true);
                    next_poll = now + 60000;
                } else if (pipeline.done.load(.acquire)) {
                    if (pipeline.failure) |err| self.recordFailure(err);
                    if (!pipeline.prepared and !playback_started and current == null and
                        self.settings.source == .@"youtube-live" and artwork == null and
                        !artwork_loaded and now >= artwork_retry_at)
                    {
                        artwork_retry_at = now + 60000;
                        artwork = Artwork.start(self) catch null;
                    }
                    pipeline.destroy();
                    candidate = null;
                    retry_at = now + 10000;
                    next_poll = now + 60000;
                }
            }
            if (current) |pipeline| {
                if (pipeline.snapshot()) |frame| {
                    self.mutex.lock();
                    const same = if (self.frame) |old| old.sequence == frame.sequence else false;
                    self.mutex.unlock();
                    if (same) frame.release() else self.publish(frame, true);
                }
                if (pipeline.done.load(.acquire) and candidate == null) {
                    if (pipeline.failure) |err| self.recordFailure(err);
                    pipeline.destroy();
                    current = null;
                    retry_at = now + 1000;
                }
            }
            if (candidate == null and now >= retry_at) {
                if (current) |pipeline| {
                    const desired = self.target(pipeline.width, pipeline.height);
                    if (desired != observed_target) {
                        observed_target = desired;
                        changed_at = now;
                    }
                    const resizing = desired != pipeline.target_height and
                        now - changed_at >= (if (desired > pipeline.target_height) @as(i64, 500) else 5000);
                    const polling = self.settings.source == .holodex and now >= next_poll;
                    const cached = pipeline.cache_ready.load(.acquire);
                    if (resizing or polling or cached) candidate = try Pipeline.start(self, desired, epoch, pipeline.live_id, polling and !resizing, resizing and desired > pipeline.target_height);
                } else candidate = try Pipeline.start(self, observed_target, epoch, null, false, false);
            }
            if (artwork) |task| {
                if (task.done.load(.acquire)) {
                    if (task.frame) |frame| {
                        self.publish(frame.retain(), false);
                        artwork_loaded = true;
                    }
                    task.destroy();
                    artwork = null;
                }
            }
            std.Thread.sleep(16 * std.time.ns_per_ms);
        }
    }

    /// Optional artwork runs independently of playback retries. The controller
    /// alone publishes its result, preserving the original playback diagnostic.
    const Artwork = struct {
        owner: *Player,
        stop: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,
        frame: ?*Frame = null,

        fn start(owner: *Player) !*Artwork {
            const self = try alloc.create(Artwork);
            errdefer alloc.destroy(self);
            self.* = .{ .owner = owner };
            self.thread = try std.Thread.spawn(.{}, worker, .{self});
            return self;
        }
        fn destroy(self: *Artwork) void {
            self.stop.store(true, .release);
            self.thread.?.join();
            if (self.frame) |frame| frame.release();
            alloc.destroy(self);
        }
        fn worker(self: *Artwork) void {
            lowerPriority();
            defer self.done.store(true, .release);
            self.frame = self.work() catch |err| {
                if (err != error.MediaCancelled) log.debug("livestream artwork unavailable: {s}", .{@errorName(err)});
                return;
            };
        }
        fn work(self: *Artwork) !*Frame {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const a = arena.allocator();
            const settings = self.owner.settings;
            const id = try Settings.youtubeID(settings.url);
            const url = try std.fmt.allocPrint(a, "https://www.youtube.com/watch?v={s}", .{id});
            const output = try Process.output(a, &.{ settings.yt_dlp, "--ignore-config", "--no-cache-dir", "--no-playlist", "--no-warnings", "--ignore-no-formats-error", "--skip-download", "--print", "%(.{id,live_status,thumbnail})j", "--", url }, &self.stop);
            const metadata = try std.json.parseFromSlice(UpcomingArtwork, a, output, .{ .ignore_unknown_fields = true });
            const bytes = try Http.artwork(a, try metadata.value.url(id), &self.stop);
            if (self.stop.load(.acquire)) return error.MediaCancelled;
            return imageFrame(bytes);
        }
    };

    /// A candidate owns its subprocesses and keeps at most one decoded frame.
    /// The controller swaps it in only after it has a frame, keeping the current
    /// decoder running during resolution changes and Holodex lookups.
    const Pipeline = struct {
        owner: *Player,
        thread: ?std.Thread = null,
        stop: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        cache_ready: std.atomic.Value(bool) = .init(false),
        mutex: std.Thread.Mutex = .{},
        frame: ?*Frame = null,
        failure: ?anyerror = null,
        prepared: bool = false,
        arena: std.heap.ArenaAllocator,
        target_height: u32,
        epoch: ?std.time.Instant,
        previous_live: ?[]const u8,
        poll_only: bool,
        force_resolve: bool,
        live_id: ?[]const u8 = null,
        width: u32 = 16,
        height: u32 = 9,

        fn start(owner: *Player, height: u32, epoch: ?std.time.Instant, previous: ?[]const u8, poll_only: bool, force_resolve: bool) !*Pipeline {
            const self = try alloc.create(Pipeline);
            errdefer alloc.destroy(self);
            self.* = .{ .owner = owner, .arena = std.heap.ArenaAllocator.init(alloc), .target_height = height, .epoch = epoch, .previous_live = null, .poll_only = poll_only, .force_resolve = force_resolve };
            errdefer self.arena.deinit();
            if (previous) |id| self.previous_live = try self.arena.allocator().dupe(u8, id);
            self.thread = try std.Thread.spawn(.{}, worker, .{self});
            return self;
        }
        fn destroy(self: *Pipeline) void {
            self.stop.store(true, .release);
            self.thread.?.join();
            if (self.frame) |frame| frame.release();
            self.arena.deinit();
            alloc.destroy(self);
        }
        fn snapshot(self: *Pipeline) ?*Frame {
            self.mutex.lock();
            defer self.mutex.unlock();
            return if (self.frame) |frame| frame.retain() else null;
        }
        fn publish(self: *Pipeline, frame: *Frame) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.frame) |old| old.release();
            frame.sequence = self.owner.manager.sequence.fetchAdd(1, .monotonic) +% 1;
            self.frame = frame;
        }
        fn worker(self: *Pipeline) void {
            lowerPriority();
            defer self.done.store(true, .release);
            self.work() catch |err| {
                self.failure = err;
            };
        }
        fn work(self: *Pipeline) !void {
            const owner = self.owner;
            const a = self.arena.allocator();
            const path = if (owner.settings.source == .video or owner.settings.source == .gif)
                try expandPath(a, owner.settings.path)
            else
                owner.settings.url;
            var cache: Cache = if (owner.settings.source == .video or owner.settings.source == .gif)
                .{ .alloc = alloc, .root = try alloc.dupe(u8, ""), .budget = 0 }
            else
                try Cache.init(alloc, owner.settings.cache_size_mb * 1024 * 1024);
            defer cache.deinit();
            var entry: ?Cache.Entry = null;
            defer if (entry) |e| e.deinit();
            var download: ?*Download = null;
            defer if (download) |d| d.destroy();
            var prepared = try owner.prepare(a, &cache, path, &entry, self, &download);
            self.prepared = true;
            self.width = prepared.width;
            self.height = prepared.height;
            const position = if (self.epoch) |epoch| @as(f64, @floatFromInt((try std.time.Instant.now()).since(epoch))) / std.time.ns_per_s else 0;
            owner.decode(prepared, position, self) catch |err| {
                if (owner.settings.hardware_acceleration != .auto or prepared.alpha or err == error.MediaCancelled) return err;
                prepared.software = true;
                const retry_position = if (self.epoch) |epoch| @as(f64, @floatFromInt((try std.time.Instant.now()).since(epoch))) / std.time.ns_per_s else 0;
                try owner.decode(prepared, retry_position, self);
            };
        }
    };

    /// Streaming starts immediately from the selected video-only URL while a
    /// cancellable downloader fills the leased rendition for offline loops.
    const Download = struct {
        owner: *Player,
        cache: *Cache,
        entry: Cache.Entry,
        url: []const u8,
        record: Cache.Record,
        ready: *std.atomic.Value(bool),
        stop: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,
        fn destroy(self: *Download) void {
            self.stop.store(true, .release);
            self.thread.?.join();
            alloc.destroy(self);
        }
        fn worker(self: *Download) void {
            lowerPriority();
            self.work() catch |err| {
                if (err != error.MediaCancelled) log.warn("media cache download failed: {s}", .{@errorName(err)});
            };
        }
        fn work(self: *Download) !void {
            var process = try Process.init(alloc, &.{ self.owner.settings.yt_dlp, "--ignore-config", "--no-cache-dir", "--no-playlist", "--no-warnings", "--no-progress", "--no-part", "-f", self.record.format, "-o", "-", "--", self.url }, &self.stop);
            defer process.deinit();
            var file = try std.fs.cwd().createFile(self.entry.path, .{});
            defer file.close();
            var committed = false;
            defer if (!committed) std.fs.cwd().deleteFile(self.entry.path) catch {};
            var buffer: [65536]u8 = undefined;
            var bytes: u64 = 0;
            while (true) {
                const n = try process.read(&buffer, std.time.milliTimestamp() + 45000);
                if (n == 0) break;
                try self.cache.append(file, buffer[0..n]);
                bytes += n;
            }
            const term = try process.wait();
            if (term != .Exited or term.Exited != 0 or bytes == 0) return error.YoutubeDownloadFailed;
            try file.sync();
            self.record.bytes = bytes;
            try self.cache.commit(self.entry, self.record);
            committed = true;
            try self.entry.lease.lock(.shared);
            self.ready.store(true, .release);
        }
    };

    const Prepared = struct {
        input: []const u8,
        width: u32,
        height: u32,
        duration: f64 = 0,
        live: bool = false,
        alpha: bool = false,
        software: bool = false,
        headers: []const u8 = "",
        target: u32 = 720,
    };
    fn prepare(self: *Player, a: Allocator, cache: *Cache, path: []const u8, entry: *?Cache.Entry, pipeline: *Pipeline, download: *?*Download) !Prepared {
        if (self.settings.source == .video or self.settings.source == .gif) return self.probe(a, path, pipeline);
        var url = path;
        if (self.settings.source == .holodex) {
            const id = try self.holodex(a, pipeline.previous_live, &pipeline.stop) orelse return error.NoHolodexBroadcast;
            pipeline.live_id = id;
            if (pipeline.poll_only and optionalStringEql(pipeline.previous_live, id)) return error.BroadcastUnchanged;
            if (!optionalStringEql(pipeline.previous_live, id)) pipeline.epoch = null;
            url = try std.fmt.allocPrint(a, "https://www.youtube.com/watch?v={s}", .{id});
        }
        const id = try Settings.youtubeID(url);
        const target_height = pipeline.target_height;
        if (self.settings.source == .@"youtube-video") {
            if (try cache.find(id, target_height)) |hit| {
                if (!pipeline.force_resolve or hit.record.height >= target_height) {
                    entry.* = hit.entry;
                    return .{ .input = hit.entry.path, .width = hit.record.width, .height = hit.record.height, .duration = hit.record.duration, .target = target_height };
                }
                // A growing viewport may need a rendition above the cached
                // resolution. The current player keeps using its leased file
                // while this candidate resolves/downloads the larger format.
                hit.entry.deinit();
            }
        }
        const selector = try std.fmt.allocPrint(a, "bestvideo[height<={d}]/worstvideo", .{target_height});
        const output = try Process.output(a, &.{ self.settings.yt_dlp, "--ignore-config", "--no-cache-dir", "--no-playlist", "--no-warnings", "--skip-download", "--dump-json", "-f", selector, "--", url }, &pipeline.stop);
        const metadata = try std.json.parseFromSlice(std.json.Value, a, output, .{});
        if (metadata.value != .object) return error.InvalidYoutubeMetadata;
        const obj = metadata.value.object;
        const input = obj.get("url") orelse return error.MissingYoutubeStream;
        if (input != .string or !std.mem.startsWith(u8, input.string, "https://")) return error.InvalidYoutubeStream;
        const live = self.settings.source != .@"youtube-video";
        const is_live = if (obj.get("is_live")) |value| value == .bool and value.bool else false;
        if (live != is_live) return error.YoutubeSourceMismatch;
        var result: Prepared = .{
            .input = input.string,
            .width = try jsonDimension(obj.get("width")),
            .height = try jsonDimension(obj.get("height")),
            .duration = jsonFloat(obj.get("duration")) orelse 0,
            .live = live,
            .target = target_height,
        };
        if (obj.get("http_headers")) |headers| {
            if (headers != .object) return error.InvalidYoutubeHeaders;
            var list: std.ArrayList(u8) = .empty;
            var it = headers.object.iterator();
            while (it.next()) |header| {
                if (header.value_ptr.* != .string) return error.InvalidYoutubeHeaders;
                if (std.mem.indexOfAny(u8, header.key_ptr.*, "\r\n") != null or std.mem.indexOfAny(u8, header.value_ptr.string, "\r\n") != null)
                    return error.InvalidYoutubeHeaders;
                try list.appendSlice(a, try std.fmt.allocPrint(a, "{s}: {s}\r\n", .{ header.key_ptr.*, header.value_ptr.string }));
            }
            result.headers = list.items;
        }
        if (!live) {
            const format_value = obj.get("format_id") orelse return error.MissingYoutubeFormat;
            if (format_value != .string) return error.MissingYoutubeFormat;
            const format = format_value.string;
            entry.* = cache.acquire(id, format) catch |err| switch (err) {
                error.RenditionInUse => null,
                else => return err,
            };
            if (entry.*) |e| {
                if (try cache.complete(e)) {
                    result.input = e.path;
                    result.headers = "";
                } else {
                    const d = try alloc.create(Download);
                    errdefer alloc.destroy(d);
                    d.* = .{ .owner = self, .cache = cache, .entry = e, .url = url, .ready = &pipeline.cache_ready, .record = .{ .video = id, .format = format, .width = result.width, .height = result.height, .duration = result.duration } };
                    d.thread = try std.Thread.spawn(.{}, Download.worker, .{d});
                    download.* = d;
                }
            }
        }
        return result;
    }
    fn probe(self: *Player, a: Allocator, path: []const u8, pipeline: *Pipeline) !Prepared {
        const output = try Process.output(a, &.{ self.settings.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height,pix_fmt:format=duration", "-of", "json", path }, &pipeline.stop);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, output, .{});
        if (parsed.value != .object) return error.NoVideoStream;
        const stream_value = parsed.value.object.get("streams") orelse return error.NoVideoStream;
        if (stream_value != .array) return error.NoVideoStream;
        const streams = stream_value.array.items;
        if (streams.len == 0) return error.NoVideoStream;
        if (streams[0] != .object) return error.NoVideoStream;
        const stream = streams[0].object;
        const width: u32 = try jsonDimension(stream.get("width"));
        const height: u32 = try jsonDimension(stream.get("height"));
        if (width == 0 or height == 0 or width > 32768 or height > 32768) return error.InvalidVideoDimensions;
        const format = parsed.value.object.get("format");
        return .{ .input = path, .width = width, .height = height, .duration = if (format) |f| if (f == .object) jsonFloat(f.object.get("duration")) orelse 0 else 0 else 0, .alpha = self.settings.source == .gif, .target = pipeline.target_height };
    }
    fn decode(self: *Player, prepared: Prepared, position: f64, pipeline: *Pipeline) !void {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const height = @max(2, @min(prepared.height, prepared.target) / 2 * 2);
        const width = @max(2, @as(u32, @intFromFloat(@as(f64, @floatFromInt(prepared.width)) * @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(prepared.height)))) / 2 * 2);
        const bytes = @as(usize, width) * height * (if (prepared.alpha) @as(usize, 4) else 3) / (if (prepared.alpha) @as(usize, 1) else 2);
        if (bytes > 32 * 1024 * 1024) return error.MediaFrameTooLarge;
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(a, &.{ self.settings.ffmpeg, "-hide_banner", "-nostdin", "-loglevel", "error", "-threads", "2", "-filter_threads", "1" });
        if (!prepared.software and !prepared.alpha and self.settings.hardware_acceleration == .auto) try args.appendSlice(a, &.{ "-hwaccel", "auto" });
        if (!prepared.live) {
            const seek = if (prepared.duration > 0) @mod(position, prepared.duration) else position;
            try args.appendSlice(a, &.{ "-readrate", "1", "-readrate_initial_burst", "2", "-stream_loop", "-1", "-ss", try std.fmt.allocPrint(a, "{d:.6}", .{seek}) });
        } else try args.appendSlice(a, &.{ "-rw_timeout", "15000000" });
        if (prepared.headers.len != 0) try args.appendSlice(a, &.{ "-headers", prepared.headers });
        const filter = try std.fmt.allocPrint(a, "fps={d},scale={d}:{d}:out_color_matrix=bt709:out_range=full,format={s}", .{ self.settings.max_fps, width, height, if (prepared.alpha) "rgba" else "nv12" });
        try args.appendSlice(a, &.{ "-i", prepared.input, "-map", "0:v:0", "-an", "-sn", "-dn", "-vf", filter, "-f", "rawvideo", "pipe:1" });
        var process = try Process.init(alloc, args.items, &pipeline.stop);
        defer process.deinit();
        var clock = try std.time.Timer.start();
        var frame_index: u64 = 0;

        while (!pipeline.stop.load(.acquire)) {
            const data = try alloc.alloc(u8, bytes);
            var owned = true;
            errdefer if (owned) alloc.free(data);
            var read: usize = 0;
            while (read < bytes) {
                const n = try process.read(data[read..], std.time.milliTimestamp() + 15000);
                if (n == 0) return error.MediaDecoderStopped;
                read += n;
            }
            const timestamp = @as(f64, @floatFromInt(frame_index)) / @as(f64, @floatFromInt(self.settings.max_fps));
            if (frame_index == 0) clock.reset();
            frame_index += 1;
            // FFmpeg's initial burst is bounded by this presentation clock, independent of UI focus.
            while ((if (pipeline.epoch) |epoch| @as(f64, @floatFromInt((try std.time.Instant.now()).since(epoch))) / std.time.ns_per_s - position else @as(f64, @floatFromInt(clock.read())) / std.time.ns_per_s) < timestamp) {
                if (pipeline.stop.load(.acquire)) return error.MediaCancelled;
                std.Thread.sleep(2 * std.time.ns_per_ms);
            }
            if (pipeline.epoch) |epoch| {
                const elapsed = @as(f64, @floatFromInt((try std.time.Instant.now()).since(epoch))) / std.time.ns_per_s;
                if (!prepared.live and position + timestamp + 2.0 / @as(f64, @floatFromInt(self.settings.max_fps)) < elapsed) {
                    alloc.free(data);
                    continue;
                }
            }
            const frame = try alloc.create(Frame);
            frame.* = .{ .sequence = 0, .width = width, .height = height, .nv12 = !prepared.alpha, .data = data, .timestamp = position + timestamp };
            pipeline.publish(frame);
            owned = false;
        }
    }
    fn image(self: *Player) !void {
        const path = try expandPath(alloc, self.settings.path);
        defer alloc.free(path);
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(alloc, 64 * 1024 * 1024);
        defer alloc.free(bytes);
        self.publish(try imageFrame(bytes), true);
    }
    fn holodex(self: *Player, a: Allocator, current: ?[]const u8, stop: *const std.atomic.Value(bool)) !?[]const u8 {
        const key = try validateKey(self.key orelse return error.HolodexKeyRequired);
        const buffer = try Http.holodex(a, key, stop);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, buffer, .{});
        if (parsed.value != .array) return error.InvalidHolodexResponse;
        var selected: ?[]const u8 = null;
        for (self.settings.channels) |channel| {
            var latest: []const u8 = "";
            var candidate: ?[]const u8 = null;
            for (parsed.value.array.items) |item| {
                if (item != .object) continue;
                const obj = item.object;
                if (!std.mem.eql(u8, jsonString(obj.get("status")) orelse continue, "live")) continue;
                const channel_value = obj.get("channel") orelse continue;
                if (channel_value != .object) continue;
                if (!std.mem.eql(u8, jsonString(channel_value.object.get("id")) orelse continue, channel)) continue;
                const id = jsonString(obj.get("id")) orelse continue;
                if (id.len != 11) continue;
                var valid_id = true;
                for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                    valid_id = false;
                    break;
                };
                if (!valid_id) continue;
                if (current) |old| if (std.mem.eql(u8, old, id)) return id;
                const start = if (obj.get("start_actual")) |v| if (v == .string) v.string else "" else "";
                if (candidate == null or std.mem.order(u8, start, latest) == .gt) {
                    candidate = id;
                    latest = start;
                }
            }
            if (selected == null) selected = candidate;
        }
        return selected;
    }
};

/// Still images and livestream covers use the same bounded RGBA upload path.
fn imageFrame(bytes: []const u8) !*Frame {
    const wuffs = @import("wuffs");
    const decoded = if (std.mem.startsWith(u8, bytes, "\x89PNG")) try wuffs.png.decodeWithLimit(alloc, bytes, 64 * 1024 * 1024) else try wuffs.jpeg.decodeWithLimit(alloc, bytes, 64 * 1024 * 1024);
    errdefer alloc.free(decoded.data);
    if (decoded.width == 0 or decoded.height == 0) return error.InvalidImageDimensions;
    const frame = try alloc.create(Frame);
    frame.* = .{ .sequence = 0, .width = decoded.width, .height = decoded.height, .nv12 = false, .data = decoded.data, .timestamp = 0 };
    return frame;
}

pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound, error.AccessDenied => "Background media could not open the file or decoder. Check the path and install ffmpeg, ffprobe, and yt-dlp for video sources.",
        error.HolodexKeyRequired => "Set your Holodex API key using the command palette, or provide HOLODEX_API_KEY in Ghostty's environment.",
        error.HolodexCredentialStoreUnavailable, error.InvalidHolodexKey => "Unlock the system credential store and use Set Holodex API Key in the command palette to retry.",
        error.NoHolodexBroadcast => "None of the configured Holodex channels is live. Ghostty will keep checking.",
        error.HolodexRequestFailed, error.CurlUnavailable => "The Holodex request failed. Check the network, API key, and system libcurl installation.",
        error.MediaCacheFull => "The background media cache is full and all remaining entries are in use. Increase background-media-cache-size-mb or close other players.",
        error.YoutubeSourceMismatch => "Use youtube-video for recorded videos and youtube-live for a currently live broadcast.",
        else => "Background media playback failed. Check the media configuration, external tools, and Ghostty logs. Playback will retry automatically.",
    };
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |value| return if (b) |other| std.mem.eql(u8, value, other) else false;
    return b == null;
}

fn expandPath(a: Allocator, path: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = try std.process.getEnvVarOwned(a, "HOME");
        defer a.free(home);
        return std.fs.path.join(a, &.{ home, path[2..] });
    }
    return a.dupe(u8, path);
}
fn jsonDimension(value: ?std.json.Value) !u32 {
    const n = jsonInt(value) orelse return error.InvalidVideoDimensions;
    if (n < 1 or n > 32768) return error.InvalidVideoDimensions;
    return @intCast(n);
}
fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}
fn jsonInt(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return if (v == .integer) v.integer else null;
}
fn jsonFloat(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .float => v.float,
        .integer => @floatFromInt(v.integer),
        .string => std.fmt.parseFloat(f64, v.string) catch null,
        else => null,
    };
}
fn lowerPriority() void {
    if (builtin.os.tag == .macos) {
        const C = struct {
            extern "c" fn pthread_set_qos_class_self_np(c_uint, c_int) c_int;
        };
        _ = C.pthread_set_qos_class_self_np(0x09, 0);
    } else if (builtin.os.tag == .linux) {
        const C = struct {
            extern "c" fn nice(c_int) c_int;
        };
        _ = C.nice(10);
    }
}

test "background media key validation" {
    try std.testing.expectEqualStrings("key", try validateKey(" key \n"));
    try std.testing.expectError(error.InvalidHolodexKey, validateKey("secret\r\nheader"));
}
test {
    _ = Settings;
    _ = Cache;
    _ = Http;
}

test "livestream artwork requires a matching scheduled stream and HTTP image" {
    var metadata: UpcomingArtwork = .{ .id = "abcdefghijk", .live_status = "is_upcoming", .thumbnail = "https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg" };
    _ = try metadata.url("abcdefghijk");
    try std.testing.expectError(error.UnexpectedYoutubeVideo, metadata.url("otherstream"));
    for ([_]?[]const u8{ null, "is_live", "was_live", "not_live" }) |status| {
        metadata.live_status = status;
        try std.testing.expectError(error.StreamNotUpcoming, metadata.url("abcdefghijk"));
    }
    metadata.live_status = "is_upcoming";
    for ([_][]const u8{ "file:///private/cover.jpg", "https:///cover.jpg", "https://user:secret@example.com/cover.jpg", "https://example.com/cover\x00.jpg" }) |url| {
        metadata.thumbnail = url;
        try std.testing.expectError(error.InvalidArtworkUrl, metadata.url("abcdefghijk"));
    }
    metadata.thumbnail = null;
    try std.testing.expectError(error.MissingArtwork, metadata.url("abcdefghijk"));
}

test "livestream cover preserves playback errors and yields to live frames" {
    const downloader = std.process.getEnvVarOwned(alloc, "GHOSTTY_MEDIA_TEST_ARTWORK_YT_DLP") catch return error.SkipZigTest;
    defer alloc.free(downloader);
    const root = try std.process.getEnvVarOwned(alloc, "GHOSTTY_MEDIA_TEST_ARTWORK_ROOT");
    defer alloc.free(root);
    const decoder = try std.process.getEnvVarOwned(alloc, "GHOSTTY_MEDIA_TEST_FFMPEG");
    defer alloc.free(decoder);
    var directory = try std.fs.cwd().openDir(root, .{});
    defer directory.close();
    var manager: Manager = .{};
    defer manager.deinit();
    const player = (try manager.acquire(.{
        .source = .@"youtube-live",
        .url = "https://youtu.be/abcdefghijk",
        .yt_dlp = downloader,
        .ffmpeg = decoder,
        .max_height = 180,
        .hardware_acceleration = .off,
    })).?;
    defer manager.release(player);
    const deadline = std.time.milliTimestamp() + 16000;
    var cover_sequence: u64 = 0;
    var live_sequence: u64 = 0;
    while (std.time.milliTimestamp() < deadline) {
        if (player.snapshot()) |frame| {
            defer frame.release();
            if (frame.nv12) {
                try std.testing.expect(cover_sequence != 0);
                try std.testing.expect(player.getError() == null);
                live_sequence = frame.sequence;
                break;
            }
            try std.testing.expectEqual(@as(u32, 32), frame.width);
            try std.testing.expectEqual(@as(u32, 32), frame.height);
            try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, frame.data[0..4]);
            try std.testing.expectEqual(error.MediaProcessFailed, player.getError().?);
            if (cover_sequence == 0) {
                cover_sequence = frame.sequence;
                const marker = try directory.createFile("live", .{});
                marker.close();
            } else try std.testing.expectEqual(cover_sequence, frame.sequence);
        } else try std.testing.expectEqual(@as(u64, 0), cover_sequence);
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(live_sequence > cover_sequence and cover_sequence != 0);
    var requests = try directory.openFile("cover-requests", .{});
    defer requests.close();
    try std.testing.expectEqual(@as(u64, 1), (try requests.stat()).size);
    var calls = try directory.openFile("artwork-calls", .{});
    defer calls.close();
    try std.testing.expectEqual(@as(u64, 1), (try calls.stat()).size);
}

test "background media shares players and shuts down failing processes" {
    var manager: Manager = .{};
    defer manager.deinit();
    const settings: Settings = .{ .source = .video, .path = "/nonexistent/media.mp4", .ffprobe = "/nonexistent/ffprobe" };
    const first = (try manager.acquire(settings)).?;
    const second = (try manager.acquire(settings)).?;
    try std.testing.expectEqual(first, second);
    first.viewport(1, .{ .width = 1920, .height = 1080 });
    try std.testing.expectEqual(@as(u32, 1080), first.target(1920, 1080));
    first.removeViewport(1);
    manager.release(first);
    manager.release(second);
}

// Run with a short video supplied by dist/fork/test-media.sh. Ordinary unit
// tests do not depend on installed external tools or the network.
test "background media real decoder loops and resizes without freezing" {
    const fixture = std.process.getEnvVarOwned(alloc, "GHOSTTY_MEDIA_TEST_VIDEO") catch return error.SkipZigTest;
    defer alloc.free(fixture);
    var manager: Manager = .{};
    defer manager.deinit();
    const player = (try manager.acquire(.{ .source = .video, .path = fixture, .max_fps = 15, .hardware_acceleration = .off })).?;
    defer manager.release(player);
    const start = std.time.milliTimestamp();
    var first_sequence: u64 = 0;
    var last_sequence: u64 = 0;
    var saw_small = false;
    var saw_large = false;
    var last_change = start;
    while (std.time.milliTimestamp() - start < 12000) {
        const elapsed = std.time.milliTimestamp() - start;
        const height: f32 = if (elapsed < 6500) 64 else 180;
        player.viewport(1, .{ .width = height * 16 / 9, .height = height });
        if (player.snapshot()) |frame| {
            defer frame.release();
            if (first_sequence == 0) first_sequence = frame.sequence;
            if (frame.sequence != last_sequence) {
                last_change = std.time.milliTimestamp();
                last_sequence = frame.sequence;
            }
            if (frame.height <= 64) saw_small = true;
            if (saw_small and frame.height == 180) saw_large = true;
            try std.testing.expect(frame.nv12);
            try std.testing.expectEqual(@as(usize, frame.width) * frame.height * 3 / 2, frame.data.len);
            // The fixture lasts one second. This verifies continuous looping.
            if (saw_large and frame.timestamp > 7) break;
        }
        if (last_sequence != 0) try std.testing.expect(std.time.milliTimestamp() - last_change < 2000);
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(first_sequence != 0 and last_sequence > first_sequence);
    try std.testing.expect(saw_small and saw_large);
}

test "background media switches streamed video to cache and reopens offline" {
    const downloader = std.process.getEnvVarOwned(alloc, "GHOSTTY_MEDIA_TEST_YT_DLP") catch return error.SkipZigTest;
    defer alloc.free(downloader);
    const decoder = try std.process.getEnvVarOwned(alloc, "GHOSTTY_MEDIA_TEST_FFMPEG");
    defer alloc.free(decoder);
    const root = try std.process.getEnvVarOwned(alloc, "GHOSTTY_MEDIA_TEST_CACHE");
    defer alloc.free(root);
    const calls_path = try std.fs.path.join(alloc, &.{ root, "metadata-calls" });
    defer alloc.free(calls_path);
    const cached_playback = try std.fs.path.join(alloc, &.{ root, "cached-playback" });
    defer alloc.free(cached_playback);
    var manager: Manager = .{};
    defer manager.deinit();
    const settings: Settings = .{
        .source = .@"youtube-video",
        .url = "https://youtu.be/abcdefghijk",
        .yt_dlp = downloader,
        .ffmpeg = decoder,
        .max_height = 180,
        .hardware_acceleration = .off,
    };
    for (0..2) |_| {
        const player = (try manager.acquire(settings)).?;
        defer manager.release(player);
        const deadline = std.time.milliTimestamp() + 6000;
        var saw_frame = false;
        while (std.time.milliTimestamp() < deadline) {
            if (player.snapshot()) |frame| {
                frame.release();
                saw_frame = true;
            }
            if (saw_frame) {
                if (std.fs.cwd().access(cached_playback, .{})) |_| break else |_| {}
            }
            std.Thread.sleep(25 * std.time.ns_per_ms);
        }
        try std.testing.expect(saw_frame);
        try std.fs.cwd().access(cached_playback, .{});
    }
    var calls = try std.fs.cwd().openFile(calls_path, .{});
    defer calls.close();
    // The second player, and the candidate that switched to cache, never
    // needed the resolver. Both used the completed leased rendition.
    try std.testing.expectEqual(@as(u64, 1), (try calls.stat()).size);
}
