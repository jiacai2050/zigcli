//! Fastfetch in Zig — system information fetcher
//! Inspired by https://github.com/fastfetch-cli/fastfetch

const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const builtin = @import("builtin");
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const native_os = builtin.os.tag;

// Import macOS-specific sysctl headers only when targeting macOS.
// On all other platforms, c is an empty struct so macOS-only code paths never reference it.
const c = if (native_os == .macos) @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("sys/time.h");
}) else struct {};

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try simargs.parse(allocator, struct {
        help: bool = false,
        version: bool = false,

        pub const __shorts__ = .{
            .help = .h,
            .version = .v,
        };

        pub const __messages__ = .{
            .help = "Print help information.",
            .version = "Print version.",
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

    try printInfo(arena_alloc, &writer.interface);
    try writer.interface.flush();
}

/// Formats a raw uptime in seconds as a human-readable string, e.g. "2 hours, 30 mins".
pub fn formatUptime(allocator: mem.Allocator, uptime_seconds: u64) ![]const u8 {
    const seconds_per_minute: u64 = 60;
    const seconds_per_hour: u64 = 60 * seconds_per_minute;
    const seconds_per_day: u64 = 24 * seconds_per_hour;

    const days = uptime_seconds / seconds_per_day;
    const hours = (uptime_seconds % seconds_per_day) / seconds_per_hour;
    const minutes = (uptime_seconds % seconds_per_hour) / seconds_per_minute;
    const secs = uptime_seconds % seconds_per_minute;

    if (days > 0) {
        return fmt.allocPrint(
            allocator,
            "{d} days, {d} hours, {d} mins",
            .{ days, hours, minutes },
        );
    } else if (hours > 0) {
        return fmt.allocPrint(allocator, "{d} hours, {d} mins", .{ hours, minutes });
    } else if (minutes > 0) {
        return fmt.allocPrint(allocator, "{d} mins, {d} secs", .{ minutes, secs });
    } else {
        return fmt.allocPrint(allocator, "{d} secs", .{secs});
    }
}

/// Gets system uptime as a human-readable string.
fn getUptime(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .linux) {
        // /proc/uptime contains "uptime_seconds idle_seconds".
        const file = try fs.openFileAbsolute("/proc/uptime", .{});
        defer file.close();
        var buf: [64]u8 = undefined;
        const byte_count = try file.read(&buf);
        const content = buf[0..byte_count];
        // Parse only the first field (uptime in seconds, possibly fractional).
        const space_pos = mem.indexOfScalar(u8, content, ' ') orelse content.len;
        const dot_pos = mem.indexOfScalar(u8, content[0..space_pos], '.') orelse space_pos;
        const total_seconds = fmt.parseInt(u64, content[0..dot_pos], 10) catch return "Unknown";
        return formatUptime(allocator, total_seconds);
    } else if (comptime native_os == .macos) {
        // kern.boottime is a struct timeval; compute uptime as now - tv_sec.
        var boot_time: c.struct_timeval = undefined;
        var size: usize = @sizeOf(c.struct_timeval);
        if (c.sysctlbyname("kern.boottime", &boot_time, &size, null, 0) != 0) {
            return "Unknown";
        }
        const now: i64 = std.time.timestamp();
        const boot_sec: i64 = @intCast(boot_time.tv_sec);
        if (now < boot_sec) return "Unknown";
        const uptime_seconds: u64 = @intCast(now - boot_sec);
        return formatUptime(allocator, uptime_seconds);
    } else {
        return "Unknown";
    }
}

/// Gets the OS pretty name, e.g. "Ubuntu 22.04.3 LTS" or "macOS 14.1".
fn getOs(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .linux) {
        // Read PRETTY_NAME from /etc/os-release.
        const file = fs.openFileAbsolute("/etc/os-release", .{}) catch {
            return "Linux";
        };
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 4096);
        var iter = mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (!mem.startsWith(u8, line, "PRETTY_NAME=")) continue;
            const raw = line["PRETTY_NAME=".len..];
            // Strip surrounding double-quotes when present.
            if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
                return allocator.dupe(u8, raw[1 .. raw.len - 1]);
            }
            return allocator.dupe(u8, raw);
        }
        return "Linux";
    } else if (comptime native_os == .macos) {
        var version_buf: [64]u8 = undefined;
        var size: usize = version_buf.len;
        if (c.sysctlbyname("kern.osproductversion", &version_buf, &size, null, 0) != 0) {
            return "macOS";
        }
        const version = mem.trimRight(u8, version_buf[0..size], &[_]u8{0});
        return fmt.allocPrint(allocator, "macOS {s}", .{version});
    } else {
        const uname_info = std.posix.uname();
        return allocator.dupe(u8, mem.sliceTo(&uname_info.sysname, 0));
    }
}

/// Gets the CPU model string, e.g. "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz".
fn getCpu(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .linux) {
        // The first "model name" entry in /proc/cpuinfo is the CPU model.
        const file = fs.openFileAbsolute("/proc/cpuinfo", .{}) catch {
            return "Unknown";
        };
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 65536);
        var iter = mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (!mem.startsWith(u8, line, "model name")) continue;
            const colon_pos = mem.indexOfScalar(u8, line, ':') orelse continue;
            const model = mem.trim(u8, line[colon_pos + 1 ..], " \t");
            return allocator.dupe(u8, model);
        }
        return "Unknown";
    } else if (comptime native_os == .macos) {
        var cpu_buf: [256]u8 = undefined;
        var size: usize = cpu_buf.len;
        if (c.sysctlbyname("machdep.cpu.brand_string", &cpu_buf, &size, null, 0) != 0) {
            return "Unknown";
        }
        const brand = mem.trimRight(u8, cpu_buf[0..size], &[_]u8{0});
        return allocator.dupe(u8, brand);
    } else {
        return "Unknown";
    }
}

