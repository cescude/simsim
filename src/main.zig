const std = @import("std");
const c = @cImport({
    @cInclude("mongoose.h");
});

fn cast(comptime T: type, op: anytype) *T {
    const a = @ptrToInt(op);
    const b = @intToPtr(*T, a);
    return b;
}

fn toSlice(str: [*c]const u8, len: usize) []const u8 {
    return str[0..len];
}

const Definition = struct {
    uri: []const u8 = undefined,

    num_guards: usize = 0,
    guards: [20][]const u8 = undefined,

    num_headers: usize = 0,
    headers: [20][]const u8 = undefined,

    body: ?[]const u8 = null,
};

var allocator = std.heap.c_allocator;

export fn callback(mconn: ?*c.mg_connection, ev: c_int, ev_data: ?*anyopaque, _: ?*anyopaque) void {
    if (ev == c.MG_EV_HTTP_MSG) {
        if (wrapper(mconn, ev_data)) |found| {
            var body = found.body orelse "";
            c.mg_http_reply(mconn, 200, "Content-Type: text/plain\r\n", "Found %*s", body.len, body.ptr);
        } else |_| {
            c.mg_http_reply(mconn, 404, "Content-Type: text/plain\r\n", "Not Found");
        }
    }
}

fn wrapper(_conn: ?*c.mg_connection, _data: ?*anyopaque) !Definition {
    var file = try std.fs.cwd().openFile("payload", .{});
    defer file.close();

    var buffer = try file.readToEndAlloc(allocator, 1 << 30);
    defer allocator.free(buffer);

    var conn = _conn orelse return error.NullConnection;
    var data = _data orelse return error.NullEvData;

    return try findDefinition(buffer, conn, cast(c.mg_http_message, data));
}

fn findDefinition(_buf: []u8, _: *c.mg_connection, hm: *c.mg_http_message) !Definition {
    var buf = _buf;

    var d: Definition = .{};

    const uri = toSlice(hm.uri.ptr, hm.uri.len);
    var found = false;

    var lines = std.mem.split(u8, buf, "\n");
    _ = lines.first(); // always skip the first line? Maybe we could stick a \n at buf[0]....

    while (lines.next()) |line0| {
        var trimmed0 = std.mem.trim(u8, line0, &std.ascii.whitespace);
        if (trimmed0.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed0, "#")) continue;

        d.uri = trimmed0;
        found = std.mem.eql(u8, uri, d.uri);
        var delim: []const u8 = undefined;

        // Read headers?
        while (lines.next()) |line| {
            var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, trimmed, "#")) continue;
            if (std.mem.startsWith(u8, trimmed, ">")) {
                d.headers[d.num_headers] = trimmed[0..];
                d.num_headers += 1;
            } else {
                delim = trimmed;
                break;
            }
        }

        // Read content!
        var content_start: usize = lines.index orelse buf.len;
        while (lines.next()) |line| {
            var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            std.debug.print(">>>> <{s}> == <{s}>, {}\n", .{ delim, trimmed, std.mem.eql(u8, delim, trimmed) });
            std.debug.print("     line.len={}, trimmed.len={}\n", .{ line.len, trimmed.len });
            if (std.mem.eql(u8, delim, trimmed)) {
                // Done w/ content
                break;
            }

            d.body = buf[content_start .. lines.index orelse buf.len];
        }

        if (found) {
            std.debug.print("found={}, uri={s}, content={?s}\n", .{ found, d.uri, d.body });
            return d;
        }
    }

    return error.notFound;
}

pub fn main() void {
    std.debug.print("Starting up the server!\n", .{});

    var mgr: c.mg_mgr = undefined;

    c.mg_mgr_init(&mgr);
    defer c.mg_mgr_free(&mgr);

    _ = c.mg_http_listen(&mgr, "http://localhost:8080", callback, &mgr);
    while (true) {
        c.mg_mgr_poll(&mgr, 1000);
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
