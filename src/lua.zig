const std = @import("std");
const externs = @import("externs.zig");
const stdout = @import("stdout.zig");
const c = externs.c;

L: *c.lua_State,
allocator: std.mem.Allocator,

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
fn setGlobalString(self: @This(), name: [:0]const u8, str: anytype) void {
    if (str.ptr) |str_ptr| {
        _ = c.lua_pushlstring(self.L, str_ptr, str.len);
    } else {
        c.lua_pushnil(self.L);
    }
    c.lua_setglobal(self.L, name);
}

fn makeDummyTable(self: @This(), name: [:0]const u8) void {
    c.lua_createtable(self.L, 0, 0);
    c.lua_setglobal(self.L, name);
}

pub fn eval(self: @This(), str: []const u8, msg: c.mg_http_message) bool {
    // Reset the lua stack at the end, so it doesn't slowly grow with
    // each request.
    var top_of_stack = c.lua_gettop(self.L);
    defer c.lua_settop(self.L, top_of_stack);

    var stmt = std.fmt.allocPrintZ(self.allocator, "return {s}", .{str}) catch {
        return false;
    };
    defer self.allocator.free(stmt);

    self.setGlobalString("method", msg.method);
    self.setGlobalString("proto", msg.proto);
    self.setGlobalString("body", msg.body);

    // Setup the path variable
    if (msg.uri.ptr) |uri_ptr| {
        c.lua_createtable(self.L, 0, 0);

        _ = c.lua_pushlstring(self.L, uri_ptr, msg.uri.len);
        c.lua_seti(self.L, -2, 0);

        if (msg.uri.len > 0) {
            var path_iter = std.mem.split(u8, uri_ptr[1..msg.uri.len], "/");
            var idx: c_longlong = 0;

            while (path_iter.next()) |segment| {
                idx += 1;
                _ = c.lua_pushlstring(self.L, segment.ptr, segment.len);
                c.lua_seti(self.L, -2, idx);
            }
        }

        c.lua_setglobal(self.L, "path");
    }

    // These may get overridden below
    makeDummyTable(self, "query");
    makeDummyTable(self, "json");
    makeDummyTable(self, "form");

    // Create a "headers" table. Will create a key that perfectly
    // matches the header (eg. `headers['Content-type']`) as well as a
    // camel case version that can be accessed without quotes
    // (eg. `headers.contentType`).

    c.lua_createtable(self.L, 0, 0);
    for (msg.headers) |hdr| {
        if (hdr.name.ptr == null) continue;

        var buffer: [200]u8 = undefined;
        var camelCaseName = toCamelCase(&buffer, hdr.name.ptr[0..hdr.name.len]);

        _ = c.lua_pushlstring(self.L, camelCaseName.ptr, camelCaseName.len);
        _ = c.lua_pushlstring(self.L, hdr.value.ptr, hdr.value.len);
        c.lua_settable(self.L, -3);

        _ = c.lua_pushlstring(self.L, hdr.name.ptr, hdr.name.len);
        _ = c.lua_pushlstring(self.L, hdr.value.ptr, hdr.value.len);
        c.lua_settable(self.L, -3);
    }
    c.lua_setglobal(self.L, "headers");

    if (msg.query.ptr) |queryptr| {
        const top = c.lua_gettop(self.L);
        const query = queryptr[0..msg.query.len];

        if (parseUriString(self.L, self.allocator, query)) {
            c.lua_setglobal(self.L, "query");
        } else |_| {
            // Cleanup any weirdness w/ Lua's stack
            c.lua_settop(self.L, top);
        }
    }

    if (msg.body.ptr) |bodyptr| {
        const top = c.lua_gettop(self.L);
        const body = bodyptr[0..msg.body.len];

        if (parseJson(self.L, body)) {
            c.lua_setglobal(self.L, "json");
        } else |_| {
            // Cleanup any weirdness w/ Lua's stack
            c.lua_settop(self.L, top);
        }

        if (parseUriString(self.L, self.allocator, body)) {
            c.lua_setglobal(self.L, "form");
        } else |_| {
            // Cleanup any weirdness w/ Lua's stack
            c.lua_settop(self.L, top);
        }
    }

    self.exec(stmt) catch {
        stdout.print("Error executing guard: {s}\n", .{c.lua_tolstring(self.L, -1, null)});
        return false;
    };

    return c.lua_toboolean(self.L, -1) != 0;
}