/// Gets memory usage as "used MiB / total MiB" on Linux, or "total MiB" on macOS.
fn getMemory(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .linux) {
        const file = fs.openFileAbsolute("/proc/meminfo", .{}) catch {
            return "Unknown";
        };
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 4096);
        var mem_total_kb: u64 = 0;
        var mem_available_kb: u64 = 0;
        var iter = mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (mem.startsWith(u8, line, "MemTotal:")) {
                mem_total_kb = parseKbLine(line);
            } else if (mem.startsWith(u8, line, "MemAvailable:")) {
                mem_available_kb = parseKbLine(line);
            }
        }
        if (mem_total_kb == 0) return "Unknown";
        // Saturating subtraction guards against the unlikely case where
        // available memory temporarily exceeds total due to a stale read.
        const used_kb = mem_total_kb -| mem_available_kb;
        return fmt.allocPrint(allocator, "{d} MiB / {d} MiB", .{
            used_kb / 1024,
            mem_total_kb / 1024,
        });
    } else if (comptime native_os == .macos) {
        var mem_bytes: u64 = 0;
        var size: usize = @sizeOf(u64);
        if (c.sysctlbyname("hw.memsize", &mem_bytes, &size, null, 0) != 0) {
            return "Unknown";
        }
        return fmt.allocPrint(allocator, "{d} MiB", .{mem_bytes / (1024 * 1024)});
    } else {
        return "Unknown";
    }
}

/// Parses a /proc/meminfo line of the form "Key:   12345 kB" and returns the kB value.
pub fn parseKbLine(line: []const u8) u64 {
    const colon_pos = mem.indexOfScalar(u8, line, ':') orelse return 0;
    const rest = mem.trim(u8, line[colon_pos + 1 ..], " \t");
    // Strip " kB" suffix before parsing the integer.
    const kb_suffix_pos = mem.indexOf(u8, rest, " kB") orelse rest.len;
    return fmt.parseInt(u64, rest[0..kb_suffix_pos], 10) catch 0;
}

/// Prints all system information lines to the writer.
fn printInfo(allocator: mem.Allocator, writer: *std.Io.Writer) !void {
    const uname_info = std.posix.uname();
    const hostname = mem.sliceTo(&uname_info.nodename, 0);
    const kernel = mem.sliceTo(&uname_info.release, 0);

    // Prefer USER, fall back to USERNAME (common on some environments).
    const username = std.posix.getenv("USER") orelse
        std.posix.getenv("USERNAME") orelse "unknown";

    // Extract the basename from the SHELL path (e.g. "/bin/bash" → "bash").
    const shell_path = std.posix.getenv("SHELL") orelse "unknown";
    const last_slash = mem.lastIndexOfScalar(u8, shell_path, '/');
    const shell = if (last_slash) |idx| shell_path[idx + 1 ..] else shell_path;

    const arch = @tagName(builtin.cpu.arch);
    const os_name = try getOs(allocator);
    const cpu_info = try getCpu(allocator);
    const memory_info = try getMemory(allocator);
    const uptime_info = try getUptime(allocator);

    // Print "username@hostname" header.
    try writer.writeAll(username);
    try writer.writeAll("@");
    try writer.writeAll(hostname);
    try writer.writeAll("\n");

    // Print a separator whose length matches the header.
    const header_len = username.len + 1 + hostname.len;
    for (0..header_len) |_| try writer.writeAll("─");
    try writer.writeAll("\n");

    // Print labelled info fields. Labels are padded to 8 characters so values align.
    try writer.print("OS:     {s} {s}\n", .{ os_name, arch });
    try writer.print("Kernel: {s}\n", .{kernel});
    try writer.print("Uptime: {s}\n", .{uptime_info});
    try writer.print("Shell:  {s}\n", .{shell});
    try writer.print("CPU:    {s}\n", .{cpu_info});
    try writer.print("Memory: {s}\n", .{memory_info});
}

test "format uptime: seconds only" {
    // Values below 60 s should show only seconds.
    const result = try formatUptime(std.testing.allocator, 45);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("45 secs", result);
}

test "format uptime: minutes and seconds" {
    const result = try formatUptime(std.testing.allocator, 90);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 mins, 30 secs", result);
}

test "format uptime: hours and minutes" {
    // 1 hour + 1 minute + 1 second — seconds are dropped at the hours scale.
    const result = try formatUptime(std.testing.allocator, 3661);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 hours, 1 mins", result);
}

test "format uptime: days hours minutes" {
    // 1 day + 1 hour + 1 minute + 1 second.
    const result = try formatUptime(std.testing.allocator, 90061);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 days, 1 hours, 1 mins", result);
}

test "parse kb line" {
    // Standard /proc/meminfo format with varying amounts of whitespace.
    try std.testing.expectEqual(@as(u64, 16280284), parseKbLine("MemTotal:       16280284 kB"));
    try std.testing.expectEqual(@as(u64, 8123456), parseKbLine("MemAvailable:    8123456 kB"));
    try std.testing.expectEqual(@as(u64, 0), parseKbLine("InvalidLine"));
}
