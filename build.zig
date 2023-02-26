const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe = b.addExecutable(.{
        .name = "loc",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const dep_simargs = b.dependency("simargs", .{
        .target = target,
        .optimize = optimize,
    });
    const dep_table = b.dependency("table_helper", .{
        .target = target,
        .optimize = optimize,
    });

    exe.addModule("table-helper", dep_table.module("table-helper"));
    exe.addModule("simargs", dep_simargs.module("simargs"));
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = .{ .path = "src/main.zig" },
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
