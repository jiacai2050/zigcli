//! Shared utilities for zfetch, platform-independent.

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const fs = std.fs;

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/statvfs.h");
    @cInclude("sys/utsname.h");
    @cInclude("netinet/in.h");
    @cInclude("ifaddrs.h");
    @cInclude("arpa/inet.h");
});

/// Gets hostname via C uname (works on all POSIX).
pub fn getHostname(allocator: mem.Allocator) ![]const u8 {
    var uts: c.struct_utsname = undefined;
    if (c.uname(&uts) != 0) return "unknown";
    return allocator.dupe(u8, mem.sliceTo(&uts.nodename, 0));
}

/// Gets kernel release via C uname (works on all POSIX).
pub fn getKernel(allocator: mem.Allocator) ![]const u8 {
    var uts: c.struct_utsname = undefined;
    if (c.uname(&uts) != 0) return "unknown";
    return allocator.dupe(u8, mem.sliceTo(&uts.release, 0));
}

/// Formats a raw uptime in seconds as a human-readable string.
pub fn formatUptime(allocator: mem.Allocator, uptime_s: u64) ![]const u8 {
    const s_per_min: u64 = 60;
    const s_per_hour: u64 = 60 * s_per_min;
    const s_per_day: u64 = 24 * s_per_hour;

    const days = uptime_s / s_per_day;
    const hours = (uptime_s % s_per_day) / s_per_hour;
    const minutes = (uptime_s % s_per_hour) / s_per_min;
    const seconds = uptime_s % s_per_min;

    const p = plural;
    if (days > 0) {
        return fmt.allocPrint(allocator, "{d} {s}, {d} {s}, {d} {s}", .{
            days,    p(days, "day"),
            hours,   p(hours, "hour"),
            minutes, p(minutes, "min"),
        });
    }

    if (hours > 0) {
        return fmt.allocPrint(allocator, "{d} {s}, {d} {s}", .{
            hours,   p(hours, "hour"),
            minutes, p(minutes, "min"),
        });
    }

    if (minutes > 0) {
        return fmt.allocPrint(allocator, "{d} {s}, {d} {s}", .{
            minutes, p(minutes, "min"),
            seconds, p(seconds, "sec"),
        });
    }

    return fmt.allocPrint(allocator, "{d} {s}", .{
        seconds, p(seconds, "sec"),
    });
}

fn plural(count: u64, singular: []const u8) []const u8 {
    if (count == 1) return singular;
    return switch (singular[0]) {
        'm' => "mins",
        's' => "secs",
        'h' => "hours",
        'd' => "days",
        else => singular,
    };
}

/// Gets disk usage for the given mount points.
pub fn getDiskMounts(
    allocator: mem.Allocator,
    mounts: []const []const u8,
) ![]const u8 {
    var parts: std.ArrayList(u8) = .empty;
    const GiB = 1024 * 1024 * 1024;
    var seen_dev: [8]u64 = .{0} ** 8;
    var seen_count: usize = 0;

    for (mounts) |mount| {
        var vfs: c.struct_statvfs = undefined;
        if (c.statvfs(mount.ptr, &vfs) != 0) continue;

        // Deduplicate by filesystem ID.
        const fsid: u64 = @bitCast(vfs.f_fsid);
        var dup = false;
        for (seen_dev[0..seen_count]) |s| {
            if (s == fsid) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen_count >= seen_dev.len) continue;
        seen_dev[seen_count] = fsid;
        seen_count += 1;

        const bpb = vfs.f_frsize;
        const bytes_total = @as(u64, vfs.f_blocks) * bpb;
        const bytes_free = @as(u64, vfs.f_bfree) * bpb;
        const bytes_used = bytes_total -| bytes_free;
        const percent = if (bytes_total > 0)
            (bytes_used * 100 / bytes_total)
        else
            0;

        if (parts.items.len > 0) {
            try parts.appendSlice(allocator, ", ");
        }
        const entry = try fmt.allocPrint(
            allocator,
            "{s}: {d} GiB / {d} GiB ({d}%)",
            .{ mount, bytes_used / GiB, bytes_total / GiB, percent },
        );
        try parts.appendSlice(allocator, entry);
    }

    return if (parts.items.len > 0) parts.items else "Unknown";
}

