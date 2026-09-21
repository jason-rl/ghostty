//! Persistent rendition cache. File leases protect active entries across processes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Self = @This();
root: []const u8,
budget: u64,
alloc: Allocator,

pub const Record = struct {
    video: []const u8,
    format: []const u8,
    width: u32,
    height: u32,
    duration: f64 = 0,
    bytes: u64 = 0,
};
pub const Entry = struct {
    path: []u8,
    lease: std.fs.File,
    alloc: Allocator,
    pub fn deinit(self: Entry) void {
        self.lease.close();
        self.alloc.free(self.path);
    }
};

pub fn init(alloc: Allocator, budget: u64) !Self {
    const builtin = @import("builtin");
    if (builtin.is_test) {
        if (std.process.getEnvVarOwned(alloc, "GHOSTTY_MEDIA_TEST_CACHE")) |root| {
            errdefer alloc.free(root);
            try std.fs.cwd().makePath(root);
            return .{ .alloc = alloc, .root = root, .budget = budget };
        } else |_| {}
    }
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    const base = if (builtin.os.tag == .macos)
        try std.fs.path.join(alloc, &.{ home, "Library/Caches" })
    else
        std.process.getEnvVarOwned(alloc, "XDG_CACHE_HOME") catch try std.fs.path.join(alloc, &.{ home, ".cache" });
    defer alloc.free(base);
    const root = try std.fs.path.join(alloc, &.{ base, "ghostty/background-media" });
    errdefer alloc.free(root);
    try std.fs.cwd().makePath(root);
    return .{ .alloc = alloc, .root = root, .budget = budget };
}
pub fn deinit(self: Self) void {
    self.alloc.free(self.root);
}

pub fn acquire(self: Self, video: []const u8, format: []const u8) !Entry {
    return self.acquireLocked(video, format, .exclusive);
}

fn acquireLocked(self: Self, video: []const u8, format: []const u8, mode: std.fs.File.Lock) !Entry {
    for (video) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidCacheID;
    for (format) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidCacheID;
    const stem = try std.fmt.allocPrint(self.alloc, "{s}/{s}-{s}", .{ self.root, video, format });
    defer self.alloc.free(stem);
    const lock_path = try std.fmt.allocPrint(self.alloc, "{s}.lease", .{stem});
    defer self.alloc.free(lock_path);
    const lease = try std.fs.cwd().createFile(lock_path, .{ .truncate = false, .read = true });
    errdefer lease.close();
    if (!try lease.tryLock(mode)) return error.RenditionInUse;
    return .{ .path = try std.fmt.allocPrint(self.alloc, "{s}.media", .{stem}), .lease = lease, .alloc = self.alloc };
}

pub const Hit = struct { entry: Entry, record: struct { width: u32, height: u32, duration: f64 } };

/// Completed renditions can be opened without any network or metadata lookup.
/// Prefer the largest rendition under the requested ceiling, then the smallest
/// above it. Shared leases allow independent Ghostty processes to reuse it.
pub fn find(self: Self, video: []const u8, height: u32) !?Hit {
    var dir = try std.fs.cwd().openDir(self.root, .{ .iterate = true });
    defer dir.close();
    var selected: ?Hit = null;
    errdefer if (selected) |hit| hit.entry.deinit();
    var it = dir.iterate();
    while (try it.next()) |item| {
        if (!std.mem.endsWith(u8, item.name, ".media.json")) continue;
        var file = dir.openFile(item.name, .{}) catch continue;
        defer file.close();
        const bytes = file.readToEndAlloc(self.alloc, 16384) catch continue;
        defer self.alloc.free(bytes);
        const parsed = std.json.parseFromSlice(Record, self.alloc, bytes, .{}) catch continue;
        defer parsed.deinit();
        const record = parsed.value;
        if (!std.mem.eql(u8, record.video, video) or record.width == 0 or record.height == 0 or record.width > 32768 or record.height > 32768) continue;
        if (selected) |old| {
            const old_under = old.record.height <= height;
            const new_under = record.height <= height;
            if (old_under and (!new_under or old.record.height >= record.height)) continue;
            if (!old_under and !new_under and old.record.height <= record.height) continue;
        }
        const entry = self.acquireLocked(record.video, record.format, .shared) catch continue;
        if (!try self.complete(entry)) {
            entry.deinit();
            continue;
        }
        if (selected) |old| old.entry.deinit();
        selected = .{ .entry = entry, .record = .{ .width = record.width, .height = record.height, .duration = record.duration } };
    }
    return selected;
}

pub fn complete(self: Self, entry: Entry) !bool {
    const manifest = try std.fmt.allocPrint(self.alloc, "{s}.json", .{entry.path});
    defer self.alloc.free(manifest);
    var file = std.fs.cwd().openFile(manifest, .{}) catch return false;
    defer file.close();
    const data = try file.readToEndAlloc(self.alloc, 16384);
    defer self.alloc.free(data);
    const parsed = std.json.parseFromSlice(Record, self.alloc, data, .{}) catch return false;
    defer parsed.deinit();
    const stat = std.fs.cwd().statFile(entry.path) catch return false;
    if (stat.size == 0 or stat.size != parsed.value.bytes) return false;
    const payload = try std.fs.cwd().openFile(entry.path, .{});
    defer payload.close();
    try payload.updateTimes(std.time.nanoTimestamp(), std.time.nanoTimestamp());
    return true;
}

