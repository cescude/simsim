const std = @import("std");

fn configCSources(step: *std.build.LibExeObjStep) void {
    step.addIncludePath("extern/mongoose");
    step.addCSourceFile("extern/mongoose/mongoose.c", &[_][]const u8{});

    step.addIncludePath("extern/lua-5.4.4/src");
    step.addCSourceFile("extern/lua-5.4.4/src/lapi.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lauxlib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lbaselib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lcode.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lcorolib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lctype.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/ldblib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/ldebug.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/ldo.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/ldump.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lfunc.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lgc.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/linit.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/liolib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/llex.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lmathlib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lmem.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/loadlib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lobject.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lopcodes.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/loslib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lparser.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lstate.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lstring.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lstrlib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/ltable.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/ltablib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/ltm.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lundump.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lutf8lib.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lvm.c", &[_][]const u8{});
    step.addCSourceFile("extern/lua-5.4.4/src/lzio.c", &[_][]const u8{});

    step.linkLibC();
}

const zopts = std.build.Pkg{
    .name = "zopts",
    .source = .{ .path = "extern/zopts/src/zopts.zig" },
    .dependencies = &[_]std.build.Pkg{},
};

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("simsim", "src/main.zig");
    configCSources(exe);
    exe.addPackage(zopts);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    configCSources(exe_tests);
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
