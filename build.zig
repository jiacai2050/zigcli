const std = @import("std");
const Build = std.Build;
const Step = Build.Step;
const macos_private_framework = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks/";
const macos_private_framework2 = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks/";

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const test_all_step = b.step("test", "Run all tests");
    try addModules(b, target, optimize, test_all_step);
    try buildBinaries(b, optimize, target, test_all_step);
    try buildExamples(b, optimize, target, test_all_step);
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
    optimize: std.builtin.OptimizeMode,
    all_tests: *Step,
) !void {
    _ = b.addModule("zigcli", .{
        .root_source_file = b.path("lib.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    all_tests.dependOn(buildRootTestStep(b, target));
    inline for (.{ "pretty-table", "structargs", "gitignore" }) |name| {
        all_tests.dependOn(buildTestStep(b, .{ .mod = name }, target));
    }
}

fn buildExamples(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    all_tests: *Step,
) !void {
    inline for (.{
        "structargs-demo",
        "pretty-table-demo",
    }) |name| {
        try buildBinary(b, .{ .ex = name }, optimize, target, all_tests);
    }
}

fn buildBinaries(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    all_tests: *Step,
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
        "cowsay",
        "pretty-csv",
        "zfetch",
        "progress",
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
    all_tests.dependOn(buildTestStep(b, .{ .bin = "util" }, target));
}

fn buildBinary(
    b: *std.Build,
    comptime source: Source,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    all_tests: *Step,
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
            all_tests.dependOn(buildTestStep(b, source, target));
        }
    }
}

fn buildTestStep(
    b: *std.Build,
    comptime source: Source,
    target: std.Build.ResolvedTarget,
) *Step {
    const name = comptime source.name();
    const path = comptime source.path();
    const module = b.modules.get(name) orelse b.createModule(.{
        .root_source_file = b.path(path ++ "/" ++ name ++ ".zig"),
        .target = target,
    });
    const exe_tests = b.addTest(.{
        .root_module = module,
    });
    exe_tests.root_module.addImport("zigcli", b.modules.get("zigcli").?);
    exe_tests.root_module.addImport("build_info", b.modules.get("build_info").?);
    const test_step = b.step("test-" ++ name, "Run " ++ name ++ " tests");
    // https://github.com/ziglang/zig/issues/15009#issuecomment-1475350701
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    return test_step;
}

fn buildRootTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) *Step {
    const exe_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("lib.zig"),
            .target = target,
        }),
    });
    const test_step = b.step("test-zigcli", "Run zigcli module tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    return test_step;
}

fn makeCompileStep(
    b: *std.Build,
    comptime source: Source,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) ?*Build.Step.Compile {
    const name = comptime source.name();
    const path = comptime source.path();
    // We can't use `target.result.isDarwin()` alone here,
    // Since when cross compile to darwin on linux, there is no framework in the host!
    const is_darwin = @import("builtin").os.tag == .macos and target.result.os.tag == .macos;
    const is_win = target.result.os.tag == .windows;
    if (!is_darwin) {
        inline for (.{ "night-shift", "dark-mode" }) |blacklist| {
            if (std.mem.eql(u8, name, blacklist)) {
                return null;
            }
        }
    }
    if (target.result.os.tag == .freebsd) {
        // Blocked by
        // @compileError("std.net.if_nametoindex unimplemented for this OS");
        inline for (.{ "zigfetch", "tcp-proxy" }) |blacklist| {
            if (std.mem.eql(u8, name, blacklist)) {
                return null;
            }
        }
    }
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path ++ "/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (std.mem.eql(u8, name, "night-shift")) {
        exe.linkSystemLibrary("objc");
        exe.addFrameworkPath(.{ .cwd_relative = macos_private_framework });
        exe.addFrameworkPath(.{ .cwd_relative = macos_private_framework2 });
        exe.linkFramework("CoreBrightness");
    } else if (std.mem.eql(u8, name, "dark-mode")) {
        exe.addFrameworkPath(.{ .cwd_relative = macos_private_framework });
        exe.addFrameworkPath(.{ .cwd_relative = macos_private_framework2 });
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
    } else if (std.mem.eql(u8, name, "zfetch")) {
        const target_os = target.result.os.tag;
        // Only supports macOS, Linux, and FreeBSD.
        switch (target_os) {
            .macos, .linux, .freebsd => {},
            else => return null,
        }
        // zfetch uses @cImport with OS-specific headers that must exist on the host.
        if (@import("builtin").os.tag != target_os and target_os == .macos) {
            return null;
        }
        exe.linkLibC();
        if (is_darwin) {
            exe.linkFramework("CoreGraphics");
            exe.linkFramework("Foundation");
            exe.linkFramework("IOKit");
        }
    } else if (std.mem.eql(u8, name, "progress")) {
        // Linux uses the /proc filesystem; macOS uses libproc.
        if (target.result.os.tag == .linux) {
            // No special libraries needed for /proc access on Linux.
        } else if (is_darwin) {
            exe.linkLibC();
        } else {
            return null;
        }
    }

    const install_step = b.step("install-" ++ name, "Install " ++ name);
    install_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    return exe;
}