pub fn commit(self: Self, entry: Entry, record: Record) !void {
    const manifest = try std.fmt.allocPrint(self.alloc, "{s}.json", .{entry.path});
    defer self.alloc.free(manifest);
    const temp = try std.fmt.allocPrint(self.alloc, "{s}.tmp", .{manifest});
    defer self.alloc.free(temp);
    const data = try std.json.Stringify.valueAlloc(self.alloc, record, .{});
    defer self.alloc.free(data);
    var file = try std.fs.cwd().createFile(temp, .{});
    defer file.close();
    try file.writeAll(data);
    try file.sync();
    try std.fs.cwd().rename(temp, manifest);
}

/// The global lock covers accounting plus the append, so concurrent downloads
/// cannot each spend the same remaining budget. The caller holds its entry lease.
pub fn append(self: Self, file: std.fs.File, bytes: []const u8) !void {
    const path = try std.fs.path.join(self.alloc, &.{ self.root, ".lock" });
    defer self.alloc.free(path);
    const lock = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer lock.close();
    try lock.lock(.exclusive);
    var dir = try std.fs.cwd().openDir(self.root, .{ .iterate = true });
    defer dir.close();
    var candidates: std.ArrayList(struct { name: []u8, size: u64, time: i128 }) = .empty;
    defer {
        for (candidates.items) |candidate| self.alloc.free(candidate.name);
        candidates.deinit(self.alloc);
    }
    var total: u64 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".media")) continue;
        const stat = try dir.statFile(entry.name);
        total += stat.size;
        try candidates.append(self.alloc, .{ .name = try self.alloc.dupe(u8, entry.name), .size = stat.size, .time = stat.mtime });
    }
    const T = @TypeOf(candidates.items[0]);
    std.mem.sort(T, candidates.items, {}, struct {
        fn less(_: void, a: T, b: T) bool {
            return a.time < b.time;
        }
    }.less);
    for (candidates.items) |candidate| {
        if (total + bytes.len <= self.budget) break;
        const lease_name = try std.fmt.allocPrint(self.alloc, "{s}.lease", .{candidate.name[0 .. candidate.name.len - 6]});
        defer self.alloc.free(lease_name);
        const lease = try dir.createFile(lease_name, .{ .truncate = false });
        defer lease.close();
        if (!try lease.tryLock(.exclusive)) continue;
        try dir.deleteFile(candidate.name);
        const manifest = try std.fmt.allocPrint(self.alloc, "{s}.json", .{candidate.name});
        defer self.alloc.free(manifest);
        dir.deleteFile(manifest) catch {};
        total -= candidate.size;
    }
    if (total + bytes.len > self.budget) return error.MediaCacheFull;
    try file.writeAll(bytes);
}

test "media cache enforces budget and protects leased renditions" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(a, ".");
    var cache: Self = .{ .alloc = a, .root = root, .budget = 6 };
    defer cache.deinit();
    const first = try cache.acquire("video", "1");
    var first_open = true;
    defer if (first_open) first.deinit();
    var file = try std.fs.cwd().createFile(first.path, .{});
    defer file.close();
    try cache.append(file, "abc");
    try cache.commit(first, .{ .video = "video", .format = "1", .width = 1280, .height = 720, .bytes = 3 });
    try std.testing.expect(try cache.complete(first));
    const second = try cache.acquire("other", "2");
    defer second.deinit();
    var other = try std.fs.cwd().createFile(second.path, .{});
    defer other.close();
    try std.testing.expectError(error.MediaCacheFull, cache.append(other, "1234"));
    first.deinit();
    first_open = false;
    try cache.append(other, "1234");
    try std.testing.expectEqual(@as(u64, 4), (try other.stat()).size);
    try std.testing.expect((try cache.find("video", 720)) == null);
}

test "media cache reuses completed video offline with shared leases" {
    const a = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(a, ".");
    const cache: Self = .{ .alloc = a, .root = root, .budget = 1024 };
    defer cache.deinit();
    const writer = try cache.acquire("video", "1");
    {
        defer writer.deinit();
        var file = try std.fs.cwd().createFile(writer.path, .{});
        defer file.close();
        try cache.append(file, "payload");
        try cache.commit(writer, .{ .video = "video", .format = "1", .width = 1280, .height = 720, .bytes = 7 });
    }
    const first = (try cache.find("video", 1080)).?;
    defer first.entry.deinit();
    const second = (try cache.find("video", 720)).?;
    defer second.entry.deinit();
    try std.testing.expectEqualStrings(first.entry.path, second.entry.path);
    try std.testing.expectError(error.RenditionInUse, cache.acquire("video", "1"));
    var corrupt = try std.fs.cwd().createFile(first.entry.path, .{});
    corrupt.close();
    try std.testing.expect(!try cache.complete(first.entry));
    try std.testing.expect((try cache.find("video", 720)) == null);
}
