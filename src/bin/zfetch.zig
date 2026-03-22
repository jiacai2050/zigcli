//! zfetch — system information fetcher in Zig.
//! Inspired by https://github.com/fastfetch-cli/fastfetch

const std = @import("std");
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const term = zigcli.term;
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

const Format = enum { text, json };

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try structargs.parse(allocator, struct {
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
    const is_tty = term.isTty(stdout);
    var output_buf: [8192]u8 = undefined;
    var writer = stdout.writer(&output_buf);

    try printInfo(
        arena_alloc,
        &writer.interface,
        opt.options.all,
        opt.options.format == .json,
        is_tty,
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
    const hostname = try platform.getHostname(allocator);
    const kernel = try platform.getKernel(allocator);

    const username = std.posix.getenv("USER") orelse
        std.posix.getenv("USERNAME") orelse "unknown";

    const shell_path = std.posix.getenv("SHELL") orelse "unknown";
    const last_slash = mem.lastIndexOfScalar(u8, shell_path, '/');
    const shell = if (last_slash) |idx|
        shell_path[idx + 1 ..]
    else
        shell_path;

    const bytes_per_page = std.heap.pageSize();

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

/// ASCII art logos for each supported OS.
/// Color markers: $1..$6 switch ANSI color mid-line.
const logo_lines: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{
        "                     ..'       ",
        "                 ,xNMM.        ",
        "               .OMMMMo         ",
        "               lMM\"            ",
        "     .;loddo:.  .olloddol;.    ",
        "   cKMMMMMMMMMMNWMMMMMMMMMM0:  ",
        " $2.KMMMMMMMMMMMMMMMMMMMMMMMWd.  ",
        " XMMMMMMMMMMMMMMMMMMMMMMMX.    ",
        "$3;MMMMMMMMMMMMMMMMMMMMMMMM:    ",
        ":MMMMMMMMMMMMMMMMMMMMMMMM:     ",
        "$4.MMMMMMMMMMMMMMMMMMMMMMMMX.   ",
        " kMMMMMMMMMMMMMMMMMMMMMMMMWd.  ",
        " $5'XMMMMMMMMMMMMMMMMMMMMMMMMMMk ",
        "  'XMMMMMMMMMMMMMMMMMMMMMMMMK. ",
        "    $6kMMMMMMMMMMMMMMMMMMMMMMd   ",
        "     ;KMMMMMMMWXXWMMMMMMMk.    ",
        "       \"cooc*\"    \"*coo'\"      ",
    },
    .linux => &.{
        "         $1_nnnn_        ",
        "        $1dGGGGMMb       ",
        "       $1@p~$2qp~~qM$1b      ",
        "       $1M|$2@||@) $1M|      ",
        "       $1@,----.JM|      ",
        "      $3JS^\\__/  qKL     ",
        "     $3dZP        qKRb   ",
        "    $3dZP          qKKb  ",
        "   $3fZP            SMMb ",
        "   $3HZM            MMMM ",
        "   $3FqM            MMMM ",
        " $3__| \".        |\\dS\"qML",
        " $3|    `.       | `' \\Zq",
        "$3_)      \\.___.,|     .' ",
        "$3\\____   )MMMMMP|   .'   ",
        "     $3`-'       `--'     ",
    },
    .freebsd => &.{
        " $2```                        $1`  ",
        "  $2` `.....---...$1....--.```   -/ ",
        "  $2+o   .--`         $1/y:`      +.",
        "   $2yo`:.            $1:o      `+- ",
        "    $2y/               $1-/`   -o/  ",
        "   $2.-                  $1::/sy+:. ",
        "   $2/                     $1`--  / ",
        "  $2`:                          $1:` ",
        "  $2`:                          $1:` ",
        "   $2/                          $1/  ",
        "   $2.-                        $1-.  ",
        "    $2--                      $1-.   ",
        "     $2`:`                  $1`:`    ",
        "       $2.--             $1`--.     ",
        "          $2.---.....----.        ",
    },
    else => &.{},
};

/// ANSI color codes for logo color markers ($1..$6).
const logo_colors: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{
        "\x1b[32m", // $1 green
        "\x1b[33m", // $2 yellow
        "\x1b[31m", // $3 red
        "\x1b[35m", // $4 magenta
        "\x1b[34m", // $5 blue
        "\x1b[36m", // $6 cyan
    },
    .linux => &.{
        "\x1b[37m", // $1 white
        "\x1b[33m", // $2 yellow
        "\x1b[30m", // $3 black
    },
    .freebsd => &.{
        "\x1b[31m", // $1 red
        "\x1b[91m", // $2 bright red
    },
    else => &.{},
};

fn isLogoColorMarker(line: []const u8, index: usize) bool {
    if (line[index] != '$') {
        return false;
    }
    if (index + 1 >= line.len) {
        return false;
    }
    if (line[index + 1] < '1') {
        return false;
    }
    return line[index + 1] <= '9';
}

/// Writes a logo line, expanding $N color markers.
fn writeLogo(
    writer: *std.Io.Writer,
    line: []const u8,
    width: usize,
    color: bool,
) !void {
    var i: usize = 0;
    var vis: usize = 0;
    // Start with first color.
    if (color and logo_colors.len > 0) {
        try writer.writeAll(logo_colors[0]);
    }
    while (i < line.len) {
        if (isLogoColorMarker(line, i)) {
            const idx = line[i + 1] - '1';
            if (color and idx < logo_colors.len) {
                try writer.writeAll(logo_colors[idx]);
            }
            i += 2;
        } else {
            try writer.writeAll(line[i..][0..1]);
            vis += 1;
            i += 1;
        }
    }
    if (color) try writer.writeAll("\x1b[0m");
    // Pad to uniform width.
    for (vis..width) |_| {
        try writer.writeAll(" ");
    }
}

/// Visual width of a logo line (excluding $N markers).
fn logoVisualWidth(line: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (isLogoColorMarker(line, i)) {
            i += 2;
        } else {
            w += 1;
            i += 1;
        }
    }
    return w;
}

