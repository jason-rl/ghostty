//! Optional libsecret integration. All operations use libsecret's asynchronous
//! Secret Service API, including unlock prompts. Secrets never enter subprocesses.
const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const adw = @import("adw");
const Application = @import("class/application.zig").Application;
const TitleDialog = @import("class/title_dialog.zig").TitleDialog;
const media = @import("../../media/main.zig");
const log = std.log.scoped(.holodex_credentials);
const Callback = *const fn (?*gobject.Object, *gio.AsyncResult, ?*anyopaque) callconv(.c) void;
const Attribute = extern struct { name: ?[*:0]const u8 = null, kind: c_int = 0 };
// ABI from libsecret/secret-schema.h. Static schemas require no allocation.
const Schema = extern struct {
    name: [*:0]const u8 = "com.mitchellh.ghostty.Holodex",
    flags: c_int = 0,
    attributes: [32]Attribute = [_]Attribute{.{ .name = "account" }} ++ [_]Attribute{.{}} ** 31,
    reserved: c_int = 0,
    pointers: [7]?*anyopaque = .{null} ** 7,
};
const schema: Schema = .{};
const Context = struct {
    library: std.DynLib,
    app: *Application,
    revision: u64,
    operation: enum { load, store, remove },
    fn symbol(self: *Context, comptime T: type, name: [:0]const u8) T {
        return self.library.lookup(T, name).?;
    }
    fn deinit(self: *Context) void {
        self.app.unref();
        std.heap.c_allocator.destroy(self);
    }
};
// All entry points and completions execute on the GTK main context.
var revision: u64 = 0;
var busy = false;
// libsecret registers GObject types and may finish callbacks after ours returns.
// Its code must remain loaded for the lifetime of those objects.
var secret_library: ?std.DynLib = null;

pub fn load(app: *Application) void {
    begin(app, null, false) catch |err| failed(app, err, false);
}

pub fn present(app: *Application, parent: *gtk.Widget, remove: bool) void {
    if (busy) return;
    if (remove) {
        begin(app, null, true) catch |err| failed(app, err, true);
        return;
    }
    const dialog = TitleDialog.new(.holodex, null);
    _ = TitleDialog.signals.set.connect(dialog, *Application, save, app, .{});
    dialog.present(parent);
}

fn save(_: *TitleDialog, key: [*:0]const u8, app: *Application) callconv(.c) void {
    const valid = media.validateKey(std.mem.span(key)) catch |err| {
        failed(app, err, true);
        return;
    };
    const value = std.heap.c_allocator.dupeZ(u8, valid) catch return;
    defer {
        @memset(value, 0);
        std.heap.c_allocator.free(value);
    }
    begin(app, value, false) catch |err| failed(app, err, true);
}

fn begin(app: *Application, key: ?[:0]const u8, remove: bool) !void {
    if (busy) return error.CredentialOperationInProgress;
    if (secret_library == null) secret_library = try std.DynLib.open("libsecret-1.so.0");
    var library = secret_library.?;
    inline for (.{ "secret_password_lookup", "secret_password_lookup_finish", "secret_password_store", "secret_password_store_finish", "secret_password_clear", "secret_password_clear_finish", "secret_password_free" }) |name| {
        if (library.lookup(*const anyopaque, name) == null) return error.LibsecretUnavailable;
    }
    const ctx = try std.heap.c_allocator.create(Context);
    revision +%= 1;
    ctx.* = .{ .library = library, .app = app.ref(), .revision = revision, .operation = if (remove) .remove else if (key != null) .store else .load };
    busy = true;
    // A failed/locked store must not select the environment fallback.
    app.core().media.setKey(null, true) catch {};
    const end: ?[*:0]const u8 = null;
    if (key) |value| {
        const Store = *const fn (*const Schema, [*:0]const u8, [*:0]const u8, [*:0]const u8, ?*gio.Cancellable, Callback, ?*anyopaque, ...) callconv(.c) void;
        ctx.symbol(Store, "secret_password_store")(&schema, "default", "Ghostty Holodex API Key", value.ptr, null, ready, ctx, @as([*:0]const u8, "account"), @as([*:0]const u8, "api-key"), end);
    } else {
        const Start = *const fn (*const Schema, ?*gio.Cancellable, Callback, ?*anyopaque, ...) callconv(.c) void;
        ctx.symbol(Start, if (remove) "secret_password_clear" else "secret_password_lookup")(&schema, null, ready, ctx, @as([*:0]const u8, "account"), @as([*:0]const u8, "api-key"), end);
    }
}

fn ready(_: ?*gobject.Object, result: *gio.AsyncResult, userdata: ?*anyopaque) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(userdata));
    defer ctx.deinit();
    busy = false;
    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();
    if (ctx.operation != .load) {
        const Finish = *const fn (*gio.AsyncResult, *?*glib.Error) callconv(.c) c_int;
        _ = ctx.symbol(Finish, if (ctx.operation == .store) "secret_password_store_finish" else "secret_password_clear_finish")(result, &err);
        if (err != null) {
            failed(ctx.app, error.CredentialStoreUnavailable, true);
            return;
        }
        load(ctx.app);
        return;
    }
    const Finish = *const fn (*gio.AsyncResult, *?*glib.Error) callconv(.c) ?[*:0]u8;
    const key = ctx.symbol(Finish, "secret_password_lookup_finish")(result, &err);
    defer if (key) |value| ctx.symbol(*const fn ([*:0]u8) callconv(.c) void, "secret_password_free")(value);
    if (ctx.revision != revision) return;
    ctx.app.core().media.setKey(if (key) |k| std.mem.span(k) else null, err != null) catch {
        failed(ctx.app, error.InvalidHolodexKey, false);
        return;
    };
    _ = ctx.app.rt().performAction(.app, .reload_config, .{ .soft = true }) catch {};
    if (err != null) log.warn("Holodex Secret Service unavailable", .{});
}

fn failed(app: *Application, err: anyerror, interactive: bool) void {
    app.core().media.setKey(null, true) catch {};
    log.warn("Holodex credential operation failed: {s}", .{@errorName(err)});
    if (!interactive) return;
    const dialog = adw.AlertDialog.new("Holodex API Key", "Unable to access the key. Check that libsecret and an unlocked Secret Service are available, and enter a key without spaces or control characters.");
    dialog.addResponse("ok", "OK");
    dialog.as(adw.Dialog).present(if (app.as(gtk.Application).getActiveWindow()) |window| window.as(gtk.Widget) else null);
}
