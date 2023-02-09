const std = @import("std");
const ZOpts = @import("zopts");
const Http = @import("http.zig");
const Definition = @import("definition.zig");

const externs = @import("externs.zig");
const c = externs.c;

pub fn main() !void {
    var zopts = ZOpts.init(std.heap.page_allocator);
    defer zopts.deinit();

    zopts.name("simsim");
    zopts.summary(
        \\Maybe an easy to use mocking HTTP server?
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

    std.debug.print("Starting up the server at http://{s}:{}\n", .{ host, port });
    for (files) |file| {
        std.debug.print("Definitions pulled from {s}\n", .{file});
    }

    try Http.serve(host, port, [][]const u8, files, handleHttpRequest);
}

fn handleHttpRequest(conn: *c.mg_connection, msg: *c.mg_http_message, file_names: [][]const u8) void {
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

        var buffer = file.readToEndAlloc(allocator, 1 << 30) catch |err| {
            std.debug.print("Error reading file {s}, {}\n", .{ file_name, err });
            continue;
        };

        var defn = findDefinition(allocator, buffer, msg.*) catch |err| switch (err) {
            error.NoMatchingDefinition => continue,
            else => {
                std.debug.print("Error while searching for definition {}\n", .{err});
                continue;
            },
        };
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
}

fn findDefinition(allocator: std.mem.Allocator, payload: []const u8, msg: c.mg_http_message) !Definition {
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

    return error.NoMatchingDefinition;
}

fn readDefinition(defn: *Definition, lines: *std.mem.SplitIterator(u8)) !void {
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

        // Found a json payload, read content until we have a valid JSON object
        if (std.mem.startsWith(u8, trimmed, "{")) {
            content_start = (lines.index orelse lines.buffer.len) - line.len - 1;
            defn.body = std.mem.trim(u8, try readJsonContent(lines, content_start), &std.ascii.whitespace);
            return;
        }

        // `trimmed` is a delimeter, read content section until we find another copy of it
        content_start = (lines.index orelse lines.buffer.len);
        defn.body = try readDelimitedContent(lines, trimmed, content_start);
        return;
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

test "std.json validates with prefixed space" {
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