/// Gets the local IP address using getifaddrs.
pub fn getLocalIp(allocator: mem.Allocator) ![]const u8 {
    var ifap: ?*c.struct_ifaddrs = null;
    if (c.getifaddrs(&ifap) != 0) return "Unknown";
    defer c.freeifaddrs(ifap);

    var parts: std.ArrayList(u8) = .empty;
    var ifa = ifap;
    while (ifa) |a| : (ifa = a.ifa_next) {
        const sa = a.ifa_addr orelse continue;
        if (sa.*.sa_family != c.AF_INET) continue;

        const name = mem.sliceTo(a.ifa_name, 0);
        // Skip loopback.
        if (mem.eql(u8, name, "lo") or mem.eql(u8, name, "lo0")) {
            continue;
        }

        var addr_buf: [c.INET_ADDRSTRLEN]u8 = undefined;
        const sin: *const c.struct_sockaddr_in =
            @ptrCast(@alignCast(sa));
        const result = c.inet_ntop(
            c.AF_INET,
            &sin.sin_addr,
            &addr_buf,
            c.INET_ADDRSTRLEN,
        );
        if (result == null) continue;

        const ip = mem.sliceTo(&addr_buf, 0);
        if (parts.items.len > 0) {
            try parts.appendSlice(allocator, ", ");
        }
        const entry = try fmt.allocPrint(
            allocator,
            "{s} ({s})",
            .{ ip, name },
        );
        try parts.appendSlice(allocator, entry);
    }

    return if (parts.items.len > 0) parts.items else "Unknown";
}

/// Gets shell name with version by running `<shell> --version`.
pub fn getShellVersion(
    allocator: mem.Allocator,
    shell: []const u8,
) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ shell, "--version" },
    }) catch return allocator.dupe(u8, shell);

    const first_line = if (mem.indexOfScalar(u8, result.stdout, '\n')) |nl|
        result.stdout[0..nl]
    else
        result.stdout;

    for (first_line, 0..) |ch, i| {
        if (ch >= '0' and ch <= '9') {
            var end = i;
            while (end < first_line.len) : (end += 1) {
                switch (first_line[end]) {
                    '0'...'9', '.', '-' => {},
                    else => break,
                }
            }
            return fmt.allocPrint(
                allocator,
                "{s} {s}",
                .{ shell, first_line[i..end] },
            );
        }
    }

    return allocator.dupe(u8, shell);
}

/// Gets the terminal name from environment variables.
pub fn getTerminal() []const u8 {
    return std.posix.getenv("TERM_PROGRAM") orelse
        std.posix.getenv("TERM") orelse "Unknown";
}

/// Parses a /proc/meminfo line "Key: 12345 kB" and returns the kB value.
pub fn parseKbLine(line: []const u8) u64 {
    const colon_pos = mem.indexOfScalar(u8, line, ':') orelse return 0;
    const rest = mem.trim(u8, line[colon_pos + 1 ..], " \t");
    const kb_suffix_pos = mem.indexOf(u8, rest, " kB") orelse rest.len;
    return fmt.parseInt(u64, rest[0..kb_suffix_pos], 10) catch 0;
}

/// Reads PRETTY_NAME from /etc/os-release.
pub fn getOsFromRelease(allocator: mem.Allocator, fallback: []const u8) ![]const u8 {
    const file = fs.cwd().openFile("/etc/os-release", .{}) catch {
        return fallback;
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 4096);
    var iter = mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (!mem.startsWith(u8, line, "PRETTY_NAME=")) continue;
        const raw = line["PRETTY_NAME=".len..];
        if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
            return allocator.dupe(u8, raw[1 .. raw.len - 1]);
        }
        return allocator.dupe(u8, raw);
    }
    return fallback;
}

