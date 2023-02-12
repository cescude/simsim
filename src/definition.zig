const std = @import("std");
const externs = @import("externs.zig");
const c = externs.c;

const Lua = @import("lua.zig");

uri: []const u8,
guards: std.ArrayList([]const u8),
headers: std.ArrayList([]const u8),
body: []const u8,
allocator: std.mem.Allocator,

const Definition = @This();

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

        if (std.mem.eql(u8, pattern_segment.?, "**")) {
            pattern_segment = piter.next();

            if (pattern_segment == null) {
                // Expansion wildcard was at the tail of the pattern,
                // so it matches the rest of the uri regardless of the
                // uri's contents.
                return true;
            }

            while (true) {
                uri_segment = uiter.next();

                if (uri_segment == null) {
                    return false;
                }

                if (std.mem.eql(u8, pattern_segment.?, uri_segment.?)) {
                    break;
                }
            }

            continue;
        }

        if (!std.mem.eql(u8, pattern_segment.?, uri_segment.?)) {
            return false;
        }
    }
}

test "matchUris basic" {
    try std.testing.expect(matchUris("one/*/three", "one/two/three"));
    try std.testing.expect(matchUris("/one", "/one"));
    try std.testing.expect(!matchUris("/one", "/one/"));
    try std.testing.expect(!matchUris("/one/", "/one"));
}

test "matchUris wildcards" {
    try std.testing.expect(matchUris("/*/*/what", "/one/two/what"));
    try std.testing.expect(!matchUris("/one/two/*", "/one/two/three/four"));
}

test "matchUris expansions" {
    try std.testing.expect(matchUris("/one/**/four", "/one/two/three/four"));
    try std.testing.expect(matchUris("/one/**", "/one/two/three/four"));
    try std.testing.expect(matchUris("/one/**/four/**/eight", "/one/two/three/four/five/six/seven/eight"));
    try std.testing.expect(!matchUris("/one/**/one", "/one/one")); // ** doesn't match zero segments
}
