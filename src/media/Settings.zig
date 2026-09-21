const std = @import("std");
const Self = @This();
pub const Source = enum { none, image, gif, video, @"youtube-video", @"youtube-live", holodex };
pub const Fit = enum { cover, contain };
pub const Acceleration = enum { auto, off };
source: Source = .none,
path: []const u8 = "",
url: []const u8 = "",
channels: []const []const u8 = &.{},
opacity: f32 = 0.2,
fit: Fit = .cover,
max_fps: u32 = 30,
max_height: ?u32 = null,
hardware_acceleration: Acceleration = .auto,
cache_size_mb: u64 = 10240,
ffmpeg: []const u8 = "ffmpeg",
ffprobe: []const u8 = "ffprobe",
yt_dlp: []const u8 = "yt-dlp",

pub fn fromConfig(alloc: std.mem.Allocator, config: anytype) !Self {
    const channels = try alloc.alloc([]const u8, config.@"background-media-channel".list.items.len);
    for (config.@"background-media-channel".list.items, channels) |channel, *copy| copy.* = try alloc.dupe(u8, channel);
    return .{
        .source = config.@"background-media-source",
        .path = try alloc.dupe(u8, config.@"background-media-path" orelse ""),
        .url = try alloc.dupe(u8, config.@"background-media-url" orelse ""),
        .channels = channels,
        .opacity = config.@"background-media-opacity",
        .fit = config.@"background-media-fit",
        .max_fps = config.@"background-media-max-fps",
        .max_height = config.@"background-media-max-height",
        .hardware_acceleration = config.@"background-media-hardware-acceleration",
        .cache_size_mb = config.@"background-media-cache-size-mb",
        .ffmpeg = try alloc.dupe(u8, config.@"background-media-ffmpeg-path"),
        .ffprobe = try alloc.dupe(u8, config.@"background-media-ffprobe-path"),
        .yt_dlp = try alloc.dupe(u8, config.@"background-media-yt-dlp-path"),
    };
}

pub fn validate(self: Self) !void {
    if (!std.math.isFinite(self.opacity) or self.opacity < 0 or self.opacity > 1 or
        self.max_fps < 1 or self.max_fps > 60 or self.cache_size_mb < 1 or self.cache_size_mb > 1048576)
        return error.InvalidMediaLimits;
    if (self.max_height) |height| if (height < 2 or height > 8192) return error.InvalidMediaHeight;
    switch (self.source) {
        .none => {},
        .image, .gif, .video => if (!std.fs.path.isAbsolute(self.path) and !std.mem.startsWith(u8, self.path, "~/"))
            return error.MediaPathMustBeAbsolute,
        .@"youtube-video", .@"youtube-live" => _ = try youtubeID(self.url),
        .holodex => {
            if (self.channels.len == 0 or self.channels.len > 50) return error.InvalidHolodexChannels;
            for (self.channels) |channel| {
                if (channel.len != 24 or !std.mem.startsWith(u8, channel, "UC")) return error.InvalidHolodexChannels;
                for (channel) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidHolodexChannels;
            }
        },
    }
}

pub fn youtubeID(input: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(input);
    if (!std.mem.eql(u8, uri.scheme, "https") or uri.user != null or uri.password != null or uri.port != null)
        return error.InvalidYoutubeURL;
    const host = if (uri.host) |h| h.percent_encoded else return error.InvalidYoutubeURL;
    const path = uri.path.percent_encoded;
    var query = std.mem.splitScalar(u8, if (uri.query) |q| q.percent_encoded else "", '&');
    while (query.next()) |part| if (std.mem.startsWith(u8, part, "list=")) return error.InvalidYoutubeURL;
    var id: ?[]const u8 = null;
    if (std.mem.eql(u8, host, "youtu.be")) {
        id = std.mem.trim(u8, path, "/");
    } else if (std.mem.eql(u8, host, "youtube.com") or std.mem.eql(u8, host, "www.youtube.com") or std.mem.eql(u8, host, "m.youtube.com")) {
        if (std.mem.eql(u8, path, "/watch")) {
            var parts = std.mem.splitScalar(u8, if (uri.query) |q| q.percent_encoded else "", '&');
            while (parts.next()) |part| {
                if (std.mem.startsWith(u8, part, "list=")) return error.InvalidYoutubeURL;
                if (std.mem.startsWith(u8, part, "v=")) id = part[2..];
            }
        } else {
            inline for (.{ "/live/", "/shorts/", "/embed/" }) |prefix| {
                if (std.mem.startsWith(u8, path, prefix)) id = path[prefix.len..];
            }
        }
    }
    const value = id orelse return error.InvalidYoutubeURL;
    if (value.len != 11) return error.InvalidYoutubeURL;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidYoutubeURL;
    return value;
}

pub fn desiredHeight(width: u32, height: u32, source_width: u32, source_height: u32, fit: Fit) u32 {
    const horizontal = @as(f64, @floatFromInt(width)) * @as(f64, @floatFromInt(source_height)) / @as(f64, @floatFromInt(@max(1, source_width)));
    const vertical: f64 = @floatFromInt(height);
    return @intFromFloat(std.math.clamp(@ceil(if (fit == .cover) @max(horizontal, vertical) else @min(horizontal, vertical)), 2, 8192));
}

test "background media URL validation and crop sizing" {
    try std.testing.expectEqualStrings("abcdefghijk", try youtubeID("https://youtu.be/abcdefghijk?t=1"));
    try std.testing.expectError(error.InvalidYoutubeURL, youtubeID("https://youtube.com.evil.test/watch?v=abcdefghijk"));
    try std.testing.expectError(error.InvalidYoutubeURL, youtubeID("https://youtube.com/watch?v=abcdefghijk&list=playlist"));
    try std.testing.expectEqual(@as(u32, 1125), desiredHeight(2000, 500, 1920, 1080, .cover));
    try std.testing.expectEqual(@as(u32, 500), desiredHeight(2000, 500, 1920, 1080, .contain));
    try std.testing.expectError(error.InvalidMediaLimits, (Self{ .max_fps = 0 }).validate());
}
