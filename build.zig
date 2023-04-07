const std = @import("std");
const Build = std.Build;
const FileSource = Build.FileSource;

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const simargs_dep = b.dependency("simargs", .{});

    inline for (.{
        .{
            buildTree(b, optimize, target, simargs_dep),
            "tree",
        },
        .{
            buildLoc(b, optimize, target, simargs_dep),
            "loc",
        },
        .{
            buildYes(b, optimize, target),
            "yes",
        },
    }) |prog| {
        buildRunTestStep(b, prog.@"0", prog.@"1");
    }
}

fn buildRunTestStep(b: *std.build.Builder, exe: *std.build.CompileStep, comptime name: []const u8) void {
    const run_cmd = exe.run();
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run-" ++ name, "Run " ++ name);
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/" ++ name ++ ".zig" },
    });
    const test_step = b.step("test-" ++ name, "Run " ++ name ++ " tests");
    // https://github.com/ziglang/zig/issues/15009#issuecomment-1475350701
    test_step.dependOn(&exe_tests.run().step);
}

fn buildTree(b: *std.build.Builder, optimize: std.builtin.Mode, target: std.zig.CrossTarget, simargs_dep: *std.build.Dependency) *std.build.CompileStep {
    const exe = b.addExecutable(.{
        .name = "tree",
        .root_source_file = FileSource.relative("src/tree.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("simargs", simargs_dep.module("simargs"));
    exe.install();

    return exe;
}

fn buildLoc(b: *std.build.Builder, optimize: std.builtin.Mode, target: std.zig.CrossTarget, simargs_dep: *std.build.Dependency) *std.build.CompileStep {
    const exe = b.addExecutable(.{
        .name = "loc",
        .root_source_file = FileSource.relative("src/loc.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("simargs", simargs_dep.module("simargs"));
    const table_dep = b.dependency("table-helper", .{});
    exe.addModule("table-helper", table_dep.module("table-helper"));
    exe.install();

    return exe;
}

fn buildYes(b: *std.build.Builder, optimize: std.builtin.Mode, target: std.zig.CrossTarget) *std.build.CompileStep {
    const exe = b.addExecutable(.{
        .name = "yes",
        .root_source_file = FileSource.relative("src/yes.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.install();

    return exe;
}
