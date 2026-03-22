const std = @import("std");
const builtin = @import("builtin");
const Build = std.Build;
const Step = Build.Step;
const macos_private_framework_xcode =
    "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/" ++
    "Developer/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks/";
const macos_private_framework_clt =
    "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks/";

pub fn build(b: *Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const test_all_step = b.step("test", "Run all tests");
    try addModules(b, target, optimize, test_all_step);
    try buildBinaries(b, optimize, target, test_all_step);
    try buildExamples(b, optimize, target, test_all_step);
}

const Source = union(enum) {
    binary: []const u8,
    example: []const u8,

    const Self = @This();

    fn name(self: Self) []const u8 {
        return switch (self) {
            .binary, .example => |value| value,
        };
    }

    fn path(self: Self) []const u8 {
        return switch (self) {
            .binary => |_| "src/bin",
            .example => |_| "examples",
        };
    }

    fn needsTest(self: Self) bool {
        return switch (self) {
            .binary => true,
            .example => false,
        };
    }
};

fn addModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    all_tests: *Step,
) !void {
    // 1. Add zigcli module.
    const zigcli = b.addModule("zigcli", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const doc_obj = b.addObject(.{
        .name = "docs",
        .root_module = zigcli,
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = doc_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // 2. Add build_info private module.
    const build_info_options = b.addOptions();
    build_info_options.addOption(
        []const u8,
        "build_date",
        b.option([]const u8, "build_date", "Build date") orelse
            b.fmt("{d}", .{std.time.milliTimestamp()}),
    );

    build_info_options.addOption(
        []const u8,
        "version",
        b.option([]const u8, "version", "Version to release") orelse
            "Unknown",
    );
    build_info_options.addOption(
        []const u8,
        "git_commit",
        b.option([]const u8, "git_commit", "Git commit") orelse
            "Unknown",
    );
    build_info_options.addOption([]const u8, "build_mode", switch (optimize) {
        .Debug => "Dev",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
        .ReleaseSafe => "ReleaseSafe",
    });
    try b.modules.put("build_info", build_info_options.createModule());

    const module_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
        }),
    });
    const test_step = b.step("test-zigcli", "Run zigcli module tests");
    test_step.dependOn(&b.addRunArtifact(module_tests).step);
    all_tests.dependOn(test_step);
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
        try buildBinary(b, .{ .example = name }, optimize, target, all_tests);
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
            .{ .binary = name },
            optimize,
            target,
            all_tests,
        );
    }

    // TODO: Move util out of src/bin because it is a shared helper.
    all_tests.dependOn(buildTestStep(b, .{ .binary = "util" }, target));
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
    )) |compile_step| {
        var module_imports = b.modules.iterator();
        while (module_imports.next()) |module_import| {
            compile_step.root_module.addImport(
                module_import.key_ptr.*,
                module_import.value_ptr.*,
            );
        }

        b.installArtifact(compile_step);
        const run_step = b.addRunArtifact(compile_step);
        if (b.args) |args| {
            run_step.addArgs(args);
        }
        const source_name = comptime source.name();
        b.step("run-" ++ source_name, "Run " ++ source_name)
            .dependOn(&run_step.step);

        if (source.needsTest()) {
            all_tests.dependOn(buildTestStep(b, source, target));
        }
    }
}

fn buildTestStep(
    b: *std.Build,
    comptime source: Source,
    target: std.Build.ResolvedTarget,
) *Step {
    const source_name = comptime source.name();
    const source_path = comptime source.path();
    const test_module = b.modules.get(source_name) orelse b.createModule(.{
        .root_source_file = b.path(source_path ++ "/" ++ source_name ++ ".zig"),
        .target = target,
    });
    const test_compile_step = b.addTest(.{
        .root_module = test_module,
    });
    test_compile_step.root_module.addImport("zigcli", b.modules.get("zigcli").?);
    test_compile_step.root_module.addImport("build_info", b.modules.get("build_info").?);
    const test_step = b.step("test-" ++ source_name, "Run " ++ source_name ++ " tests");
    // Build test artifacts through addRunArtifact because Zig does not expose a direct test step.
    test_step.dependOn(&b.addRunArtifact(test_compile_step).step);
    return test_step;
}

