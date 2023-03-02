const std = @import("std");

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

pub fn reflowText(a: std.mem.Allocator, text: []const u8, width: usize) ReflowTextIterator {
    return ReflowTextIterator.init(a, text, width);
}

/// Iterator that wraps text around the indicated column length;
pub const ReflowTextIterator = struct {
    allocator: std.mem.Allocator,
    current_line: std.ArrayList(u8),
    token_iterator: std.mem.TokenIterator(u8),
    width: usize,
    token: ?[]const u8,

    const Self = @This();

    pub fn init(a: std.mem.Allocator, text: []const u8, width: usize) Self {
        return .{
            .allocator = a,
            .current_line = std.ArrayList(u8).init(a),
            .token_iterator = std.mem.tokenize(u8, text, " \t\r\n"),
            .width = width,
            .token = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.current_line.deinit();
    }

    pub fn next(self: *Self) !?[]const u8 {
        self.current_line.deinit();
        self.current_line = std.ArrayList(u8).init(self.allocator);

        var line = &self.current_line;

        while (true) {
            if (self.token == null) {
                self.token = self.token_iterator.next();
            }

            if (self.token) |word| {
                if (line.items.len == 0 and word.len > self.width) {
                    try line.appendSlice(word); // Just return the single word
                    self.token = null;
                    return line.items;
                } else if (line.items.len + word.len + 1 > self.width) {
                    return line.items;
                } else {
                    if (line.items.len > 0) {
                        try line.append(' ');
                    }
                    try line.appendSlice(word);
                    self.token = null;
                }
            } else break;
        }

        return if (line.items.len > 0) line.items else null;
    }
};

test "Reflow paragraph text" {
    var text =
        \\One two three four five six seven eight nine ten eleven twelve thirteen
        \\fourteen fifteen sixteen seventeen eighteen nineteen AND tweeeeenty!
    ;

    var iter = ReflowTextIterator.init(std.testing.allocator, text, 40);
    defer iter.deinit();

    std.debug.print("\n", .{});
    while (try iter.next()) |line| {
        std.debug.print(">>{d: >5} {s}\n", .{ line.len, line });
        try expect(line.len <= 40);
    }
}
