const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

fn contains(comptime T: type, needle: []const T, haystack: [][]const T) bool {
    for (haystack) |hay| {
        if (std.mem.eql(T, needle, hay)) {
            return true;
        }
    }

    return false;
}

fn truthValue(val: []const u8) !bool {
    var truly: [5][]const u8 = .{ "true", "yes", "on", "y", "1" };
    var falsy: [5][]const u8 = .{ "false", "no", "off", "n", "0" };

    if (contains(u8, val, truly[0..])) {
        return true;
    }

    if (contains(u8, val, falsy[0..])) {
        return false;
    }

    return error.ParseError;
}

ptr: usize,
conv_fn: ConvFn,
tag: ?[]const u8,

const FlagConverter = @This();

const ConvFn = *const fn (ptr: usize, value: []const u8) error{ParseError}!void;
const SameStrFn = *const fn (ptr0: usize, value: []const u8) bool;

// T can be bool, or ?bool
fn _convertBool(comptime T: type, p: *T, value: []const u8) !void {
    var v = p;
    v.* = try truthValue(value);
}

// T can be []const u8, or ?[]const u8
fn _convertStr(comptime T: type, p: *T, value: []const u8) !void {
    var v = p;
    v.* = value;
}

// T can be C, or ?C
fn _convertNum(comptime T: type, comptime C: type, p: *T, value: []const u8) !void {
    var v = p;
    const info = @typeInfo(C);
    v.* = switch (info) {
        .Int => switch (info.Int.signedness) {
            .signed => std.fmt.parseInt(C, value, 10) catch return error.ParseError,
            .unsigned => std.fmt.parseUnsigned(C, value, 10) catch return error.ParseError,
        },
        else => @compileError("Unsupported number type: " ++ @typeName(C)),
    };
}

fn _convertEnum(comptime T: type, comptime C: type, p: *T, value: []const u8) !void {
    var v = p;
    const info = @typeInfo(C);
    switch (info) {
        .Enum => {
            inline for (info.Enum.fields) |field| {
                if (std.ascii.eqlIgnoreCase(field.name, value)) {
                    v.* = @intToEnum(C, field.value);
                    return;
                }
            }

            return error.ParseError;
        },
        else => unreachable,
    }
}

fn joinedEnumSpace(comptime C: type) usize {
    comptime {
        const names = std.meta.fieldNames(C);
        var sz: comptime_int = 0;
        for (names) |name| {
            sz += name.len;
        }
        // (one|two|three) is
        //   onetwothree (11) +
        //   () (2) +
        //   || (3-1)
        return sz + 2 + names.len - 1;
    }
}

fn joinedEnumVals(comptime C: type) *const [joinedEnumSpace(C)]u8 {
    comptime {
        const names = std.meta.fieldNames(C);
        var joined: [joinedEnumSpace(C)]u8 = undefined;
        var offset = 0;

        joined[offset] = '(';
        offset += 1;

        for (names, 0..) |name, idx| {
            if (idx > 0) {
                joined[offset] = '|';
                offset += 1;
            }

            std.mem.copy(u8, joined[offset..], name);
            offset += name.len;
        }

        joined[offset] = ')';

        return &joined;
    }
}

pub fn init(ptr: anytype) FlagConverter {
    const T = @typeInfo(@TypeOf(ptr)).Pointer.child; // ptr must be a pointer!
    const C: type = switch (@typeInfo(T)) {
        .Optional => @typeInfo(T).Optional.child,
        else => T,
    };

    const info = @typeInfo(C);

    const impl = struct {
        pub fn convert(p: usize, value: []const u8) error{ParseError}!void {
            switch (info) {
                .Bool => try _convertBool(T, @intToPtr(*T, p), value),
                .Pointer => try _convertStr(T, @intToPtr(*T, p), value),
                .Int => try _convertNum(T, C, @intToPtr(*T, p), value),
                .Enum => try _convertEnum(T, C, @intToPtr(*T, p), value),
                else => @compileError("Unsupported type " ++ @typeName(T)),
            }
        }
    };

    const can_convert: bool = switch (info) {
        .Bool, .Int, .Enum => true,
        // Only if it's a pointer to a []const u8
        .Pointer => info.Pointer.size == .Slice and info.Pointer.is_const and info.Pointer.child == u8,
        else => false,
    };

    if (!can_convert) {
        @compileError("Unsupported type " ++ @typeName(T));
    }

    const short_tag = switch (info) {
        .Bool => null,
        .Int => "NUM",
        .Pointer => "STR",
        .Enum => joinedEnumVals(C),
        else => unreachable,
    };

    return FlagConverter{
        .ptr = @ptrToInt(ptr),
        .conv_fn = impl.convert,
        .tag = short_tag,
    };
}

test "Typed/Generic flag conversion functionality" {
    var b0: bool = false;
    var b0c = FlagConverter.init(&b0);
    try b0c.conv_fn(b0c.ptr, "true");
    try expect(b0);

    var b1: ?bool = null;
    var b1c = FlagConverter.init(&b1);
    try b1c.conv_fn(b1c.ptr, "yes");
    try expect(b1.?);
    try b1c.conv_fn(b1c.ptr, "no");
    try expect(!b1.?);

    var uu0: u15 = 0;
    var uu0c = FlagConverter.init(&uu0);
    try uu0c.conv_fn(uu0c.ptr, "12");
    try expect(uu0 == 12);
    try expectError(error.ParseError, uu0c.conv_fn(uu0c.ptr, "-12"));
    try expectError(error.ParseError, uu0c.conv_fn(uu0c.ptr, "7000000"));

    var uu1: ?u8 = null;
    var uu1c = FlagConverter.init(&uu1);
    try uu1c.conv_fn(uu1c.ptr, "12");
    try expect(uu1.? == 12);
    try expectError(error.ParseError, uu1c.conv_fn(uu1c.ptr, "-12"));
    try expectError(error.ParseError, uu1c.conv_fn(uu1c.ptr, "7000000"));

    var ii0: i7 = 0;
    var ii0c = FlagConverter.init(&ii0);
    try ii0c.conv_fn(ii0c.ptr, "-60");
    try expect(ii0 == -60);
    try expectError(error.ParseError, ii0c.conv_fn(ii0c.ptr, "7000000"));

    var ii1: ?i7 = 0;
    var ii1c = FlagConverter.init(&ii1);
    try ii1c.conv_fn(ii1c.ptr, "-60");
    try expect(ii1.? == -60);
    try expectError(error.ParseError, ii1c.conv_fn(ii1c.ptr, "7000000"));

    var str0: []const u8 = "";
    var str0c = FlagConverter.init(&str0);
    try str0c.conv_fn(str0c.ptr, "pass");
    try expectEqualStrings("pass", str0);

    var str1: ?[]const u8 = null;
    var str1c = FlagConverter.init(&str1);
    try str1c.conv_fn(str1c.ptr, "pass");
    try expectEqualStrings("pass", str1.?);

    var en0: enum { Auto, Off, On } = .Auto;
    var en0c = FlagConverter.init(&en0);
    try expectEqualStrings("(Auto|Off|On)", en0c.tag.?);
    try en0c.conv_fn(en0c.ptr, "Off");
    try expect(en0 == .Off);

    var en1: ?enum { Red, Green, Blue } = null;
    var en1c = FlagConverter.init(&en1);
    try expectEqualStrings("(Red|Green|Blue)", en1c.tag.?);
    try en1c.conv_fn(en1c.ptr, "blue");
    try expect(en1.? == .Blue);
}