/// Reads uptime from /proc/uptime (Linux, FreeBSD with procfs).
pub fn getUptimeFromProc(allocator: mem.Allocator) ![]const u8 {
    const file = fs.cwd().openFile("/proc/uptime", .{}) catch {
        return "Unknown";
    };
    defer file.close();
    var buf: [64]u8 = undefined;
    const byte_count = try file.read(&buf);
    const content = buf[0..byte_count];

    const space_pos = mem.indexOfScalar(u8, content, ' ') orelse content.len;
    const dot_pos = mem.indexOfScalar(u8, content[0..space_pos], '.') orelse space_pos;
    const uptime_s = fmt.parseInt(u64, content[0..dot_pos], 10) catch return "Unknown";
    return formatUptime(allocator, uptime_s);
}

/// Reads battery from /sys/class/power_supply (Linux, FreeBSD).
pub fn getBatteryFromSys(allocator: mem.Allocator) ![]const u8 {
    var ps_dir = fs.openDirAbsolute(
        "/sys/class/power_supply",
        .{ .iterate = true },
    ) catch return "No Battery";
    defer ps_dir.close();
    var iter = ps_dir.iterate();
    while (try iter.next()) |entry| {
        const type_path = try fmt.allocPrint(
            allocator,
            "/sys/class/power_supply/{s}/type",
            .{entry.name},
        );
        const type_file = fs.openFileAbsolute(type_path, .{}) catch continue;
        defer type_file.close();
        var type_buf: [16]u8 = undefined;
        const n_type = type_file.read(&type_buf) catch continue;
        const dev_type = mem.trim(u8, type_buf[0..n_type], " \n\t");
        if (!mem.eql(u8, dev_type, "Battery")) continue;

        const cap_path = try fmt.allocPrint(
            allocator,
            "/sys/class/power_supply/{s}/capacity",
            .{entry.name},
        );
        const cap_file = fs.openFileAbsolute(cap_path, .{}) catch continue;
        defer cap_file.close();
        const stat_path = try fmt.allocPrint(
            allocator,
            "/sys/class/power_supply/{s}/status",
            .{entry.name},
        );
        const stat_file = fs.openFileAbsolute(stat_path, .{}) catch continue;
        defer stat_file.close();

        var cap_buf: [8]u8 = undefined;
        const n_cap = cap_file.read(&cap_buf) catch continue;
        const capacity = fmt.parseInt(
            u32,
            mem.trim(u8, cap_buf[0..n_cap], " \n\t"),
            10,
        ) catch continue;

        var stat_buf: [16]u8 = undefined;
        const n_stat = stat_file.read(&stat_buf) catch continue;
        const status = mem.trim(u8, stat_buf[0..n_stat], " \n\t");

        return fmt.allocPrint(
            allocator,
            "{d}% [{s}]",
            .{ capacity, status },
        );
    }
    return "No Battery";
}

/// Detects dark theme from GTK/dconf config files.
pub fn getThemeFromGtk() []const u8 {
    const home = std.posix.getenv("HOME") orelse return "Unknown";
    var buf: [1024]u8 = undefined;

    const config_files = [_][]const u8{
        "/.config/dconf/user",
        "/.config/gtk-4.0/settings.ini",
        "/.config/gtk-3.0/settings.ini",
    };
    const needles = [_][]const u8{
        "prefer-dark",
        "gtk-application-prefer-dark-theme=1",
        "gtk-application-prefer-dark-theme=true",
    };

    for (config_files) |suffix| {
        const path = fmt.bufPrint(&buf, "{s}{s}", .{ home, suffix }) catch continue;
        const file = fs.openFileAbsolute(path, .{}) catch continue;
        defer file.close();
        const n = file.readAll(&buf) catch continue;
        for (needles) |needle| {
            if (mem.indexOf(u8, buf[0..n], needle) != null) return "Dark";
        }
    }

    return "Light";
}

