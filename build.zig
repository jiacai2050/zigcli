const std = @import("std");
const Build = std.Build;

const macos_private_framework = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks/";

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    var all_tests = std.ArrayList(*Build.Step).init(b.allocator);

    try addModules(b, target, optimize, &all_tests);
    try buildBinaries(b, optimize, target, &all_tests);
    try buildExamples(b, optimize, target, &all_tests);

    const test_all_step = b.step("test", "Run all tests");
    for (all_tests.items) |step| {
        test_all_step.dependOn(step);
    }
}

const Source = union(enum) {
    bin: []const u8,
    mod: []const u8,
    ex: []const u8,

    const Self = @This();

    fn name(self: Self) []const u8 {
        return switch (self) {
            .bin, .mod, .ex => |v| v,
        };
    }

    fn path(self: Self) []const u8 {
        return switch (self) {
            .bin => |_| "src/bin",
            .mod => |_| "src/mod",
            .ex => |_| "examples",
        };
    }

    fn need_test(self: Self) bool {
        return switch (self) {
            .bin, .mod => true,
            .ex => false,
        };
    }
};

fn addModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    all_tests: *std.ArrayList(*Build.Step),
) !void {
    inline for (.{ "pretty-table", "simargs" }) |name| {
        _ = b.addModule(name, .{
            .root_source_file = b.path("src/mod/" ++ name ++ ".zig"),
        });

        try all_tests.append(buildTestStep(b, .{ .mod = name }, target));
    }

    const opt = b.addOptions();
    opt.addOption(
        []const u8,
        "build_date",
        b.option([]const u8, "build_date", "Build date") orelse
            b.fmt("{d}", .{std.time.milliTimestamp()}),
    );

    opt.addOption(
        []const u8,
        "version",
        b.option([]const u8, "version", "Version to release") orelse
            "Unknown",
    );
    opt.addOption(
        []const u8,
        "git_commit",
        b.option([]const u8, "git_commit", "Git commit") orelse
            "Unknown",
    );
    opt.addOption([]const u8, "build_mode", switch (optimize) {
        .Debug => "Dev",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
        .ReleaseSafe => "ReleaseSafe",
    });
    try b.modules.put("build_info", opt.createModule());
}

fn buildExamples(
    b: *std.Build,
    optimize: std.builtin.Mode,
    target: std.Build.ResolvedTarget,
    all_tests: *std.ArrayList(*Build.Step),
) !void {
    inline for (.{
        "simargs-demo",
        "pretty-table-demo",
    }) |name| {
        try buildBinary(b, .{ .ex = name }, optimize, target, all_tests);
    }
}

fn buildBinaries(
    b: *std.Build,
    optimize: std.builtin.Mode,
    target: std.Build.ResolvedTarget,
    all_tests: *std.ArrayList(*Build.Step),
) !void {
    inline for (.{
        "zigfetch",
        "tree",
        "loc",
        "pidof",
        "yes",
        "night-shift",
        "dark-mode",
        "repeat",
        "tcp-proxy",
        "timeout",
    }) |name| {
        try buildBinary(
            b,
            .{ .bin = name },
            optimize,
            target,
            all_tests,
        );
    }

    // TODO: move util out of `bin`
    try all_tests.append(buildTestStep(b, .{ .bin = "util" }, target));
}

fn buildBinary(
    b: *std.Build,
    comptime source: Source,
    optimize: std.builtin.Mode,
    target: std.Build.ResolvedTarget,
    all_tests: *std.ArrayList(*Build.Step),
) !void {
    if (makeCompileStep(
        b,
        source,
        optimize,
        target,
    )) |exe| {
        var deps = b.modules.iterator();
        while (deps.next()) |dep| {
            exe.root_module.addImport(dep.key_ptr.*, dep.value_ptr.*);
        }

        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const prog_name = comptime source.name();
        b.step("run-" ++ prog_name, "Run " ++ prog_name)
            .dependOn(&run_cmd.step);

        if (source.need_test()) {
            try all_tests.append(buildTestStep(b, source, target));
        }
    }
}

fn buildTestStep(
    b: *std.Build,
    comptime source: Source,
    target: std.Build.ResolvedTarget,
) *Build.Step {
    const name = comptime source.name();
    const path = comptime source.path();
    const exe_tests = b.addTest(.{
        .root_source_file = b.path(path ++ "/" ++ name ++ ".zig"),
        .target = target,
    });
    const test_step = b.step("test-" ++ name, "Run " ++ name ++ " tests");
    // https://github.com/ziglang/zig/issues/15009#issuecomment-1475350701
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    return test_step;
}

fn makeCompileStep(
    b: *std.Build,
    comptime source: Source,
    optimize: std.builtin.Mode,
    target: std.Build.ResolvedTarget,
) ?*Build.Step.Compile {
    const name = comptime source.name();
    const path = comptime source.path();
    // We can't use `target.result.isDarwin()` alone here,
    // Since when cross compile to darwin on linux, there is no framework in the host!
    const is_darwin = @import("builtin").os.tag == .macos and target.result.os.tag == .macos;
    const is_win = target.result.os.tag == .windows;
    if (!is_darwin) {
        if (std.mem.eql(u8, name, "night-shift") or std.mem.eql(u8, name, "dark-mode")) {
            return null;
        }
    }
    const exe = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(path ++ "/" ++ name ++ ".zig"),
        .target = target,
        .optimize = optimize,
    });

    if (std.mem.eql(u8, name, "night-shift")) {
        exe.linkSystemLibrary("objc");
        exe.addFrameworkPath(.{ .cwd_relative = macos_private_framework });
        exe.linkFramework("CoreBrightness");
    } else if (std.mem.eql(u8, name, "dark-mode")) {
        exe.addFrameworkPath(.{ .cwd_relative = macos_private_framework });
        exe.linkFramework("SkyLight");
    } else if (std.mem.eql(u8, name, "tcp-proxy")) {
        exe.linkLibC();
    } else if (std.mem.eql(u8, name, "timeout")) {
        if (is_win) { // error: TODO windows Sigaction definition
            return null;
        }
        exe.linkLibC();
    } else if (std.mem.eql(u8, name, "zigfetch")) {
        const dep_curl = b.dependency("curl", .{
            .link_vendor = true,
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("curl", dep_curl.module("curl"));
        exe.linkLibC();
    } else if (std.mem.eql(u8, name, "pidof")) {
        // only build for macOS
        if (is_darwin) {
            exe.linkLibC();
        } else {
            return null;
        }
    }

    const install_step = b.step("install-" ++ name, "Install " ++ name);
    install_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    return exe;
}