fn exec(self: @This(), str: []const u8) !void {
    if (c.luaL_loadstring(self.L, str.ptr) != 0) {
        return error.LuaFailedLoadString;
    }

    if (c.lua_pcallk(self.L, 0, c.LUA_MULTRET, 0, 0, null) != 0) {
        return error.LuaFailedCall;
    }
}

fn toCamelCase(dst: []u8, src: []const u8) []const u8 {
    var src_idx: usize = 0;
    var dst_idx: usize = 0;

    var make_upper = true; // first character is upcased
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

    return dst[0..dst_idx];
}

test "toCamelCase" {
    const results = [_][2][]const u8{
        .{ "AbcDef", "abc-def-" },
        .{ "AbcDef", "abc-DEF" },
        .{ "AbcDef", "abc-def-" },
        .{ "AbcDef", "ABC--def--" },
        .{ "Abcdef", "abcdef" },
    };

    for (results) |pair| {
        var ccz: [200]u8 = undefined;
        try std.testing.expectEqualSlices(u8, pair[0], toCamelCase(&ccz, pair[1]));
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
        else => return error.ExpectedJsonToStartWithAnObject,
    };
}

fn tokenStr(s: *std.json.TokenStream, t: anytype) []const u8 {
    return s.slice[s.i - t.count - 1 .. s.i - 1];
}

const JsonReadError = error{
    UnexpectedKeyType,
    UnexpectedToken,
} || std.fmt.ParseIntError || std.fmt.ParseFloatError || std.json.TokenStream.Error;

fn readObject(L: *c.lua_State, stream: *std.json.TokenStream) JsonReadError!void {
    while (true) {
        // Read the key
        if (try stream.next()) |t| switch (t) {
            .ObjectEnd => return,
            .String => |s| {
                const slice = tokenStr(stream, s);
                _ = c.lua_pushlstring(L, slice.ptr, slice.len);
            },
            else => return error.UnexpectedKeyType,
        };

        // Read the value
        if (try stream.next()) |t| switch (t) {
            .ObjectBegin => {
                c.lua_createtable(L, 0, 0);
                try readObject(L, stream);
            },
            .ObjectEnd => return error.UnexpectedToken,
            .ArrayBegin => {
                c.lua_createtable(L, 0, 0);
                try readArray(L, stream);
            },
            .ArrayEnd => return error.UnexpectedToken,
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
        };

        c.lua_settable(L, -3);
    }
}

fn readArray(L: *c.lua_State, stream: *std.json.TokenStream) JsonReadError!void {
    var i: c_longlong = 1;
    while (true) {
        if (try stream.next()) |t| switch (t) {
            .ObjectBegin => {
                c.lua_createtable(L, 0, 0);
                try readObject(L, stream);
            },
            .ObjectEnd => return error.UnexpectedToken,
            .ArrayBegin => {
                c.lua_createtable(L, 0, 0);
                try readArray(L, stream);
            },
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
        };

        c.lua_seti(L, -2, i);
        i = i + 1;
    }
}

// TODO: move the scratch buffer out of here?
fn parseUriString(L: *c.lua_State, allocator: std.mem.Allocator, form: []const u8) !void {
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
                dst_idx += 1;
                read_mode = .Normal;
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
    try std.testing.expectEqualSlices(u8, "one two&ono", try decodeUri(&dec, enc));
}
