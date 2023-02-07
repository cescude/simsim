const std = @import("std");
const ZOpts = @import("zopts");
const Lua = @import("lua.zig");

const externs = @import("externs.zig");
const c = externs.c;

fn cast(comptime T: type, op: anytype) *T {
    const a = @ptrToInt(op);
    const b = @intToPtr(*T, a);
    return b;
}

const Definition = struct {
    uri: []const u8,
    guards: std.ArrayList([]const u8),
    headers: std.ArrayList([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, uri: []const u8) Definition {
        return .{
            .uri = uri,
            .guards = std.ArrayList([]const u8).init(allocator),
            .headers = std.ArrayList([]const u8).init(allocator),
            .body = "",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: Definition) void {
        self.guards.deinit();
        self.headers.deinit();
    }

    pub fn match(self: Definition, msg: c.mg_http_message) !bool {
        if (!matchUris(self.uri, msg.uri.ptr[0..msg.uri.len])) {
            return false;
        }

        var lua = try Lua.init(self.allocator);
        defer lua.deinit();

        for (self.guards.items) |grd| {
            if (!lua.eval(grd, msg)) return false;
        }

        return true;
    }
};

test "matchUris" {
    try std.testing.expect(matchUris("one/*/three", "one/two/three"));
    try std.testing.expect(matchUris("/one", "/one"));
    try std.testing.expect(!matchUris("/one", "/one/"));
    try std.testing.expect(!matchUris("/one/", "/one"));
    try std.testing.expect(matchUris("/*/*/what", "/one/two/what"));
    try std.testing.expect(!matchUris("/one/two/*", "/one/two/three/four"));
}

fn matchUris(pattern: []const u8, uri: []const u8) bool {
    var piter = std.mem.split(u8, pattern, "/");
    var uiter = std.mem.split(u8, uri, "/");

    while (true) {
        var pattern_segment = piter.next();
        var uri_segment = uiter.next();

        if (pattern_segment == null and uri_segment == null) {
            return true;
        }

        if (pattern_segment == null or uri_segment == null) {
            return false;
        }

        if (std.mem.eql(u8, pattern_segment.?, "*")) {
            continue;
        }

        if (!std.mem.eql(u8, pattern_segment.?, uri_segment.?)) {
            return false;
        }
    }
}

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

        var defn = try findDefinition(allocator, buffer, msg.*) orelse continue;
        defer defn.deinit();

        std.debug.print("Matched: {s}", .{defn.uri});
        if (file_names.len > 1) {
            std.debug.print(" ({s})", .{file_name});
        }
        std.debug.print("\n", .{});

        _ = c.mg_printf(conn, "HTTP/1.1 200 OK\r\n");
        for (defn.headers.items) |hdr| {
            _ = c.mg_printf(conn, "%.*s\r\n", hdr.len, hdr.ptr);
        }

        _ = c.mg_printf(conn, "Content-Length: %d\r\n\r\n%.*s", defn.body.len, defn.body.len, defn.body.ptr);
        c.mg_finish_resp(conn);
        return;
    }

    std.debug.print("No Match for {s}\n", .{uri});
    c.mg_http_reply(conn, 404, "", "");

    return error.NoMatch;
}

fn findDefinition(allocator: std.mem.Allocator, payload: []const u8, msg: c.mg_http_message) !?Definition {
    var lines = std.mem.split(u8, payload, "\n");

    while (lines.next()) |line| {
        var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;

        var defn: Definition = Definition.init(allocator, trimmed);
        errdefer defn.deinit();

        try readDefinition(&defn, &lines);

        // Add a Content-Type header (if one hasn't already been added)
        for (defn.headers.items) |hdr| {
            var hdrator = std.mem.split(u8, hdr, ":");
            if (std.ascii.eqlIgnoreCase(hdrator.first(), "Content-Type")) {
                break;
            }
        } else {
            if (std.mem.startsWith(u8, defn.body, "{")) {
                try defn.headers.append("Content-Type: application/json");
            }
        }

        if (try defn.match(msg)) {
            return defn;
        }

        defn.deinit();
    }

    return null;
}

fn readDefinition(defn: *Definition, lines: *std.mem.SplitIterator(u8)) !void {
    var delim: ?[]const u8 = null;
    var is_json = false;
    var content_start: usize = undefined;

    // Read headers?
    while (lines.next()) |line| {
        var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "#")) {
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "@")) {
            var grd = std.mem.trim(u8, trimmed[1..], &std.ascii.whitespace);
            try defn.guards.append(grd);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, ">")) {
            var hdr = std.mem.trim(u8, trimmed[1..], &std.ascii.whitespace);
            try defn.headers.append(hdr);
            continue;
        }

        // Found a json payload, go to the read content section...
        if (std.mem.startsWith(u8, trimmed, "{")) {
            content_start = (lines.index orelse lines.buffer.len) - line.len - 1;
            is_json = true;
            break;
        }

        // Found a delimeter, go to the read content section...
        delim = trimmed;
        content_start = (lines.index orelse lines.buffer.len);
        is_json = false;
        break;
    }

    if (is_json) {
        defn.body = std.mem.trim(u8, try readJsonContent(lines, content_start), &std.ascii.whitespace);
    } else if (delim) |_| {
        defn.body = try readDelimitedContent(lines, delim.?, content_start);
    }
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
    var payloads =
        [_][]const u8{
        \\  { "one" :
        \\ true, "two":
        \\
        \\ [false, false, "FALLSE!"]}
        \\ Here's some other stuff
        ,
        \\ { "one": "two" }
        ,
        "{\"one\":\n\"no ending newline\"}",
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
    var zopts = ZOpts.init(std.heap.page_allocator);
    defer zopts.deinit();

    zopts.name("simsim");
    zopts.summary(
        \\Maybe an easy HTTP server mocker.
    );

    var host: []const u8 = "localhost";
    var port: u16 = 3131;
    var files: [][]const u8 = undefined;
    var show_help = false;

    try zopts.flag(&host, .{ .name = "host", .short = 'h', .description = "Hostname or IP to listen on (defaults to localhost)." });
    try zopts.flag(&port, .{ .name = "port", .short = 'p', .description = "Port to listen on (defaults to 3131)." });
    try zopts.flag(&show_help, .{ .name = "help", .description = "Show this help message." });
    try zopts.extra(&files, .{ .placeholder = "[FILE]", .description = "Files containing payload definitions, processed in order (default is 'payload')." });

    zopts.parseOrDie();

    if (show_help) {
        zopts.printHelpAndDie();
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
