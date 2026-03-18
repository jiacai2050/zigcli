//! zfetch — system information fetcher in Zig.
//! Inspired by https://github.com/fastfetch-cli/fastfetch

const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const builtin = @import("builtin");
const mem = std.mem;
const fmt = std.fmt;

const common = @import("zfetch/common.zig");
const platform = switch (builtin.os.tag) {
    .linux => @import("zfetch/linux.zig"),
    .macos => @import("zfetch/macos.zig"),
    .freebsd => @import("zfetch/freebsd.zig"),
    else => @compileError("Unsupported OS"),
};

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Format = enum { text, json };

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try simargs.parse(allocator, struct {
        help: bool = false,
        version: bool = false,
        all: bool = false,
        format: Format = .text,

        pub const __shorts__ = .{
            .help = .h,
            .version = .v,
            .all = .a,
            .format = .f,
        };

        pub const __messages__ = .{
            .help = "Print help information.",
            .version = "Print version.",
            .all = "Show all info including packages.",
            .format = "Output format.",
        };
    }, .{
        .version_string = util.get_build_info(),
    });
    defer opt.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const stdout = std.fs.File.stdout();
    var output_buf: [8192]u8 = undefined;
    var writer = stdout.writer(&output_buf);

    try printInfo(
        arena_alloc,
        &writer.interface,
        opt.options.all,
        opt.options.format == .json,
    );
    try writer.interface.flush();
}

const SysInfo = struct {
    username: []const u8,
    hostname: []const u8,
    os: []const u8,
    arch: []const u8,
    host: []const u8,
    kernel: []const u8,
    uptime: []const u8,
    shell: []const u8,
    terminal: []const u8,
    resolution: []const u8,
    theme: []const u8,
    cpu: []const u8,
    memory: []const u8,
    disk: []const u8,
    battery: []const u8,
    page: []const u8,
    local_ip: []const u8,
    packages: ?[]const u8 = null,
};

/// Collects all system information via platform-specific backends.
fn collectInfo(
    allocator: mem.Allocator,
    show_all: bool,
) !SysInfo {
    const uname_info = std.posix.uname();
    const hostname = try allocator.dupe(
        u8,
        mem.sliceTo(&uname_info.nodename, 0),
    );
    const kernel = try allocator.dupe(
        u8,
        mem.sliceTo(&uname_info.release, 0),
    );

    const username = std.posix.getenv("USER") orelse
        std.posix.getenv("USERNAME") orelse "unknown";

    const shell_path = std.posix.getenv("SHELL") orelse "unknown";
    const last_slash = mem.lastIndexOfScalar(u8, shell_path, '/');
    const shell = if (last_slash) |idx|
        shell_path[idx + 1 ..]
    else
        shell_path;

    const bytes_per_page = platform.fetchPageSize();

    return .{
        .username = username,
        .hostname = hostname,
        .os = try platform.getOs(allocator),
        .arch = @tagName(builtin.cpu.arch),
        .host = try platform.getHost(allocator),
        .kernel = kernel,
        .uptime = try platform.getUptime(allocator),
        .shell = if (show_all)
            try common.getShellVersion(allocator, shell)
        else
            shell,
        .terminal = common.getTerminal(),
        .resolution = try platform.getResolution(allocator),
        .theme = platform.getTheme(),
        .cpu = try platform.getCpu(allocator),
        .memory = try platform.getMemory(allocator, bytes_per_page),
        .disk = try common.getDiskMounts(allocator, platform.getDiskMounts()),
        .battery = try platform.getBattery(allocator),
        .page = try fmt.allocPrint(
            allocator,
            "{d} KiB",
            .{bytes_per_page / 1024},
        ),
        .local_ip = try common.getLocalIp(allocator),
        .packages = if (show_all)
            try platform.getPackages(allocator)
        else
            null,
    };
}

/// Prints all system information to the writer.
fn printInfo(
    allocator: mem.Allocator,
    writer: *std.Io.Writer,
    show_all: bool,
    json: bool,
) !void {
    const info = try collectInfo(allocator, show_all);

    if (json) {
        const formatted = try fmt.allocPrint(
            allocator,
            "{f}",
            .{std.json.fmt(info, .{})},
        );
        try writer.writeAll(formatted);
        try writer.writeAll("\n");
        return;
    }

    // Print "username@hostname" header.
    try writer.print("{s}@{s}\n", .{
        info.username, info.hostname,
    });

    const header_len = info.username.len + 1 + info.hostname.len;
    var i: usize = 0;
    while (i < header_len) : (i += 1) {
        try writer.writeAll("─");
    }
    try writer.writeAll("\n");

    try writer.print("OS:          {s} {s}\n", .{ info.os, info.arch });
    try writer.print("Host:        {s}\n", .{info.host});
    try writer.print("Kernel:      {s}\n", .{info.kernel});
    try writer.print("Uptime:      {s}\n", .{info.uptime});
    try writer.print("Shell:       {s}\n", .{info.shell});
    try writer.print("Terminal:    {s}\n", .{info.terminal});
    try writer.print("Resolution:  {s}\n", .{info.resolution});
    try writer.print("Theme:       {s}\n", .{info.theme});
    try writer.print("CPU:         {s}\n", .{info.cpu});
    try writer.print("Memory:      {s}\n", .{info.memory});
    try writer.print("Disk:        {s}\n", .{info.disk});
    try writer.print("Battery:     {s}\n", .{info.battery});
    try writer.print("Page:        {s}\n", .{info.page});
    try writer.print("Local IP:    {s}\n", .{info.local_ip});

    if (info.packages) |packages| {
        try writer.print("Packages:    {s}\n", .{packages});
    }

    // Color palette.
    try writer.writeAll("\n");
    inline for ([_][8][]const u8{
        .{ "40", "41", "42", "43", "44", "45", "46", "47" },
        .{ "100", "101", "102", "103", "104", "105", "106", "107" },
    }) |row| {
        inline for (row) |bg| {
            try writer.writeAll("\x1b[" ++ bg ++ "m   \x1b[0m");
        }
        try writer.writeAll("\n");
    }
}

// Re-export tests from common.
test {
    _ = common;
}
