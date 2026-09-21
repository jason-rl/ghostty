//! Bounded HTTP requests through system libcurl. Credentials stay in process memory.
const std = @import("std");
const builtin = @import("builtin");
var mutex: std.Thread.Mutex = .{};
var library: ?std.DynLib = null;
const Easy = *anyopaque;
const Set = *const fn (Easy, c_int, ...) callconv(.c) c_int;

fn symbol(comptime T: type, name: [:0]const u8) !T {
    return library.?.lookup(T, name) orelse error.CurlUnavailable;
}

pub fn holodex(a: std.mem.Allocator, key: []const u8, stop: *const std.atomic.Value(bool)) ![]u8 {
    return request(a, "https://holodex.net/api/v2/live?status=live&max_upcoming_hours=0&limit=1000", key, 4 * 1024 * 1024, stop);
}

pub fn artwork(a: std.mem.Allocator, url: []const u8, stop: *const std.atomic.Value(bool)) ![]u8 {
    return request(a, url, null, 8 * 1024 * 1024, stop);
}

fn request(a: std.mem.Allocator, url: []const u8, key: ?[]const u8, limit: usize, stop: *const std.atomic.Value(bool)) ![]u8 {
    if (stop.load(.acquire)) return error.MediaCancelled;
    const easy = init: {
        mutex.lock();
        defer mutex.unlock();
        if (library == null) library = try std.DynLib.open(if (builtin.os.tag == .macos) "/usr/lib/libcurl.4.dylib" else "libcurl.so.4");
        break :init (try symbol(*const fn () callconv(.c) ?Easy, "curl_easy_init"))() orelse return error.CurlUnavailable;
    };
    const cleanup = try symbol(*const fn (Easy) callconv(.c) void, "curl_easy_cleanup");
    defer cleanup(easy);
    const set = try symbol(Set, "curl_easy_setopt");
    const append = try symbol(*const fn (?Easy, [*:0]const u8) callconv(.c) ?Easy, "curl_slist_append");
    const free = try symbol(*const fn (?Easy) callconv(.c) void, "curl_slist_free_all");
    const header = if (key) |value| try std.fmt.allocPrintSentinel(a, "X-APIKEY: {s}", .{value}, 0) else null;
    defer {
        if (header) |value| {
            @memset(value, 0);
            a.free(value);
        }
    }
    const headers = if (header) |value| append(null, value) orelse return error.OutOfMemory else null;
    defer free(headers);
    const address = try a.dupeZ(u8, url);
    defer a.free(address);
    var response: Response = .{ .a = a, .stop = stop, .limit = limit };
    errdefer response.bytes.deinit(a);
    // CURLOPT numeric values are stable ABI (curl/curl.h).
    if (set(easy, 10002, address.ptr) != 0 or
        set(easy, 10023, headers) != 0 or set(easy, 10001, &response) != 0 or
        set(easy, 20011, @as(*const fn ([*]const u8, usize, usize, *Response) callconv(.c) usize, write)) != 0 or
        set(easy, 20219, @as(*const fn (*Response, i64, i64, i64, i64) callconv(.c) c_int, progress)) != 0 or
        set(easy, 10057, &response) != 0 or set(easy, 43, @as(c_long, 0)) != 0 or
        set(easy, 99, @as(c_long, 1)) != 0 or set(easy, 155, @as(c_long, 15000)) != 0 or
        set(easy, 156, @as(c_long, 5000)) != 0 or
        set(easy, 181, @as(c_long, if (key != null) 2 else 3)) != 0 or
        set(easy, 182, @as(c_long, 3)) != 0 or set(easy, 68, @as(c_long, 5)) != 0 or
        set(easy, 52, @as(c_long, if (key != null) 0 else 1)) != 0) return error.CurlUnavailable;
    // Only anonymous artwork follows redirects, restricted to HTTP(S).
    const result = (try symbol(*const fn (Easy) callconv(.c) c_int, "curl_easy_perform"))(easy);
    if (stop.load(.acquire)) return error.MediaCancelled;
    if (response.too_large) return error.MediaResponseTooLarge;
    if (result != 0) return if (key != null) error.HolodexRequestFailed else error.ArtworkRequestFailed;
    var status: c_long = 0;
    const info = try symbol(*const fn (Easy, c_int, ...) callconv(.c) c_int, "curl_easy_getinfo");
    if (info(easy, 0x200002, &status) != 0 or status != 200) return if (key != null) error.HolodexRequestFailed else error.ArtworkRequestFailed;
    return response.bytes.toOwnedSlice(a);
}
const Response = struct { a: std.mem.Allocator, stop: *const std.atomic.Value(bool), limit: usize, too_large: bool = false, bytes: std.ArrayList(u8) = .empty };
fn write(data: [*]const u8, size: usize, count: usize, response: *Response) callconv(.c) usize {
    const len = std.math.mul(usize, size, count) catch return 0;
    if (response.stop.load(.acquire)) return 0;
    if (len > response.limit - response.bytes.items.len) {
        response.too_large = true;
        return 0;
    }
    response.bytes.appendSlice(response.a, data[0..len]) catch return 0;
    return len;
}
fn progress(response: *Response, _: i64, _: i64, _: i64, _: i64) callconv(.c) c_int {
    return if (response.stop.load(.acquire)) 1 else 0;
}

test "artwork HTTP rejects oversized responses and non-HTTP redirects" {
    const a = std.testing.allocator;
    const base = std.process.getEnvVarOwned(a, "GHOSTTY_MEDIA_TEST_ARTWORK_URL") catch return error.SkipZigTest;
    defer a.free(base);
    var stop: std.atomic.Value(bool) = .init(false);
    const oversized = try std.fmt.allocPrint(a, "{s}/too-large", .{base});
    defer a.free(oversized);
    try std.testing.expectError(error.MediaResponseTooLarge, artwork(a, oversized, &stop));
    const redirect = try std.fmt.allocPrint(a, "{s}/redirect-file", .{base});
    defer a.free(redirect);
    try std.testing.expectError(error.ArtworkRequestFailed, artwork(a, redirect, &stop));
    const missing = try std.fmt.allocPrint(a, "{s}/missing", .{base});
    defer a.free(missing);
    try std.testing.expectError(error.ArtworkRequestFailed, artwork(a, missing, &stop));
    const slow = try std.fmt.allocPrint(a, "{s}/slow", .{base});
    defer a.free(slow);
    const cancel = try std.Thread.spawn(.{}, struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            flag.store(true, .release);
        }
    }.run, .{&stop});
    defer cancel.join();
    var timer = try std.time.Timer.start();
    try std.testing.expectError(error.MediaCancelled, artwork(a, slow, &stop));
    try std.testing.expect(timer.read() < 5 * std.time.ns_per_s);
    try std.testing.expectError(error.MediaCancelled, artwork(a, base, &stop));
}
