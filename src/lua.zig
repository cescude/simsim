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

    // Create a "header" table (also "headers" in case of typos). Will
    // create a key that perfectly matches the header
    // (eg. `header['Content-type']`) as well as a camel case version
    // that can be accessed without quotes (eg. `header.contentType`).

    c.lua_createtable(self.L, 0, 0);
    for (msg.headers) |hdr| {
        if (hdr.name.ptr == null) continue;

        var camelCaseName: [200:0]u8 = undefined;
        toCamelCaseZ(&camelCaseName, hdr.name);

        _ = c.lua_pushstring(self.L, &camelCaseName);
        _ = c.lua_pushlstring(self.L, hdr.value.ptr, hdr.value.len);
        c.lua_settable(self.L, -3);

        _ = c.lua_pushlstring(self.L, hdr.name.ptr, hdr.name.len);
        _ = c.lua_pushlstring(self.L, hdr.value.ptr, hdr.value.len);
        c.lua_settable(self.L, -3);
    }
    c.lua_pushvalue(self.L, -1); // duplicate top of stack
    c.lua_setglobal(self.L, "header");
    c.lua_setglobal(self.L, "headers");

    if (msg.body.ptr) |bodyptr| {
        const top = c.lua_gettop(self.L);
        const body = bodyptr[0..msg.body.len];

        if (parseJson(self.L, body)) {
            c.lua_setglobal(self.L, "json");
        } else |_| {
            // Cleanup any weirdness w/ Lua's stack
            c.lua_settop(self.L, top);
        }

        if (parseFormBody(self.L, self.allocator, body)) {
            c.lua_setglobal(self.L, "form");
        } else |_| {
            // Cleanup any weirdness w/ Lua's stack
            c.lua_settop(self.L, top);
        }
    }

    exec(self.L, stmt) catch return false;

    return c.lua_toboolean(self.L, -1) != 0;
}

fn toCamelCaseZ(dst: [:0]u8, src: anytype) void {
    var src_idx: usize = 0;
    var dst_idx: usize = 0;

    var make_upper = false; // first character isn't upcased
    while (src_idx < src.len and dst_idx < dst.len) {
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
}

test "toCamelCaseZ" {
    const results = [_][2][]const u8{
        .{ "abcDef", "abc-def-" },
        .{ "abcDef", "abc-DEF" },
        .{ "abcDef", "abc-def-" },
        .{ "abcDef", "abc--def--" },
        .{ "abcdef", "abcdef" },
    };

    for (results) |pair| {
        var ccz: [200:0]u8 = undefined;
        toCamelCaseZ(&ccz, pair[1]);
        try std.testing.expectEqual(pair[0].len, std.mem.indexOfSentinel(u8, 0, &ccz));
        try std.testing.expectEqualSlices(u8, pair[0], ccz[0..pair[0].len]);
    }
}

// Leaves a lua table on the stack
fn parseJson(L: *c.lua_State, json: []const u8) !void {
    if (!std.json.validate(json)) {
        return error.NotJSON;
    }

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

// TODO: move the scratch buffer out of here?
fn parseFormBody(L: *c.lua_State, allocator: std.mem.Allocator, form: []const u8) !void {
    c.lua_createtable(L, 0, 0);

    var iter = std.mem.tokenize(u8, form, "&");
    while (iter.next()) |tok| {
        var buf = try allocator.alloc(u8, tok.len); // Decoding always shrinks the size (eg. %20 goes from three bytes to one)
        defer allocator.free(buf);

        var pair = std.mem.tokenize(u8, tok, "=");

        var name = try decodeUri(buf, pair.next() orelse continue);
        _ = c.lua_pushlstring(L, name.ptr, name.len);

        var value = try decodeUri(buf, pair.rest());
        _ = c.lua_pushlstring(L, value.ptr, value.len);

        c.lua_settable(L, -3);
    }
}

fn toNibble(character: u8) !u4 {
    const codes = "0123456789abcdef";
    return @truncate(u4, std.mem.indexOfScalar(u8, codes, std.ascii.toLower(character)) orelse return error.InvalidHexDigit);
}

fn decodeUri(buf: []u8, str: []const u8) ![]const u8 {
    const ReadMode = enum { Normal, HighBits, LowBits };
    var read_mode = ReadMode.Normal;

    var dst_idx: usize = 0;
    for (str) |b| {
        switch (read_mode) {
            .Normal => {
                if (b == '%') {
                    read_mode = .HighBits;
                } else {
                    buf[dst_idx] = b;
                    dst_idx += 1;
                }
            },
            .HighBits => {
                buf[dst_idx] = try toNibble(b);
                buf[dst_idx] <<= 4;
                read_mode = .LowBits;
            },
            .LowBits => {
                buf[dst_idx] += try toNibble(b);
                read_mode = .Normal;
                dst_idx += 1;
            },
        }
    }

    if (read_mode != ReadMode.Normal) {
        return error.IncompleteByteSequence;
    }
    return buf[0..dst_idx];
}

test "decodeUri" {
    var dec: [20]u8 = undefined;
    var enc = "one%20two&on%6f";
    std.debug.print("decodeUri: orig={s}, decoded={s}\n", .{ enc, try decodeUri(&dec, enc) });
}
