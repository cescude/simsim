const std = @import("std");
const externs = @import("externs.zig");
const c = externs.c;

fn cast(comptime T: type, op: anytype) *T {
    const a = @ptrToInt(op);
    const b = @intToPtr(*T, a);
    return b;
}

pub fn serve(addr: []const u8, port: u16, comptime T: type, data: T, user_callback: *const fn (*c.mg_connection, *c.mg_http_message, T) void) !noreturn {
    var listen_buf = [_:0]u8{0} ** 200;
    var listen_addr = try std.fmt.bufPrint(&listen_buf, "http://{s}:{d}", .{ addr, port });

    var mgr: c.mg_mgr = undefined;
    c.mg_mgr_init(&mgr);
    defer c.mg_mgr_free(&mgr);

    const UserDataWrapper = struct {
        user_callback: @TypeOf(user_callback),
        user_data: T,

        const SelfType = @This();

        // Function that mongoose actually calls...this then lifts up into the user callback
        export fn userCallbackWrapper(_conn: ?*c.mg_connection, ev: c_int, _msg: ?*anyopaque, _wrap: ?*anyopaque) void {
            var conn = _conn orelse return;
            var http_msg = cast(c.mg_http_message, _msg orelse return);
            var wrap = cast(SelfType, _wrap orelse return);

            if (ev == c.MG_EV_HTTP_MSG) {
                wrap.user_callback(conn, http_msg, wrap.user_data);
            }
        }
    };

    const userDataWrapper = UserDataWrapper{
        .user_callback = user_callback,
        .user_data = data,
    };

    _ = c.mg_http_listen(&mgr, listen_addr.ptr, UserDataWrapper.userCallbackWrapper, cast(anyopaque, &userDataWrapper));
    while (true) {
        c.mg_mgr_poll(&mgr, 1000);
    }
}
