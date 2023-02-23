const std = @import("std");
const ZOpts = @import("zopts");
const Http = @import("http.zig");
const Definition = @import("definition.zig");
const Payload = @import("payload.zig");
const externs = @import("externs.zig");
const stdout = @import("stdout.zig");
const c = externs.c;

test {
    // Needed to pick up downstream tests
    _ = Payload;
    _ = Definition;
    _ = Http;
}

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

    stdout.print("Starting up the server at http://{s}:{}\n", .{ host, port });

    var payloads = try std.heap.page_allocator.alloc(Payload, files.len);
    defer std.heap.page_allocator.free(payloads);

    for (files, 0..) |file_name, i| {
        payloads[i] = try Payload.init(std.heap.page_allocator, file_name);
    }
    defer {
        for (payloads) |*payload| {
            payload.deinit();
        }
    }

    try Http.serve([]Payload, .{
        .addr = host,
        .port = port,
        .data = payloads,
        .user_callback = handleHttpRequest,
        .tick = 100,
        .tick_callback = stdout.flush,
    });
}

fn handleHttpRequest(conn: *c.mg_connection, msg: *c.mg_http_message, payloads: []Payload) void {
    var uri = msg.uri.ptr[0..msg.uri.len];

    for (payloads) |*payload| {
        payload.loadDefinitions() catch |err| {
            stdout.print("Error refreshing file data for {s}, {}\n", .{ payload.name, err });
            continue;
        };

        var result = payload.findDefinition(msg.*) catch |err| {
            stdout.print("Error while searching for definition {}\n", .{err});
            continue;
        } orelse continue;

        const defn = result[0];
        const idx = result[1];

        if (payloads.len > 1) {
            stdout.print("Matched #{} {s} ({s})\n", .{ idx + 1, defn.uri, payload.name });
        } else {
            stdout.print("Matched #{} {s}\n", .{ idx + 1, defn.uri });
        }

        if (defn.status_line) |status_line| {
            _ = c.mg_printf(conn, "HTTP/1.1 %.*s\r\n", status_line.len, status_line.ptr);
        } else {
            _ = c.mg_printf(conn, "HTTP/1.1 200 OK\r\n");
        }

        for (defn.headers.items) |hdr| {
            _ = c.mg_printf(conn, "%.*s\r\n", hdr.len, hdr.ptr);
        }

        // If the location header is provided as a prefix, we should
        // append the requested path.
        if (defn.location_prefix) |location_prefix| {
            _ = c.mg_printf(conn, "%.*s%.*s\r\n", location_prefix.len, location_prefix.ptr, msg.uri.len, msg.uri.ptr);
        }

        _ = c.mg_printf(conn, "Content-Length: %d\r\n\r\n%.*s", defn.body.len, defn.body.len, defn.body.ptr);
        c.mg_finish_resp(conn);
        return;
    }

    stdout.print("No Match for {s}\n", .{uri});
    c.mg_http_reply(conn, 404, "", "");
}
