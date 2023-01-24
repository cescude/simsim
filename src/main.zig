const std = @import("std");
const c = @cImport({
    @cInclude("mongoose.h");
});

fn cast(comptime T: type, op: anytype) *T {
    const a = @ptrToInt(op);
    const b = @intToPtr(*T, a);
    return b;
}

const Definition = struct {
    uri: []const u8 = undefined,

    // num_guards: usize = 0,
    // guards: [20][]const u8 = undefined,

    headers: std.ArrayList([]const u8) = undefined,

    body: ?[]const u8 = null,

    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .uri = undefined,
            .headers = std.ArrayList([]const u8).init(alloc),
            .body = null,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: @This()) void {
        self.headers.deinit();
    }
};

export fn callback(conn: ?*c.mg_connection, ev: c_int, ev_data: ?*anyopaque, _: ?*anyopaque) void {
    if (ev == c.MG_EV_HTTP_MSG) {
        if (handleHttpRequest(conn, ev_data)) {
            // Nothing to do!
        } else |err| {
            std.debug.print("Error: {}\n", .{err});
            c.mg_http_reply(conn, 404, "Content-Type: text/plain\r\n", "Nope");
        }
    }
}

fn handleHttpRequest(_conn: ?*c.mg_connection, _data: ?*anyopaque) !void {
    var file = try std.fs.cwd().openFile("payload", .{});
    defer file.close();

    var conn = _conn orelse return error.NullConnection;
    var data = _data orelse return error.NullEvData;

    var msg = cast(c.mg_http_message, data);
    var uri = msg.uri.ptr[0..msg.uri.len];

    var buffer = try file.readToEndAlloc(std.heap.c_allocator, 1 << 30);
    defer std.heap.c_allocator.free(buffer);

    var defn = try findDefinition(uri, buffer);
    defer defn.deinit();

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

    std.debug.print("Matched: {s}\n", .{defn.uri});
}

fn findDefinition(uri: []const u8, payload: []u8) !Definition {
    var found = false;

    var lines = std.mem.split(u8, payload, "\n");

    while (lines.next()) |line0| {
        var d: Definition = Definition.init(std.heap.c_allocator);
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

    return error.notFound;
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
        std.debug.print("foundjson={s}\n", .{result});
    }
}

test "json validates with prefixed space" {
    var payload =
        \\   { "one":true,
        \\  "two":false
        \\}
    ;
    std.debug.print("payload=\n{s}\n", .{payload});
    std.debug.print("valid={}\n", .{std.json.validate(payload)});
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
