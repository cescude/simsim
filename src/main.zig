const std = @import("std");
const zopts = @import("zopts");
const c = @cImport({
    @cInclude("mongoose.h");
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

fn cast(comptime T: type, op: anytype) *T {
    const a = @ptrToInt(op);
    const b = @intToPtr(*T, a);
    return b;
}

const Definition = struct {
    uri: []const u8 = undefined,
    // guards: std.ArrayList([]const u8) = undefined,
    headers: std.ArrayList([]const u8) = undefined,
    body: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .uri = undefined,
            // .guards = std.ArrayList([]const u8).init(allocator),
            .headers = std.ArrayList([]const u8).init(allocator),
            .body = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: @This()) void {
        // self.guards.deinit();
        self.headers.deinit();
    }
};

export fn callback(conn: ?*c.mg_connection, ev: c_int, ev_data: ?*anyopaque, files: ?*anyopaque) void {
    if (ev == c.MG_EV_HTTP_MSG) {
        if (handleHttpRequest(conn, ev_data, files)) {
            // Nothing to do!
        } else |err| switch (err) {
            error.NoMatch => {},
            else => {
                std.debug.print("Error: {}\n", .{err});
                c.mg_http_reply(conn, 500, null, "");
            },
        }
    }
}

fn handleHttpRequest(_conn: ?*c.mg_connection, _data: ?*anyopaque, _file_names: ?*anyopaque) !void {
    var file_names = cast([][]const u8, _file_names orelse return error.NullFiles).*;

    var conn = _conn orelse return error.NullConnection;
    var data = _data orelse return error.NullEvData;

    var msg = cast(c.mg_http_message, data);
    var uri = msg.uri.ptr[0..msg.uri.len];

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var allocator = arena.allocator();

    for (file_names) |file_name| {
        defer _ = arena.reset(std.heap.ArenaAllocator.ResetMode.retain_capacity);

        var file = std.fs.cwd().openFile(file_name, .{}) catch |err| {
            std.debug.print("Error opening file {s}, {}\n", .{ file_name, err });
            continue;
        };
        defer file.close();

        var buffer = try file.readToEndAlloc(allocator, 1 << 30);

        var lua = try Lua.init(allocator);
        defer lua.deinit();

        var defn = try findDefinition(allocator, uri, buffer, lua, msg.*) orelse continue;
        defer defn.deinit();

        std.debug.print("Matched: {s}\n", .{defn.uri});

        const status_line = "HTTP/1.1 200 OK\r\nConnection: close\r\n";
        _ = c.mg_send(conn, status_line, status_line.len);
        for (defn.headers.items) |hdr| {
            _ = c.mg_send(conn, hdr.ptr, hdr.len);
            _ = c.mg_send(conn, "\r\n", 2);
        }

        var line_buf: [200]u8 = undefined;

        if (defn.body) |body| {
            var content_length = try std.fmt.bufPrint(&line_buf, "Content-Length: {d}\r\n", .{body.len});
            _ = c.mg_send(conn, content_length.ptr, content_length.len);
            _ = c.mg_send(conn, "\r\n", 2);
            _ = c.mg_send(conn, body.ptr, body.len);
        } else {
            _ = c.mg_send(conn, "\r\n", 2);
        }

        return;
    }

    std.debug.print("No Match for {s}\n", .{uri});
    c.mg_http_reply(conn, 404, null, "");
    return error.NoMatch;
}

const Lua = struct {
    L: *c.lua_State,
    allocator: std.mem.Allocator,

    // export fn body(L: ?*c.lua_State) c_int {
    //     c.lua_pushnumber(L, 12);
    //     return 1;
    // }

    pub fn init(allocator: std.mem.Allocator) !@This() {
        var L = c.luaL_newstate() orelse return error.LuaInitFailure;

        c.luaL_openlibs(L);

        // c.lua_pushcclosure(L, fff, 0);
        // c.lua_setglobal(L, "fff");

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

        if (c.luaL_loadstring(self.L, stmt.ptr) != 0) {
            std.debug.print("loadstring => {s}\n", .{c.lua_tolstring(self.L, -1, null)});
            return false;
        }

        if (c.lua_pcallk(self.L, 0, c.LUA_MULTRET, 0, 0, null) != 0) {
            std.debug.print("pcallk => {s}\n", .{c.lua_tolstring(self.L, -1, null)});
            return false;
        }

        return c.lua_toboolean(self.L, -1) != 0;
    }
};

test "lua scratch" {
    var lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    var cases = .{
        .{ true, "2 + 1" },
        .{ true, "true" },
        .{ true, "'some string'" },
        .{ false, "false" },
        .{ false, "null" },
        .{ false, "invalid lua code?" },
    };

    inline for (cases) |case| {
        try std.testing.expectEqual(case[0], lua.eval(case[1]));
    }
}

fn findDefinition(allocator: std.mem.Allocator, uri: []const u8, payload: []u8, lua: Lua, msg: c.mg_http_message) !?Definition {
    var found = false;

    var lines = std.mem.split(u8, payload, "\n");

    while (lines.next()) |line0| {
        var d: Definition = Definition.init(allocator);
        errdefer d.deinit();

        var trimmed0 = std.mem.trim(u8, line0, &std.ascii.whitespace);
        if (trimmed0.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed0, "#")) continue;

        d.uri = trimmed0;
        found = std.mem.eql(u8, uri, d.uri);
        var delim: []const u8 = undefined;
        var is_json = false;
        var content_start: usize = undefined;

        // Read headers?
        while (lines.next()) |line| {
            var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

            if (std.mem.startsWith(u8, trimmed, "#")) {
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "@")) {
                found = found and lua.eval(std.mem.trim(u8, trimmed[1..], &std.ascii.whitespace), msg);
                // var grd = std.mem.trim(u8, trimmed[1..], &std.ascii.whitespace);
                // try d.guards.append(grd);
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, ">")) {
                var hdr = std.mem.trim(u8, trimmed[1..], &std.ascii.whitespace);
                try d.headers.append(hdr);
                continue;
            }

            // Found a json payload, go to the read content section...
            if (std.mem.startsWith(u8, trimmed, "{")) {

                // Adds a JSON content-type header, if one hasn't already been
                // specified:
                for (d.headers.items) |hdr| {
                    // TODO: Technically would match "Content-Type-2",
                    // but maybe just don't do that for now?
                    if (std.ascii.startsWithIgnoreCase(hdr, "content-type")) {
                        break;
                    }
                } else {
                    try d.headers.append("Content-Type: application/json");
                }

                content_start = lines.index.? - line.len - 1;
                is_json = true;
                break;
            }

            // Found a delimeter, go to the read content section...
            delim = trimmed;
            content_start = lines.index.?;
            is_json = false;
            break;
        }

        if (is_json) {
            d.body = try readJsonContent(&lines, content_start);
        } else {
            d.body = try readDelimitedContent(&lines, delim, content_start);
        }

        if (found) {
            return d;
        }

        d.deinit();
    }

    return null;
}

