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

        var defn = findDefinition(allocator, buffer, msg.*) catch |err| {
            std.debug.print("Error while searching for definition {}\n", .{err});
            continue;
        } orelse continue;
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

fn mkmsg(full_path: []const u8, headers: []const u8, body: []const u8) c.mg_http_message {
    var iter: std.mem.SplitIterator(u8) = undefined;
    var req: c.mg_http_message = undefined;

    iter = std.mem.split(u8, full_path, "?");
    var path = iter.next().?;
    var query = iter.rest();

    req.uri = .{ .ptr = path.ptr, .len = path.len };
    req.query = .{ .ptr = query.ptr, .len = query.len };

    iter = std.mem.split(u8, headers, "\r\n");
    var i: usize = 0;
    while (iter.next()) |hdr_pair| {
        var jter = std.mem.split(u8, hdr_pair, ":");
        var name = jter.next().?;
        var value = jter.rest();

        req.headers[i].name = .{ .ptr = name.ptr, .len = name.len };
        req.headers[i].value = .{ .ptr = value.ptr, .len = value.len };
        i += 1;
    }

    req.body = .{ .ptr = body.ptr, .len = body.len };

    return req;
}

fn resultStr(comptime r: []const u8) []const u8 {
    return "{\"result\": " ++ r ++ "}";
}

const TestCase = struct { c.mg_http_message, []const u8 };

fn verifyTestCases(allocator: std.mem.Allocator, payload: []const u8, cases: []TestCase) !void {
    for (cases) |case, idx| {
        if (try findDefinition(allocator, payload, case[0])) |defn| {
            defer defn.deinit();
            try std.testing.expectEqualSlices(u8, case[1], defn.body);
        } else {
            std.debug.print("Case #{d} failed, no matching definition found!\n", .{idx + 1});
            try std.testing.expect(false);
        }
    }
}

test "Generic cases" {
    const payload: []const u8 = @embedFile("example.payload");

    comptime var cases = [_]TestCase{
        .{ mkmsg("/test/json", "", ""), resultStr("1") },
        .{ mkmsg("/test/raw", "", ""), "1,2,3\n4,5,6\n" },
        .{ mkmsg("/lua/comparison", "", ""), resultStr("2") },
    };

    try verifyTestCases(std.testing.allocator, payload, &cases);
}

test "Lua: Query string guards" {
    const payload: []const u8 = @embedFile("example.payload");

    comptime var cases = [_]TestCase{
        .{ mkmsg("/query?ok=indeed", "", ""), resultStr("3") },
        .{ mkmsg("/query?ok=maybe", "", ""), resultStr("4") },
        .{ mkmsg("/query?abc=def&ok=maybe&ghi=jkl", "", ""), resultStr("4") },
    };

    try verifyTestCases(std.testing.allocator, payload, &cases);
}

test "Lua: JSON body guards" {
    const payload: []const u8 = @embedFile("example.payload");

    comptime var cases = [_]TestCase{
        .{ mkmsg("/json/body", "", "{\"ok\": \"indeed\"}"), resultStr("5") },
        .{ mkmsg("/json/body", "", "{\"ok\": \"maybe?\"}"), resultStr("6") },
        .{ mkmsg("/json/body", "", "{\"nope\": \"indeed\"}"), resultStr("7") },
    };

    try verifyTestCases(std.testing.allocator, payload, &cases);
}

test "Lua: Form body guards" {
    const payload: []const u8 = @embedFile("example.payload");

    comptime var cases = [_]TestCase{
        .{ mkmsg("/form/body", "", "ok=indeed"), resultStr("8") },
        .{ mkmsg("/form/body", "", "ok=maybe"), resultStr("9") },
        .{ mkmsg("/form/body", "", "nope=indeed"), resultStr("10") },
    };

    try verifyTestCases(std.testing.allocator, payload, &cases);
}

test "Wildcard path matching" {
    const payload: []const u8 = @embedFile("example.payload");

    comptime var cases = [_]TestCase{
        .{ mkmsg("/wildcard/anything/def/ghi", "", ""), resultStr("11") },
        .{ mkmsg("/wildcard/abc/anything/ghi", "", ""), resultStr("12") },
        .{ mkmsg("/wildcard/anything_at_all", "", ""), resultStr("13") },
    };

    try verifyTestCases(std.testing.allocator, payload, &cases);
}

test "Lua: Request headers" {
    const payload: []const u8 = @embedFile("example.payload");

    comptime var cases = [_]TestCase{
        .{ mkmsg("/headers/switch", "X-Response-Type:1\r\n", ""), resultStr("14") }, // case 14 uses camel-case bareword thing
        .{ mkmsg("/headers/switch", "X-Response-Type:2\r\n", ""), resultStr("15") }, // case 15 uses table string lookup
        .{ mkmsg("/headers/switch", "x-RESPONSE-type:1\r\n", ""), resultStr("14") }, // case 14 is case insensitive
        .{ mkmsg("/headers/switch", "x-RESPONSE-type:2\r\n", ""), resultStr("16") }, // string lookup is case sensitive
    };

    try verifyTestCases(std.testing.allocator, payload, &cases);
}

test "Lua: Path segments" {
    const payload = @embedFile("example.payload");

    comptime var cases = [_]TestCase{
        .{ mkmsg("/path/get/ok", "", ""), resultStr("17") },
        .{ mkmsg("/path/hmm/ok", "", ""), resultStr("18") },
    };

    try verifyTestCases(std.testing.allocator, payload, &cases);
}

test "Response headers are transmitted properly" {
    const payload: []const u8 = @embedFile("example.payload");

    if (try findDefinition(std.testing.allocator, payload, mkmsg("/test/json", "", ""))) |defn| {
        defer defn.deinit();

        // Three headers (two defined + Content-type added)
        try std.testing.expectEqual(@as(usize, 3), defn.headers.items.len);
        try std.testing.expectEqualSlices(u8, "X-Response-Type: 1", defn.headers.items[0]);
        try std.testing.expectEqualSlices(u8, "X-Another-Header: Here", defn.headers.items[1]);
        try std.testing.expectEqualSlices(u8, "Content-Type: application/json", defn.headers.items[2]);
    }

    if (try findDefinition(std.testing.allocator, payload, mkmsg("/test/raw", "", ""))) |defn| {
        defer defn.deinit();

        // Just one header defined (not a JSON body, so no implicit content-type added)
        try std.testing.expectEqual(@as(usize, 1), defn.headers.items.len);
        try std.testing.expectEqualSlices(u8, "X-Response-Type: 2", defn.headers.items[0]);
        try std.testing.expectEqualSlices(u8, "1,2,3\n4,5,6\n", defn.body);
    }
}
