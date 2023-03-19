const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const simargs = b.dependency("simargs", .{
        .target = target,
        .optimize = optimize,
    });

    inline for (.{
        .{
            buildTree(b, optimize, target, simargs),
            "tree",
            "src/tree.zig",
        },
        .{
            buildLoc(b, optimize, target, simargs),
            "loc",
            "src/loc.zig",
        },
    }) |prog| {
        buildRunTestStep(b, prog.@"0", prog.@"1", prog.@"2");
    }
}

fn buildRunTestStep(b: *std.build.Builder, exe: *std.build.CompileStep, comptime name: []const u8, root_file: []const u8) void {
    const run_cmd = exe.run();
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run-" ++ name, "Run " ++ name);
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = root_file },
    });
    const test_step = b.step("test-" ++ name, "Run " ++ name ++ " tests");
    test_step.dependOn(&exe_tests.step);
}

fn buildTree(b: *std.build.Builder, optimize: std.builtin.Mode, target: std.zig.CrossTarget, simargs: *std.build.Dependency) *std.build.CompileStep {
    const exe = b.addExecutable(.{
        .name = "tree",
        .root_source_file = .{ .path = "src/tree.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("simargs", simargs.module("simargs"));
    exe.install();

    return exe;
}

fn buildLoc(b: *std.build.Builder, optimize: std.builtin.Mode, target: std.zig.CrossTarget, simargs: *std.build.Dependency) *std.build.CompileStep {
    const exe = b.addExecutable(.{
        .name = "loc",
        .root_source_file = .{ .path = "src/loc.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("simargs", simargs.module("simargs"));
    const dep_table = b.dependency("table-helper", .{
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("table-helper", dep_table.module("table-helper"));
    exe.install();

    return exe;
}
