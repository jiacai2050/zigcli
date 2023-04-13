const std = @import("std");
const Build = std.Build;
const FileSource = Build.FileSource;

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const simargs_dep = b.dependency("simargs", .{});

    var all_tests = std.ArrayList(*Build.Step).init(b.allocator);
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
        const exe = prog.@"0";
        const name = prog.@"1";
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run-" ++ name, "Run " ++ name);
        run_step.dependOn(&run_cmd.step);

        all_tests.append(buildTestStep(b, name, target)) catch @panic("OOM");
    }

    const test_all_step = b.step("test", "Run all tests");
    for (all_tests.items) |step| {
        test_all_step.dependOn(step);
    }
}

fn buildTestStep(b: *std.Build, comptime name: []const u8, target: std.zig.CrossTarget) *Build.Step {
    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/" ++ name ++ ".zig" },
        .target = target,
    });
    const test_step = b.step("test-" ++ name, "Run " ++ name ++ " tests");
    // https://github.com/ziglang/zig/issues/15009#issuecomment-1475350701
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    return test_step;
}

fn buildTree(b: *std.Build, optimize: std.builtin.Mode, target: std.zig.CrossTarget, simargs_dep: *std.build.Dependency) *Build.CompileStep {
    const exe = b.addExecutable(.{
        .name = "tree",
        .root_source_file = FileSource.relative("src/tree.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("simargs", simargs_dep.module("simargs"));

    return exe;
}

fn buildLoc(b: *std.Build, optimize: std.builtin.Mode, target: std.zig.CrossTarget, simargs_dep: *std.build.Dependency) *Build.CompileStep {
    const exe = b.addExecutable(.{
        .name = "loc",
        .root_source_file = FileSource.relative("src/loc.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("simargs", simargs_dep.module("simargs"));
    const table_dep = b.dependency("table-helper", .{});
    exe.addModule("table-helper", table_dep.module("table-helper"));

    return exe;
}

fn buildYes(b: *std.build.Builder, optimize: std.builtin.Mode, target: std.zig.CrossTarget) *std.build.CompileStep {
    const exe = b.addExecutable(.{
        .name = "yes",
        .root_source_file = FileSource.relative("src/yes.zig"),
        .target = target,
        .optimize = optimize,
    });

    return exe;
}