fn readJsonContent(_lines: *std.mem.SplitIterator(u8), json_start_offset: usize) ![]const u8 {
    var lines = _lines;
    const payload = lines.buffer;

    const validate = std.json.validate;

    if (validate(payload[json_start_offset .. lines.index orelse payload.len])) {
        // We've already got a full, complete JSON payload
        return payload[json_start_offset .. lines.index orelse payload.len];
    }

    // Still more of the JSON message to go!
    while (lines.next()) |_| {
        if (validate(payload[json_start_offset .. lines.index orelse payload.len])) {
            return payload[json_start_offset .. lines.index orelse payload.len];
        }
    }

    return error.UnterminatedJSONPayload;
}

test "movePastJsonContent" {
    var payloads: [2][]const u8 =
        .{
        \\  { "one" :
        \\ true, "two":
        \\
        \\ [false, false, "FALLSE!"]}
        \\ Here's some other stuff
        ,
        \\ { "one": "two" }
    };

    for (payloads) |payload| {
        var lines = std.mem.split(u8, payload, "\n");

        var result = try readJsonContent(&lines, 0);
        _ = result;
    }
}

test "json validates with prefixed space" {
    var payload =
        \\   { "one":true,
        \\  "two":false
        \\}
    ;
    try std.testing.expectEqual(true, std.json.validate(payload));
}

fn readDelimitedContent(_lines: *std.mem.SplitIterator(u8), delimeter: []const u8, payload_start_offset: usize) ![]const u8 {
    var lines = _lines;
    const payload = lines.buffer;

    while (lines.next()) |line| {
        var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (std.mem.eql(u8, delimeter, trimmed)) {
            return payload[payload_start_offset .. (lines.index orelse payload.len) - delimeter.len - 1];
        }
    }

    return error.UnterminatedPayload;
}

pub fn main() !void {
    var opts = zopts.init(std.heap.page_allocator);
    defer opts.deinit();

    opts.name("simsim");
    opts.summary(
        \\Mocking HTTP server designed for simulating external APIs.
    );

    var host: []const u8 = "localhost";
    var port: u16 = 8080;
    var files: [][]const u8 = undefined;
    var show_help = false;

    try opts.flag(&host, .{ .name = "host", .short = 'h', .description = "Hostname or IP to listen on (defaults to localhost)." });
    try opts.flag(&port, .{ .name = "port", .short = 'p', .description = "Port to listen on (defaults to 8080)." });
    try opts.flag(&show_help, .{ .name = "help", .description = "Show this help message." });
    try opts.extra(&files, .{ .placeholder = "[FILE]", .description = "Files containing payload definitions, processed in order (default is 'payload')." });

    opts.parseOrDie();

    if (show_help) {
        opts.printHelpAndDie();
    }

    if (files.len == 0) {
        var default_files_array = [_][]const u8{"payload"};
        files = &default_files_array;
    }

    var listen_buf = [_:0]u8{0} ** 200;
    var listen_addr = try std.fmt.bufPrint(&listen_buf, "http://{s}:{d}", .{ host, port });

    std.debug.print("Starting up the server at {s}\n", .{listen_addr});
    for (files) |file| {
        std.debug.print("Definitions pulled from {s}\n", .{file});
    }

    var mgr: c.mg_mgr = undefined;

    c.mg_mgr_init(&mgr);
    defer c.mg_mgr_free(&mgr);

    _ = c.mg_http_listen(&mgr, listen_addr.ptr, callback, cast(anyopaque, &files));
    while (true) {
        c.mg_mgr_poll(&mgr, 1000);
    }
}
