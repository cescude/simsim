const std = @import("std");

var stdout_writer = std.io.bufferedWriter(std.io.getStdOut().writer());
var stdout = stdout_writer.writer();

// This module defines a rate limited, buffered printer. Right now
// hardcoded to flush no more frequently than every 100ms (unless the
// buffer fills, obviously).

pub fn print(comptime fmt: []const u8, arg: anytype) void {
    stdout.print(fmt, arg) catch {};
}

var timer: ?std.time.Timer = null;

pub fn flush() void {
    if (timer) |*t| {
        if (t.read() < 100_000_000) {
            return;
        }
        t.reset();
    } else {
        timer = std.time.Timer.start() catch return;
    }

    stdout_writer.flush() catch {};
}