/// Reads memory info from /proc/meminfo (Linux, FreeBSD with procfs).
pub fn getMemoryFromProc(allocator: mem.Allocator) ![]const u8 {
    const file = fs.cwd().openFile("/proc/meminfo", .{}) catch {
        return "Unknown";
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 4096);
    var bytes_total_kb: u64 = 0;
    var bytes_available_kb: u64 = 0;
    var bytes_swap_total_kb: u64 = 0;
    var bytes_swap_free_kb: u64 = 0;

    var iter = mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (mem.startsWith(u8, line, "MemTotal:")) {
            bytes_total_kb = parseKbLine(line);
        } else if (mem.startsWith(u8, line, "MemAvailable:")) {
            bytes_available_kb = parseKbLine(line);
        } else if (mem.startsWith(u8, line, "SwapTotal:")) {
            bytes_swap_total_kb = parseKbLine(line);
        } else if (mem.startsWith(u8, line, "SwapFree:")) {
            bytes_swap_free_kb = parseKbLine(line);
        }
    }
    if (bytes_total_kb == 0) return "Unknown";

    const bytes_used_kb = bytes_total_kb -| bytes_available_kb;
    const percent = if (bytes_total_kb > 0)
        (bytes_used_kb * 100 / bytes_total_kb)
    else
        0;
    const bytes_swap_used_kb = bytes_swap_total_kb -| bytes_swap_free_kb;

    if (bytes_swap_total_kb > 0) {
        return fmt.allocPrint(
            allocator,
            "{d} MiB / {d} MiB ({d}%)" ++
                " [Swap: {d} MiB / {d} MiB]",
            .{
                bytes_used_kb / 1024,
                bytes_total_kb / 1024,
                percent,
                bytes_swap_used_kb / 1024,
                bytes_swap_total_kb / 1024,
            },
        );
    }
    return fmt.allocPrint(allocator, "{d} MiB / {d} MiB ({d}%)", .{
        bytes_used_kb / 1024,
        bytes_total_kb / 1024,
        percent,
    });
}

/// Reads CPU info from /proc/cpuinfo.
pub fn getCpuFromProc(allocator: mem.Allocator) ![]const u8 {
    const file = fs.cwd().openFile("/proc/cpuinfo", .{}) catch {
        return "Unknown";
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 65536);
    var iter = mem.splitScalar(u8, content, '\n');
    var model: ?[]const u8 = null;
    var logical_count: u32 = 0;
    var physical_cores_per_socket: u32 = 0;

    while (iter.next()) |line| {
        if (mem.startsWith(u8, line, "model name")) {
            if (model == null) {
                const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
                model = mem.trim(u8, line[colon + 1 ..], " \t");
            }
        } else if (mem.startsWith(u8, line, "processor")) {
            logical_count += 1;
        } else if (mem.startsWith(u8, line, "cpu cores")) {
            if (physical_cores_per_socket == 0) {
                const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
                physical_cores_per_socket = fmt.parseInt(
                    u32,
                    mem.trim(u8, line[colon + 1 ..], " \t"),
                    10,
                ) catch 0;
            }
        }
    }

    if (model) |m| {
        if (physical_cores_per_socket > 0) {
            return fmt.allocPrint(
                allocator,
                "{s} ({d} logical, {d} physical cores)",
                .{ m, logical_count, physical_cores_per_socket },
            );
        }
        return fmt.allocPrint(
            allocator,
            "{s} ({d} logical cores)",
            .{ m, logical_count },
        );
    }
    return "Unknown";
}

/// Reads host from DMI (Linux, some FreeBSD).
pub fn getHostFromDmi(allocator: mem.Allocator, fallback: []const u8) ![]const u8 {
    const vendor_file = fs.openFileAbsolute(
        "/sys/class/dmi/id/sys_vendor",
        .{},
    ) catch return fallback;
    defer vendor_file.close();
    const product_file = fs.openFileAbsolute(
        "/sys/class/dmi/id/product_name",
        .{},
    ) catch return fallback;
    defer product_file.close();

    const vendor = try vendor_file.readToEndAlloc(allocator, 64);
    const product = try product_file.readToEndAlloc(allocator, 64);

    return fmt.allocPrint(allocator, "{s} {s}", .{
        mem.trim(u8, vendor, " \n\t"),
        mem.trim(u8, product, " \n\t"),
    });
}

