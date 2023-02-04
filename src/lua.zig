const std = @import("std");
const externs = @import("externs.zig");
const c = externs.c;

L: *c.lua_State,
allocator: std.mem.Allocator,

// export fn body(L: ?*c.lua_State) c_int {
//     c.lua_pushnumber(L, 12);
//     return 1;
// }

// export fn header(L: ?*c.lua_State) c_int {
//     return 1;
// }

// export fn requireJsonLib(L: ?*c.lua_State) c_int {
//     _ = c.lua_pushlstring(L, externs.lua_json_module, externs.lua_json_module.len);
//     return 1;
// }

fn exec(L: *c.lua_State, str: []const u8) !void {
    if (c.luaL_loadstring(L, str.ptr) != 0) {
        std.debug.print("loadstring => {s}\n", .{c.lua_tolstring(L, -1, null)});
        return error.LuaFailedLoadString;
    }

    if (c.lua_pcallk(L, 0, c.LUA_MULTRET, 0, 0, null) != 0) {
        std.debug.print("pcallk => {s}\n", .{c.lua_tolstring(L, -1, null)});
        return error.LuaFailedCall;
    }
}

pub fn init(allocator: std.mem.Allocator) !@This() {
    var L = c.luaL_newstate() orelse return error.LuaInitFailure;

    c.luaL_openlibs(L);

    return .{
        .L = L,
        .allocator = allocator,
    };
}

pub fn deinit(self: @This()) void {
    c.lua_close(self.L);
}

// str: anytype is a bit of a hack? This lets me support both
// c.mg_str and []const u8 types, but I really only use it due to
// the fact that I can't specify c.mg_str in the argument for some
// reason.
fn setGlobal(self: @This(), name: [:0]const u8, str: anytype) void {
    _ = c.lua_pushlstring(self.L, str.ptr, str.len);
    c.lua_setglobal(self.L, name);
}

pub fn eval(self: @This(), str: []const u8, msg: c.mg_http_message) bool {
    var stmt = std.fmt.allocPrintZ(self.allocator, "return {s}", .{str}) catch {
        return false;
    };
    defer self.allocator.free(stmt);

    self.setGlobal("method", msg.method);
    self.setGlobal("uri", msg.uri);
    self.setGlobal("query", msg.query);
    self.setGlobal("proto", msg.proto);
    self.setGlobal("body", msg.body);

    for (msg.headers) |hdr| {
        var hdr_name = toCamelCaseZ(200, hdr.name);
        self.setGlobal(hdr_name, hdr.value);
    }

    if (msg.body.ptr) |bodyptr| {
        const body = bodyptr[0..msg.body.len];
        if (std.json.validate(body)) {
            if (parseJson(self.L, body)) {
                c.lua_setglobal(self.L, "json");
            } else |_| {}
        }
    }

    exec(self.L, stmt) catch return false;

    return c.lua_toboolean(self.L, -1) != 0;
}

fn toCamelCaseZ(comptime sz: usize, src: anytype) [:0]const u8 {
    var dst: [sz:0]u8 = undefined;

    var src_idx: usize = 0;
    var dst_idx: usize = 0;

    var make_upper = true;
    while (src_idx < src.len and dst_idx < sz) {
        switch (src.ptr[src_idx]) {
            '-' => {
                src_idx += 1;
                make_upper = true;
            },
            else => {
                if (make_upper) {
                    dst[dst_idx] = std.ascii.toUpper(src.ptr[src_idx]);
                    make_upper = false;
                } else {
                    dst[dst_idx] = std.ascii.toLower(src.ptr[src_idx]);
                }

                src_idx += 1;
                dst_idx += 1;
            },
        }
    }

    dst[dst_idx] = 0;
    return dst[0..dst_idx :0];
}

test "toCamelCaseZ" {
    const results = [_][2][]const u8{
        .{ "AbcDef" ** 10, "abc-def-" ** 10 },
        .{ "AbcDef", "abc-DEF" },
        .{ "AbcDef", "abc-def-" },
        .{ "AbcDef", "abc--def--" },
        .{ "Abcdef", "abcdef" },
    };
    for (results) |pair| {
        var ccz = toCamelCaseZ(60, pair[1]);
        // std.debug.print("\nok ccz={s}, ccz.len={}\n", .{ ccz, ccz.len });
        try std.testing.expectEqual(pair[0].len, ccz.len);
        try std.testing.expectEqualSlices(u8, pair[0], ccz);
    }
}

