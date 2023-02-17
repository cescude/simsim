const std = @import("std");
const externs = @import("externs.zig");
const c = externs.c;
const Definition = @import("definition.zig");
const Lua = @import("lua.zig");
const Payload = @This();

name: []const u8,
stat: ?std.fs.Dir.Stat,
data: []u8, // All the bytes in the file, used as backing memory for the definitions.
defns: []Definition,
lua: Lua,
arena: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator, file_name: []const u8) !Payload {
    // Use an arena for data and defns...if we clear one we should
    // clear them all.
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    // However, lua should be managed separately. It's ok to just
    // initialize this and then keep it allocated for the lifetime of
    // this payload.
    var lua = try Lua.init(allocator);
    errdefer lua.deinit();

    return .{
        .name = file_name,
        .stat = null,
        .data = "",
        .lua = lua,
        .defns = &[0]Definition{},
        .arena = arena,
    };
}

pub fn deinit(self: *Payload) void {
    defer self.arena.deinit();
    defer self.lua.deinit();
}

pub fn loadDefinitions(self: *Payload) !void {
    var stat = try std.fs.cwd().statFile(self.name);
    if (self.stat) |self_stat| {
        if (stat.size == self_stat.size and stat.mtime == self_stat.mtime) {
            // No change according to the size/mtime, so skip the read
            return;
        }
    }

    std.debug.print("Reading definitions from {s}\n", .{self.name});

    // Invalidate all memory allocated within this Payload (data, defns, etc)
    _ = self.arena.reset(std.heap.ArenaAllocator.ResetMode.retain_capacity);

    // Also, if an error occurs below, just cancel everything and
    // empty out this payload.
    errdefer {
        _ = self.arena.reset(std.heap.ArenaAllocator.ResetMode.retain_capacity);
        self.stat = null;
        self.data = "";
        self.defns = &[0]Definition{};
    }

    var file = try std.fs.cwd().openFile(self.name, .{});
    defer file.close();

    self.stat = stat;
    self.data = try file.readToEndAlloc(self.arena.allocator(), 1 << 30);
    self.defns = try readAllDefinitionsAlloc(self.arena.allocator(), self.data);
}

fn readAllDefinitionsAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]Definition {
    var definitions = std.ArrayList(Definition).init(allocator);
    errdefer {
        for (definitions.items) |defn| {
            defn.deinit();
        }
        definitions.deinit();
    }

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

        try definitions.append(defn);
    }

    return try definitions.toOwnedSlice();
}

fn readDefinition(defn: *Definition, lines: *std.mem.SplitIterator(u8)) !void {
    var content_start: usize = undefined;

    // Read guards until we find a body
    while (lines.next()) |line| {
        var trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        if (trimmed.len == 0) {
            defn.body = "";
            return;
        }
        if (std.mem.startsWith(u8, trimmed, "#")) {
            continue;
        }

        if (isStatusLine(trimmed)) {
            if (defn.status_line == null) {
                defn.status_line = trimmed;
            } else {
                return error.DuplicateStatusLinesInDefinition;
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "@")) {
            var guard = std.mem.trim(u8, trimmed[1..], &std.ascii.whitespace);
            try defn.guards.append(guard);
            continue;
        }

        // Found a json payload, read content until we have a valid JSON object
        if (std.mem.startsWith(u8, trimmed, "{")) {
            content_start = (lines.index orelse lines.buffer.len) - line.len - 1;
            defn.body = std.mem.trim(u8, try readJsonContent(lines, content_start), &std.ascii.whitespace);
            return;
        }

        // Or perhaps it's a header definition...
        if (std.mem.indexOfScalar(u8, trimmed, ':') != null) {
            try defn.headers.append(trimmed);
            continue;
        }

        // OK, if it's none of the above, `trimmed` is a delimeter.
        // Read content section until we find another copy of it
        content_start = (lines.index orelse lines.buffer.len);
        defn.body = try readDelimitedContent(lines, trimmed, content_start);
        return;
    }

    // If we ran out of lines, just assume an empty body
    defn.body = "";
}

// line should be something like "200 OK" or "404 Not Found"
fn isStatusLine(line: []const u8) bool {
    return line.len > 3 and std.ascii.isWhitespace(line[3]) and std.mem.lessThan(u8, "099", line[0..3]) and std.mem.lessThan(u8, line[0..3], "600");
}

test "isStatusLine" {
    try std.testing.expect(isStatusLine("200 OK"));
    try std.testing.expect(isStatusLine("404 Not Found"));
    try std.testing.expect(isStatusLine("100 Info time"));
    try std.testing.expect(isStatusLine("599 Really?"));
    try std.testing.expect(!isStatusLine("99 Invalid"));
    try std.testing.expect(!isStatusLine("9   Ok"));
    try std.testing.expect(!isStatusLine("600 Bad times"));
    try std.testing.expect(!isStatusLine("    Ok then"));
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

pub fn findDefinition(self: Payload, msg: c.mg_http_message) !?Definition {
    return try findDefinitionInArray(self.defns, self.lua, msg);
}

fn findDefinitionInArray(defns: []const Definition, lua: Lua, msg: c.mg_http_message) !?Definition {
    for (defns) |defn| {
        if (try defn.match(lua, msg)) {
            return defn;
        }
    }

    return null;
}

// Everything below here is for testing

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
    var defns = try readAllDefinitionsAlloc(allocator, payload);
    defer {
        for (defns) |defn| {
            defn.deinit();
        }
        allocator.free(defns);
    }

    var lua = try Lua.init(allocator);
    defer lua.deinit();

    for (cases) |case, idx| {
        if (try findDefinitionInArray(defns, lua, case[0])) |defn| {
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
        .{ mkmsg("/path/hmm/perhaps/ok", "", ""), resultStr("19") },
        .{ mkmsg("/path/hmm/perhaps/ok/let/us/add/more/here/though", "", ""), resultStr("20") },
    };

    try verifyTestCases(std.testing.allocator, payload, &cases);
}

test "Response headers are transmitted properly" {
    const payload: []const u8 = @embedFile("example.payload");

    var defns = try readAllDefinitionsAlloc(std.testing.allocator, payload);
    defer {
        for (defns) |defn| {
            defn.deinit();
        }
        std.testing.allocator.free(defns);
    }

    var lua = try Lua.init(std.testing.allocator);

    if (try findDefinitionInArray(defns, lua, mkmsg("/test/json", "", ""))) |defn| {
        // Three headers (two defined + Content-type added)
        try std.testing.expectEqual(@as(usize, 3), defn.headers.items.len);
        try std.testing.expectEqualSlices(u8, "X-Response-Type: 1", defn.headers.items[0]);
        try std.testing.expectEqualSlices(u8, "X-Another-Header: Here", defn.headers.items[1]);
        try std.testing.expectEqualSlices(u8, "Content-Type: application/json", defn.headers.items[2]);
    }

    if (try findDefinitionInArray(defns, lua, mkmsg("/test/raw", "", ""))) |defn| {
        // Just one header defined (not a JSON body, so no implicit content-type added)
        try std.testing.expectEqual(@as(usize, 1), defn.headers.items.len);
        try std.testing.expectEqualSlices(u8, "X-Response-Type: 2", defn.headers.items[0]);
        try std.testing.expectEqualSlices(u8, "1,2,3\n4,5,6\n", defn.body);
    }
}