fn makeCompileStep(
    b: *std.Build,
    comptime source: Source,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) ?*Build.Step.Compile {
    const source_name = comptime source.name();
    const source_path = comptime source.path();
    if (!sourceSupported(
        source_name,
        builtin.os.tag,
        target.result.os.tag,
    )) {
        return null;
    }

    const compile_step = b.addExecutable(.{
        .name = source_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source_path ++ "/" ++ source_name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    configureCompileStep(b, compile_step, source_name, optimize, target);

    const install_step = b.step("install-" ++ source_name, "Install " ++ source_name);
    install_step.dependOn(&b.addInstallArtifact(compile_step, .{}).step);
    return compile_step;
}

fn sourceSupported(
    source_name: []const u8,
    host_os: std.Target.Os.Tag,
    target_os: std.Target.Os.Tag,
) bool {
    if (target_os == .freebsd) {
        // FreeBSD currently lacks std.net.if_nametoindex, which blocks these programs.
        if (sourceNameInList(source_name, .{ "zigfetch", "tcp-proxy" })) {
            return false;
        }
    }

    if (std.mem.eql(u8, source_name, "timeout")) {
        // Windows still lacks the required Sigaction definition here.
        if (target_os == .windows) {
            return false;
        }
    }

    if (sourceNameInList(source_name, .{ "pidof", "night-shift", "dark-mode" })) {
        // those programs depend on macOS-only APIs, and don't support cross compile.
        if (host_os != .macos or target_os != .macos) {
            return false;
        }
    }

    if (std.mem.eql(u8, source_name, "zfetch")) {
        if (!zfetchSupported(host_os, target_os)) {
            return false;
        }
    }

    if (std.mem.eql(u8, source_name, "progress")) {
        if (!(target_os == .macos or target_os == .linux)) {
            return false;
        }
    }

    return true;
}

fn configureCompileStep(
    b: *std.Build,
    compile_step: *Build.Step.Compile,
    source_name: []const u8,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
) void {
    if (std.mem.eql(u8, source_name, "night-shift")) {
        compile_step.linkSystemLibrary("objc");
        addMacOSPrivateFrameworkPaths(compile_step);
        compile_step.linkFramework("CoreBrightness");
        return;
    }

    if (std.mem.eql(u8, source_name, "dark-mode")) {
        addMacOSPrivateFrameworkPaths(compile_step);
        compile_step.linkFramework("SkyLight");
        return;
    }

    if (std.mem.eql(u8, source_name, "tcp-proxy")) {
        compile_step.linkLibC();
        return;
    }

    if (std.mem.eql(u8, source_name, "timeout")) {
        compile_step.linkLibC();
        return;
    }

    if (std.mem.eql(u8, source_name, "zigfetch")) {
        const curl_dependency = b.dependency("curl", .{
            .link_vendor = true,
            .target = target,
            .optimize = optimize,
        });
        compile_step.root_module.addImport("curl", curl_dependency.module("curl"));
        compile_step.linkLibC();
        return;
    }

    if (std.mem.eql(u8, source_name, "pidof")) {
        compile_step.linkLibC();
        return;
    }

    if (std.mem.eql(u8, source_name, "zfetch")) {
        switch (target.result.os.tag) {
            .macos => {
                compile_step.linkFramework("CoreGraphics");
                compile_step.linkFramework("Foundation");
                compile_step.linkFramework("IOKit");
            },
            .linux => {
                compile_step.linkLibC();
            },
            else => {},
        }
        return;
    }

    if (std.mem.eql(u8, source_name, "progress")) {
        if (target.result.os.tag == .linux) {
            compile_step.linkLibC();
            return;
        }
    }
}

fn sourceNameInList(
    source_name: []const u8,
    comptime source_names: anytype,
) bool {
    inline for (source_names) |name| {
        if (std.mem.eql(u8, source_name, name)) {
            return true;
        }
    }
    return false;
}

fn zfetchSupported(
    host_os: std.Target.Os.Tag,
    target_os: std.Target.Os.Tag,
) bool {
    // zfetch only supports macOS, Linux, and FreeBSD.
    switch (target_os) {
        .macos, .linux, .freebsd => {},
        else => return false,
    }

    // zfetch uses @cImport with OS-specific headers that must exist on the host.
    if (target_os == .macos) {
        return host_os == .macos;
    } else {
        return true;
    }
}

fn addMacOSPrivateFrameworkPaths(compile_step: *Build.Step.Compile) void {
    compile_step.addFrameworkPath(.{ .cwd_relative = macos_private_framework_xcode });
    compile_step.addFrameworkPath(.{ .cwd_relative = macos_private_framework_clt });
}