/// Prints all system information to the writer.
fn printInfo(
    allocator: mem.Allocator,
    writer: *std.Io.Writer,
    show_all: bool,
    json: bool,
    color: bool,
) !void {
    const info = try collectInfo(allocator, show_all);

    if (json) {
        try writer.print("{f}\n", .{std.json.fmt(info, .{})});
        return;
    }

    // Build info lines.
    var lines_buf: [24][]const u8 = undefined;
    var line_count: usize = 0;

    const header = try fmt.allocPrint(
        allocator,
        "{s}@{s}",
        .{ info.username, info.hostname },
    );
    lines_buf[line_count] = header;
    line_count += 1;

    // Separator matching header length.
    var sep_buf: [128]u8 = undefined;
    var sep_pos: usize = 0;
    for (0..header.len) |_| {
        const s = "─";
        @memcpy(sep_buf[sep_pos..][0..s.len], s);
        sep_pos += s.len;
    }
    lines_buf[line_count] = sep_buf[0..sep_pos];
    line_count += 1;

    const fields = [_]struct { []const u8, []const u8 }{
        .{ "OS", try fmt.allocPrint(allocator, "{s} {s}", .{ info.os, info.arch }) },
        .{ "Host", info.host },
        .{ "Kernel", info.kernel },
        .{ "Uptime", info.uptime },
        .{ "Shell", info.shell },
        .{ "Terminal", info.terminal },
        .{ "Resolution", info.resolution },
        .{ "Theme", info.theme },
        .{ "CPU", info.cpu },
        .{ "Memory", info.memory },
        .{ "Disk", info.disk },
        .{ "Battery", info.battery },
        .{ "Page", info.page },
        .{ "Local IP", info.local_ip },
    };
    for (fields) |f| {
        lines_buf[line_count] = try fmt.allocPrint(
            allocator,
            "{s:<13}{s}",
            .{ f[0], f[1] },
        );
        line_count += 1;
    }
    if (info.packages) |packages| {
        lines_buf[line_count] = try fmt.allocPrint(
            allocator,
            "{s:<13}{s}",
            .{ "Packages", packages },
        );
        line_count += 1;
    }

    // Empty line before color palette.
    lines_buf[line_count] = "";
    line_count += 1;

    // Print logo and info side by side.
    var logo_width: usize = 0;
    for (logo_lines) |line| {
        const w = logoVisualWidth(line);
        if (w > logo_width) logo_width = w;
    }
    logo_width += 2; // Gap between logo and info.
    const total = @max(logo_lines.len + 2, line_count);
    for (0..total) |i| {
        // Logo column.
        if (i < logo_lines.len) {
            try writeLogo(writer, logo_lines[i], logo_width, color);
        } else {
            for (0..logo_width) |_| {
                try writer.writeAll(" ");
            }
        }

        // Info column.
        if (i < line_count) {
            try writer.print("{s}", .{lines_buf[i]});
        }
        try writer.writeAll("\n");
    }

    // Color palette (only in TTY mode).
    if (color) {
        inline for ([_][8][]const u8{
            .{ "40", "41", "42", "43", "44", "45", "46", "47" },
            .{ "100", "101", "102", "103", "104", "105", "106", "107" },
        }) |row| {
            for (0..logo_width) |_| {
                try writer.writeAll(" ");
            }
            inline for (row) |bg| {
                try writer.writeAll(
                    "\x1b[" ++ bg ++ "m   \x1b[0m",
                );
            }
            try writer.writeAll("\n");
        }
    }
}

// Re-export tests from common.
test {
    _ = common;
}
