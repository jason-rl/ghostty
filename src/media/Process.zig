//! Cancellable subprocess I/O. No shell, no inherited Holodex credentials, bounded output.
const std = @import("std");
const Self = @This();
const Allocator = std.mem.Allocator;
child: std.process.Child,
env: std.process.EnvMap,
stop: *const std.atomic.Value(bool),

pub fn init(alloc: Allocator, argv: []const []const u8, stop: *const std.atomic.Value(bool)) !Self {
    var env = try std.process.getEnvMap(alloc);
    errdefer env.deinit();
    env.remove("HOLODEX_API_KEY");
    // Finder launches do not inherit a login shell PATH. Include conventional tool locations.
    const path = try std.fmt.allocPrint(alloc, "{s}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", .{env.get("PATH") orelse ""});
    defer alloc.free(path);
    try env.put("PATH", path);
    var child = std.process.Child.init(argv, alloc);
    child.pgid = 0;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    // Never retain decoder diagnostics: URLs can contain signed tokens and headers.
    child.stderr_behavior = .Ignore;
    child.env_map = &env;
    try child.spawn();
    return .{ .child = child, .env = env, .stop = stop };
}

pub fn deinit(self: *Self) void {
    if (self.child.term == null) {
        std.posix.kill(-self.child.id, std.posix.SIG.KILL) catch {};
    }
    _ = self.child.wait() catch {};
    self.env.deinit();
}

pub fn read(self: *Self, buffer: []u8, deadline: i64) !usize {
    while (!self.stop.load(.acquire)) {
        if (std.time.milliTimestamp() > deadline) return error.MediaProcessTimeout;
        var fds = [_]std.posix.pollfd{.{ .fd = self.child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 100) == 0) continue;
        return self.child.stdout.?.read(buffer);
    }
    return error.MediaCancelled;
}

/// EOF is not proof of child exit. Poll the child so even a tool that closes
/// stdout and hangs cannot block config reload or app shutdown indefinitely.
pub fn wait(self: *Self) !std.process.Child.Term {
    try self.child.waitForSpawn();
    const deadline = std.time.milliTimestamp() + 5000;
    while (!self.stop.load(.acquire)) {
        const result = std.posix.waitpid(self.child.id, std.posix.W.NOHANG);
        if (result.pid != 0) {
            const status = result.status;
            self.child.term = if (std.posix.W.IFEXITED(status))
                .{ .Exited = std.posix.W.EXITSTATUS(status) }
            else if (std.posix.W.IFSIGNALED(status))
                .{ .Signal = std.posix.W.TERMSIG(status) }
            else
                .{ .Unknown = status };
            return self.child.wait();
        }
        if (std.time.milliTimestamp() >= deadline) return error.MediaProcessTimeout;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.MediaCancelled;
}

pub fn output(alloc: Allocator, args: []const []const u8, stop: *const std.atomic.Value(bool)) ![]u8 {
    var process = try init(alloc, args, stop);
    defer process.deinit();
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    const deadline = std.time.milliTimestamp() + 45_000;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try process.read(&buf, deadline);
        if (n == 0) break;
        if (bytes.items.len + n > 4 * 1024 * 1024) return error.MediaMetadataTooLarge;
        try bytes.appendSlice(alloc, buf[0..n]);
    }
    // wait() closes Child's pipe handles. deinit may safely call kill after wait.
    const term = try process.wait();
    if (term != .Exited or term.Exited != 0) return error.MediaProcessFailed;
    return bytes.toOwnedSlice(alloc);
}
