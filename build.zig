const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;

pub fn build(b: *Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const simargs_dep = b.dependency("simargs", .{});

    const opt = b.addOptions();
    opt.addOption(
        []const u8,
        "build_date",
        b.option([]const u8, "build_date", "Build date") orelse
            b.fmt("{d}", .{std.time.milliTimestamp()}),
    );
    opt.addOption(
        []const u8,
        "git_commit",
        b.option([]const u8, "git_commit", "Git commit") orelse
            "Unknown",
    );
    b.modules.put("build_info", opt.createModule()) catch @panic("OOM");
    b.modules.put("simargs", simargs_dep.module("simargs")) catch @panic("OOM");
    _ = b.addModule("pretty-table", .{
        .source_file = .{ .path = "src/mod/pretty_table.zig" },
    });
    const is_ci = b.option(bool, "is_ci", "Build in CI") orelse false;

    try buildBinariesAndModules(b, optimize, target, is_ci);
}

const Source = union(enum) {
    bin: []const u8,
    mod: []const u8,

    const Self = @This();
    fn name(self: Self) []const u8 {
        return switch (self) {
            .bin => |v| v,
            .mod => |v| v,
        };
    }
};

fn buildBinariesAndModules(
    b: *std.Build,
    optimize: std.builtin.Mode,
    target: std.zig.CrossTarget,
    is_ci: bool,
) !void {
    var all_tests = std.ArrayList(*Build.Step).init(b.allocator);
    inline for (.{
        "tree",
        "loc",
        "pidof",
        "yes",
        "night-shift",
        "repeat",
    }) |name| {
        try buildBinaries(.{ .bin = name }, b, optimize, target, is_ci, &all_tests);
    }

    const test_all_step = b.step("test", "Run all tests");
    test_all_step.dependOn(buildTestStep(b, "util", target));
    for (all_tests.items) |step| {
        test_all_step.dependOn(step);
    }
}

fn buildBinaries(
    comptime source: Source,
    b: *std.Build,
    optimize: std.builtin.Mode,
    target: std.zig.CrossTarget,
    is_ci: bool,
    all_tests: *std.ArrayList(*Build.Step),
) !void {
    const prog_name = comptime source.name();
    if (makeCompileStep(b, prog_name, optimize, target, is_ci)) |exe| {
        var deps = b.modules.iterator();
        while (deps.next()) |dep| {
            exe.addModule(dep.key_ptr.*, dep.value_ptr.*);
        }

        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        b.step("run-" ++ prog_name, "Run " ++ prog_name)
            .dependOn(&run_cmd.step);

        all_tests.append(buildTestStep(b, prog_name, target)) catch @panic("OOM");
    }
}

fn buildTestStep(b: *std.Build, comptime name: []const u8, target: std.zig.CrossTarget) *Build.Step {
    const exe_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/bin/" ++ name ++ ".zig" },
        .target = target,
    });
    const test_step = b.step("test-" ++ name, "Run " ++ name ++ " tests");
    // https://github.com/ziglang/zig/issues/15009#issuecomment-1475350701
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    return test_step;
}

fn makeCompileStep(
    b: *std.Build,
    comptime name: []const u8,
    optimize: std.builtin.Mode,
    target: std.zig.CrossTarget,
    is_ci: bool,
) ?*Build.CompileStep {
    if (std.mem.eql(u8, name, "night-shift") or std.mem.eql(u8, name, "pidof")) {
        if (target.getOsTag() != .macos) {
            return null;
        }
    }

    if (is_ci and std.mem.eql(u8, name, "night-shift")) {
        // zig build -Dtarget=aarch64-macos  will throw error
        // error: warning(link): library not found for '-lobjc'
        // warning(link): Library search paths:
        // warning(link): framework not found for '-framework CoreBrightness'
        // warning(link): Framework search paths:
        // warning(link):   /System/Library/PrivateFrameworks
        // so disable this in CI environment.
        return null;
    }

    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = LazyPath.relative("src/bin/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
    });

    if (std.mem.eql(u8, name, "night-shift")) {
        exe.linkSystemLibrary("objc");
        exe.addFrameworkPath(.{ .path = "/System/Library/PrivateFrameworks" });
        exe.linkFramework("CoreBrightness");
    }
    return exe;
}