// Leaves a lua table on the stack
fn parseJson(L: *c.lua_State, json: []const u8) !void {
    var stream = std.json.TokenStream.init(json);

    if (try stream.next()) |t| switch (t) {
        .ObjectBegin => {
            c.lua_createtable(L, 0, 0);
            try readObject(L, &stream);
        },
        else => unreachable,
    };
}

fn tokenStr(s: *std.json.TokenStream, t: anytype) []const u8 {
    return s.slice[s.i - t.count - 1 .. s.i - 1];
}

fn readObject(L: *c.lua_State, stream: *std.json.TokenStream) !void {
    while (true) {
        // Read the key
        if (try stream.next()) |t| switch (t) {
            .ObjectEnd => return,
            .String => |s| {
                const slice = tokenStr(stream, s);
                _ = c.lua_pushlstring(L, slice.ptr, slice.len);
            },
            else => unreachable,
        };

        // Read the value
        if (try stream.next()) |t| switch (t) {
            .ObjectBegin => {
                c.lua_createtable(L, 0, 0);
                try readObject(L, stream);
            },
            .ArrayBegin => {
                c.lua_createtable(L, 0, 0);
                try readArray(L, stream);
            },
            .String => |s| {
                const slice = tokenStr(stream, s);
                _ = c.lua_pushlstring(L, slice.ptr, slice.len);
            },
            .Number => |n| {
                if (n.is_integer) {
                    c.lua_pushinteger(L, try std.fmt.parseInt(i64, tokenStr(stream, n), 10));
                } else {
                    c.lua_pushnumber(L, try std.fmt.parseFloat(f64, tokenStr(stream, n)));
                }
            },
            .True => c.lua_pushboolean(L, 1),
            .False => c.lua_pushboolean(L, 0),
            .Null => c.lua_pushnil(L),
            else => unreachable,
        };

        c.lua_settable(L, -3);
    }
}

fn readArray(L: *c.lua_State, stream: *std.json.TokenStream) !void {
    var i: c_longlong = 1;
    while (true) {
        if (try stream.next()) |t| switch (t) {
            .ObjectEnd => unreachable,
            .ArrayEnd => return,
            .String => |s| {
                const slice = tokenStr(stream, s);
                _ = c.lua_pushlstring(L, slice.ptr, slice.len);
            },
            .Number => |n| {
                if (n.is_integer) {
                    c.lua_pushinteger(L, try std.fmt.parseInt(i64, tokenStr(stream, n), 10));
                } else {
                    c.lua_pushnumber(L, try std.fmt.parseFloat(f64, tokenStr(stream, n)));
                }
            },
            .True => c.lua_pushboolean(L, 1),
            .False => c.lua_pushboolean(L, 0),
            .Null => c.lua_pushnil(L),
            else => return error.PleaseImplementMeArray,
        };

        c.lua_seti(L, -2, i);
        i = i + 1;
    }
}

// test "lua scratch" {
//     var lua = try init(std.testing.allocator);
//     defer lua.deinit();

//     var cases = .{
//         .{ true, "2 + 1" },
//         .{ true, "true" },
//         .{ true, "'some string'" },
//         .{ false, "false" },
//         .{ false, "null" },
//         .{ false, "invalid lua code?" },
//     };

//     inline for (cases) |case| {
//         try std.testing.expectEqual(case[0], lua.eval(case[1], msg));
//     }
// }

// test "json parse to lua struct" {
//     const json =
//         \\{ "one" : "twoish",
//         \\  "three" : "four",
//         \\  "five": { "hey" : "ok" },
//         \\  "ok" : [1001, 24.4, 398, 41]
//         \\}
//     ;

//     if (std.json.validate(json)) {
//         var L = c.luaL_newstate() orelse return error.LuaInitFailure;
//         c.luaL_openlibs(L);

//         parseJson(L, json) catch {
//             try std.testing.expect(false);
//         };
//         c.lua_setglobal(L, "jj");
//         std.debug.print("\n\n\n", .{});
//         try exec(L, "print(jj.ok[1]*20)");
//         std.debug.print("\n", .{});
//     }
// }