/// Reads display resolution from DRM sysfs.
pub fn getResolutionFromDrm(allocator: mem.Allocator) ![]const u8 {
    var drm_dir = fs.openDirAbsolute(
        "/sys/class/drm",
        .{ .iterate = true },
    ) catch return "Unknown";
    defer drm_dir.close();
    var parts: std.ArrayList(u8) = .empty;
    var iter = drm_dir.iterate();
    while (try iter.next()) |entry| {
        if (!mem.startsWith(u8, entry.name, "card")) continue;
        if (mem.indexOfScalar(u8, entry.name[4..], '-') == null) continue;

        const modes_path = try fmt.allocPrint(
            allocator,
            "/sys/class/drm/{s}/modes",
            .{entry.name},
        );
        const file = fs.openFileAbsolute(modes_path, .{}) catch continue;
        defer file.close();
        var buf: [64]u8 = undefined;
        const n = file.read(&buf) catch continue;
        if (n == 0) continue;
        const first_line = mem.sliceTo(buf[0..n], '\n');
        const mode_str = mem.trim(u8, first_line, " \n\r\t");
        if (mode_str.len == 0) continue;

        if (parts.items.len > 0) {
            try parts.appendSlice(allocator, ", ");
        }
        try parts.appendSlice(allocator, mode_str);
    }
    return if (parts.items.len > 0) parts.items else "Unknown";
}

/// Counts dpkg packages from /var/lib/dpkg/info.
pub fn getPackagesDpkg(allocator: mem.Allocator) ![]const u8 {
    var dir = fs.openDirAbsolute(
        "/var/lib/dpkg/info",
        .{ .iterate = true },
    ) catch return "Unknown";
    defer dir.close();
    var count: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (mem.endsWith(u8, entry.name, ".list")) count += 1;
    }
    if (count > 0) {
        return fmt.allocPrint(allocator, "{d} (dpkg)", .{count});
    }
    return "Unknown";
}

/// Counts pkg packages from /var/db/pkg (FreeBSD).
pub fn getPackagesPkg(allocator: mem.Allocator) ![]const u8 {
    // TODO: Implement sqlite query for /var/db/pkg/local.sqlite.
    // For now, count directories in /var/db/pkg as fallback.
    var pkg_dir = fs.openDirAbsolute(
        "/var/db/pkg",
        .{ .iterate = true },
    ) catch return "Unknown";
    defer pkg_dir.close();
    var count: u32 = 0;
    var iter = pkg_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) count += 1;
    }
    if (count > 0) {
        return fmt.allocPrint(
            allocator,
            "{d} (pkg)",
            .{count},
        );
    }
    return "Unknown";
}

// ── Tests ───────────────────────────────────────

test "format uptime: seconds only" {
    const result = try formatUptime(std.testing.allocator, 45);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("45 secs", result);
}

test "format uptime: one second" {
    const result = try formatUptime(std.testing.allocator, 1);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 sec", result);
}

test "format uptime: minutes and seconds" {
    const result = try formatUptime(std.testing.allocator, 90);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 min, 30 secs", result);
}

test "format uptime: hours and minutes" {
    const result = try formatUptime(std.testing.allocator, 3661);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 hour, 1 min", result);
}

test "format uptime: days hours minutes" {
    const result = try formatUptime(std.testing.allocator, 90061);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 day, 1 hour, 1 min", result);
}

test "format uptime: plural days" {
    const a = std.testing.allocator;
    const result = try formatUptime(a, 2 * 86400 + 3 * 3600 + 5 * 60);
    defer a.free(result);
    try std.testing.expectEqualStrings("2 days, 3 hours, 5 mins", result);
}

test "parse kb line" {
    try std.testing.expectEqual(
        @as(u64, 16280284),
        parseKbLine("MemTotal:       16280284 kB"),
    );
    try std.testing.expectEqual(
        @as(u64, 8123456),
        parseKbLine("MemAvailable:    8123456 kB"),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        parseKbLine("InvalidLine"),
    );
}
