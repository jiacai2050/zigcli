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

// Import common and OS-specific C headers.
const c = @cImport({
    @cInclude("sys/time.h");
    @cInclude("sys/statvfs.h");
    @cInclude("unistd.h");
    @cInclude("ifaddrs.h");
    @cInclude("arpa/inet.h");
    if (native_os == .macos) {
        @cInclude("sys/sysctl.h");
        @cInclude("sys/mount.h");
        @cInclude("mach/mach_host.h");
        @cInclude("mach/mach_init.h");
        @cInclude("mach/vm_statistics.h");
        @cInclude("CoreGraphics/CoreGraphics.h");
        @cInclude("CoreFoundation/CoreFoundation.h");
        @cInclude("IOKit/ps/IOPowerSources.h");
        @cInclude("IOKit/ps/IOPSKeys.h");
    }
});

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try simargs.parse(allocator, struct {
        help: bool = false,
        version: bool = false,
        all: bool = false,

        pub const __shorts__ = .{
            .help = .h,
            .version = .v,
            .all = .a,
        };

        pub const __messages__ = .{
            .help = "Print help information.",
            .version = "Print version.",
            .all = "Show all info including packages.",
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

    try printInfo(arena_alloc, &writer.interface, opt.options.all);
    try writer.interface.flush();
}

/// Prints all system information lines to the writer.
fn printInfo(allocator: mem.Allocator, writer: *std.Io.Writer, show_all: bool) !void {
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
    const host_info = try getHost(allocator);
    const cpu_info = try getCpu(allocator);
    const disk_info = try getDisk(allocator);
    const resolution_info = try getResolution(allocator);
    const battery_info = try getBattery(allocator);
    const theme_info = getTheme();
    const bytes_per_page = fetchPageSize();
    const memory_info = try getMemory(allocator, bytes_per_page);
    const page_size_info = try fmt.allocPrint(allocator, "{d} KiB", .{bytes_per_page / 1024});
    const uptime_info = try getUptime(allocator);
    const terminal_info = getTerminal();

    // Print "username@hostname" header.
    try writer.writeAll(username);
    try writer.writeAll("@");
    try writer.writeAll(hostname);
    try writer.writeAll("\n");

    // Print a separator whose length matches the header.
    const header_len = username.len + 1 + hostname.len;
    var i: usize = 0;
    while (i < header_len) : (i += 1) try writer.writeAll("─");
    try writer.writeAll("\n");

    try writer.print("OS:          {s} {s}\n", .{ os_name, arch });
    try writer.print("Host:        {s}\n", .{host_info});
    try writer.print("Kernel:      {s}\n", .{kernel});
    try writer.print("Uptime:      {s}\n", .{uptime_info});
    try writer.print("Shell:       {s}\n", .{shell});
    try writer.print("Terminal:    {s}\n", .{terminal_info});
    try writer.print("Resolution:  {s}\n", .{resolution_info});
    try writer.print("Theme:       {s}\n", .{theme_info});
    try writer.print("CPU:         {s}\n", .{cpu_info});
    try writer.print("Memory:      {s}\n", .{memory_info});
    try writer.print("Disk:        {s}\n", .{disk_info});
    try writer.print("Battery:     {s}\n", .{battery_info});
    try writer.print("Page:        {s}\n", .{page_size_info});

    const ip_info = try getLocalIp(allocator);
    try writer.print("Local IP:    {s}\n", .{ip_info});

    if (show_all) {
        const packages_info = try getPackages(allocator);
        try writer.print("Packages:    {s}\n", .{packages_info});
    }

    // Color palette (matches fastfetch: background colors, width=3, range 0-15)
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

/// Formats a raw uptime in seconds as a human-readable string, e.g. "2 hours, 30 mins".
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

    return fmt.allocPrint(allocator, "{d} {s}", .{ seconds, p(seconds, "sec") });
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

/// Gets system uptime as a human-readable string.
fn getUptime(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .linux) {
        // /proc/uptime contains "uptime_seconds idle_seconds".
        const file = try fs.cwd().openFile("/proc/uptime", .{});
        defer file.close();
        var buf: [64]u8 = undefined;
        const byte_count = try file.read(&buf);
        const content = buf[0..byte_count];

        // Parse only the first field (uptime in seconds, possibly fractional).
        const space_pos = mem.indexOfScalar(u8, content, ' ') orelse content.len;
        const dot_pos = mem.indexOfScalar(u8, content[0..space_pos], '.') orelse space_pos;
        const uptime_s = fmt.parseInt(u64, content[0..dot_pos], 10) catch return "Unknown";
        return formatUptime(allocator, uptime_s);
    }

    if (comptime native_os == .macos) {
        // kern.boottime is a struct timeval; compute uptime as now - tv_sec.
        var boot_time: c.struct_timeval = undefined;
        var boot_time_size: usize = @sizeOf(c.struct_timeval);
        if (c.sysctlbyname("kern.boottime", &boot_time, &boot_time_size, null, 0) != 0) {
            return "Unknown";
        }
        const now_s: i64 = std.time.timestamp();
        const boot_s: i64 = @intCast(boot_time.tv_sec);
        if (now_s < boot_s) return "Unknown";
        const uptime_s: u64 = @intCast(now_s - boot_s);
        return formatUptime(allocator, uptime_s);
    }

    return "Unknown";
}

/// Gets the OS pretty name, e.g. "Ubuntu 22.04.3 LTS" or "macOS 14.1".
fn getOs(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .linux) {
        // Read PRETTY_NAME from /etc/os-release.
        const file = fs.cwd().openFile("/etc/os-release", .{}) catch {
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
    }

    if (comptime native_os == .macos) {
        var version_buf: [64]u8 = undefined;
        var version_size: usize = version_buf.len;
        if (c.sysctlbyname("kern.osproductversion", &version_buf, &version_size, null, 0) != 0) {
            return "macOS";
        }
        const version = mem.trimRight(u8, version_buf[0..version_size], &[_]u8{0});
        return fmt.allocPrint(allocator, "macOS {s}", .{version});
    }

    const uname_info = std.posix.uname();
    return allocator.dupe(u8, mem.sliceTo(&uname_info.sysname, 0));
}

/// Gets the CPU model string, e.g. "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz".
fn getCpu(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .linux) {
        // The first "model name" entry in /proc/cpuinfo is the CPU model.
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
                    const colon_pos = mem.indexOfScalar(u8, line, ':') orelse continue;
                    model = mem.trim(u8, line[colon_pos + 1 ..], " \t");
                }
            } else if (mem.startsWith(u8, line, "processor")) {
                logical_count += 1;
            } else if (mem.startsWith(u8, line, "cpu cores")) {
                if (physical_cores_per_socket == 0) {
                    const colon_pos = mem.indexOfScalar(u8, line, ':') orelse continue;
                    physical_cores_per_socket = fmt.parseInt(u32, mem.trim(u8, line[colon_pos + 1 ..], " \t"), 10) catch 0;
                }
            }
        }

        if (model) |m| {
            if (physical_cores_per_socket > 0) {
                return fmt.allocPrint(allocator, "{s} ({d} logical, {d} physical cores)", .{ m, logical_count, physical_cores_per_socket });
            }
            return fmt.allocPrint(allocator, "{s} ({d} logical cores)", .{ m, logical_count });
        }
        return "Unknown";
    }

    if (comptime native_os == .macos) {
        var cpu_buf: [256]u8 = undefined;
        var cpu_size: usize = cpu_buf.len;
        if (c.sysctlbyname("machdep.cpu.brand_string", &cpu_buf, &cpu_size, null, 0) != 0) {
            return "Unknown";
        }
        const brand = mem.trimRight(u8, cpu_buf[0..cpu_size], &[_]u8{0});

        var cpu_physical_count: u32 = 0;
        var pc_size: usize = @sizeOf(u32);
        _ = c.sysctlbyname("hw.physicalcpu", &cpu_physical_count, &pc_size, null, 0);

        var p_cores_count: u32 = 0;
        var p_size: usize = @sizeOf(u32);
        // hw.perflevel0 refers to Performance cores on Apple Silicon
        _ = c.sysctlbyname("hw.perflevel0.physicalcpu", &p_cores_count, &p_size, null, 0);

        var e_cores_count: u32 = 0;
        var e_size: usize = @sizeOf(u32);
        // hw.perflevel1 refers to Efficiency cores on Apple Silicon
        _ = c.sysctlbyname("hw.perflevel1.physicalcpu", &e_cores_count, &e_size, null, 0);

        if (p_cores_count > 0 or e_cores_count > 0) {
            return fmt.allocPrint(allocator, "{s} ({d} cores: {d}P + {d}E)", .{
                brand,
                cpu_physical_count,
                p_cores_count,
                e_cores_count,
            });
        }

        if (cpu_physical_count > 0) {
            return fmt.allocPrint(allocator, "{s} ({d} cores)", .{ brand, cpu_physical_count });
        }

        return allocator.dupe(u8, brand);
    }

    return "Unknown";
}

/// Gets the system host/model, e.g. "Mac14,9" or "ThinkPad X1".
fn getHost(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .macos) {
        var model_buf: [128]u8 = undefined;
        var model_size: usize = model_buf.len;
        if (c.sysctlbyname("hw.model", &model_buf, &model_size, null, 0) != 0) {
            return "Mac";
        }
        const model = mem.trimRight(u8, model_buf[0..model_size], &[_]u8{0});
        return allocator.dupe(u8, model);
    }

    if (comptime native_os == .linux) {
        const vendor_file = fs.openFileAbsolute("/sys/class/dmi/id/sys_vendor", .{}) catch return "Linux";
        defer vendor_file.close();
        const product_file = fs.openFileAbsolute("/sys/class/dmi/id/product_name", .{}) catch return "Linux";
        defer product_file.close();

        const vendor = try vendor_file.readToEndAlloc(allocator, 64);
        const product = try product_file.readToEndAlloc(allocator, 64);

        return fmt.allocPrint(allocator, "{s} {s}", .{ mem.trim(u8, vendor, " \n\t"), mem.trim(u8, product, " \n\t") });
    }

    return "Unknown";
}

/// Gets disk usage for important mount points.
fn getDisk(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .macos) {
        return getDiskMounts(allocator, &[_][]const u8{"/"});
    }
    if (comptime native_os == .linux) {
        return getDiskMounts(allocator, &[_][]const u8{ "/", "/home" });
    }
    return "Unknown";
}

fn getDiskMounts(allocator: mem.Allocator, mounts: []const []const u8) ![]const u8 {
    var parts: std.ArrayList(u8) = .empty;
    const GiB = 1024 * 1024 * 1024;
    var seen_dev: [8]u64 = .{0} ** 8;
    var seen_count: usize = 0;

    for (mounts) |mount| {
        var vfs: c.struct_statvfs = undefined;
        if (c.statvfs(mount.ptr, &vfs) != 0) continue;

        // Deduplicate by filesystem ID to avoid counting the same device twice.
        const fsid: u64 = @bitCast(vfs.f_fsid);
        var dup = false;
        for (seen_dev[0..seen_count]) |s| {
            if (s == fsid) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        if (seen_count < seen_dev.len) {
            seen_dev[seen_count] = fsid;
            seen_count += 1;
        }

        const bytes_per_block = vfs.f_frsize;
        const bytes_total = @as(u64, vfs.f_blocks) * bytes_per_block;
        const bytes_free = @as(u64, vfs.f_bfree) * bytes_per_block;
        const bytes_used = bytes_total -| bytes_free;
        const percent = if (bytes_total > 0) (bytes_used * 100 / bytes_total) else 0;

        if (parts.items.len > 0) try parts.appendSlice(allocator, ", ");
        const entry = try fmt.allocPrint(allocator, "{s}: {d} GiB / {d} GiB ({d}%)", .{
            mount, bytes_used / GiB, bytes_total / GiB, percent,
        });
        try parts.appendSlice(allocator, entry);
    }

    return if (parts.items.len > 0) parts.items else "Unknown";
}

/// Gets display resolution(s) and refresh rate.
fn getResolution(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .macos) {
        var display_ids: [8]c.CGDirectDisplayID = undefined;
        var display_count: u32 = 0;
        if (c.CGGetActiveDisplayList(display_ids.len, &display_ids, &display_count) != 0 or display_count == 0) {
            return "Unknown";
        }

        var parts: std.ArrayList(u8) = .empty;
        for (display_ids[0..display_count]) |did| {
            const mode = c.CGDisplayCopyDisplayMode(did);
            if (mode == null) continue;
            defer c.CGDisplayModeRelease(mode);

            const width: u32 = @intCast(c.CGDisplayModeGetWidth(mode));
            const height: u32 = @intCast(c.CGDisplayModeGetHeight(mode));
            const refresh_rate = c.CGDisplayModeGetRefreshRate(mode);

            if (parts.items.len > 0) try parts.appendSlice(allocator, ", ");
            if (refresh_rate > 0) {
                const entry = try fmt.allocPrint(allocator, "{d}x{d} @ {d}Hz", .{ width, height, @as(u32, @intFromFloat(refresh_rate)) });
                try parts.appendSlice(allocator, entry);
            } else {
                const entry = try fmt.allocPrint(allocator, "{d}x{d}", .{ width, height });
                try parts.appendSlice(allocator, entry);
            }
        }
        return if (parts.items.len > 0) parts.items else "Unknown";
    }

    if (comptime native_os == .linux) {
        // DRM connectors are named like "card0-HDMI-A-1", "card0-eDP-1", etc.
        var drm_dir = fs.openDirAbsolute("/sys/class/drm", .{ .iterate = true }) catch return "Unknown";
        defer drm_dir.close();
        var parts: std.ArrayList(u8) = .empty;
        var iter = drm_dir.iterate();
        while (try iter.next()) |entry| {
            // Connectors contain a dash after "cardN"
            if (!mem.startsWith(u8, entry.name, "card")) continue;
            // Skip bare "cardN" directories (no connector suffix)
            if (mem.indexOfScalar(u8, entry.name[4..], '-') == null) continue;

            const modes_path = try fmt.allocPrint(allocator, "/sys/class/drm/{s}/modes", .{entry.name});
            const file = fs.openFileAbsolute(modes_path, .{}) catch continue;
            defer file.close();
            var buf: [64]u8 = undefined;
            const n = file.read(&buf) catch continue;
            if (n == 0) continue;
            const first_line = mem.sliceTo(buf[0..n], '\n');
            const mode_str = mem.trim(u8, first_line, " \n\r\t");
            if (mode_str.len == 0) continue;

            if (parts.items.len > 0) try parts.appendSlice(allocator, ", ");
            try parts.appendSlice(allocator, mode_str);
        }
        return if (parts.items.len > 0) parts.items else "Unknown";
    }

    return "Unknown";
}

/// Gets battery status as "percent% [Charging/Discharging]".
fn getBattery(allocator: mem.Allocator) ![]const u8 {
    if (comptime native_os == .macos) {
        const info = c.IOPSCopyPowerSourcesInfo();
        defer _ = c.CFRelease(info);
        const list = c.IOPSCopyPowerSourcesList(info);
        defer _ = c.CFRelease(list);

        const count = c.CFArrayGetCount(list);
        if (count == 0) return "No Battery";

        const source = c.CFArrayGetValueAtIndex(list, 0);
        const description = c.IOPSGetPowerSourceDescription(info, source);

        // We need to extract percent and state.
        var battery_capacity: i32 = 0;
        const key_capacity = c.CFStringCreateWithCString(null, c.kIOPSCurrentCapacityKey, c.kCFStringEncodingUTF8);
        defer _ = c.CFRelease(key_capacity);
        const val_capacity = c.CFDictionaryGetValue(description, key_capacity);
        if (val_capacity != null) {
            _ = c.CFNumberGetValue(@ptrCast(val_capacity), c.kCFNumberSInt32Type, &battery_capacity);
        }

        var is_charging = false;
        const key_charging = c.CFStringCreateWithCString(null, c.kIOPSIsChargingKey, c.kCFStringEncodingUTF8);
        defer _ = c.CFRelease(key_charging);
        const val_charging = c.CFDictionaryGetValue(description, key_charging);
        if (val_charging != null) {
            is_charging = c.CFBooleanGetValue(@ptrCast(val_charging)) != 0;
        }

        return fmt.allocPrint(allocator, "{d}% [{s}]", .{
            battery_capacity,
            if (is_charging) "Charging" else "Discharging",
        });
    }

    if (comptime native_os == .linux) {
        // Scan /sys/class/power_supply/ for battery devices.
        var ps_dir = fs.openDirAbsolute("/sys/class/power_supply", .{ .iterate = true }) catch return "No Battery";
        defer ps_dir.close();
        var iter = ps_dir.iterate();
        while (try iter.next()) |entry| {
            // Check if this is a battery by reading its type file.
            const type_path = try fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/type", .{entry.name});
            const type_file = fs.openFileAbsolute(type_path, .{}) catch continue;
            defer type_file.close();
            var type_buf: [16]u8 = undefined;
            const n_type = type_file.read(&type_buf) catch continue;
            const dev_type = mem.trim(u8, type_buf[0..n_type], " \n\t");
            if (!mem.eql(u8, dev_type, "Battery")) continue;

            const cap_path = try fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/capacity", .{entry.name});
            const capacity_file = fs.openFileAbsolute(cap_path, .{}) catch continue;
            defer capacity_file.close();
            const stat_path = try fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/status", .{entry.name});
            const status_file = fs.openFileAbsolute(stat_path, .{}) catch continue;
            defer status_file.close();

            var cap_buf: [8]u8 = undefined;
            const n_cap = capacity_file.read(&cap_buf) catch continue;
            const capacity = fmt.parseInt(u32, mem.trim(u8, cap_buf[0..n_cap], " \n\t"), 10) catch continue;

            var stat_buf: [16]u8 = undefined;
            const n_stat = status_file.read(&stat_buf) catch continue;
            const status = mem.trim(u8, stat_buf[0..n_stat], " \n\t");

            return fmt.allocPrint(allocator, "{d}% [{s}]", .{ capacity, status });
        }
        return "No Battery";
    }

    return "Unknown";
}

/// Gets system theme, "Dark" or "Light".
fn getTheme() []const u8 {
    if (comptime native_os == .macos) {
        const key = c.CFStringCreateWithCString(null, "AppleInterfaceStyle", c.kCFStringEncodingUTF8);
        defer _ = c.CFRelease(key);
        const value = c.CFPreferencesCopyAppValue(key, c.kCFPreferencesAnyApplication);
        if (value != null) {
            defer _ = c.CFRelease(value);
            return "Dark";
        }
        return "Light";
    }

    if (comptime native_os == .linux) {
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

    return "Unknown";
}

/// Gets memory usage as "used MiB / total MiB" on Linux, or "total MiB" on macOS.
fn getMemory(allocator: mem.Allocator, bytes_per_page: u64) ![]const u8 {
    if (comptime native_os == .linux) {
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
        const percent = if (bytes_total_kb > 0) (bytes_used_kb * 100 / bytes_total_kb) else 0;
        const bytes_swap_used_kb = bytes_swap_total_kb -| bytes_swap_free_kb;

        if (bytes_swap_total_kb > 0) {
            return fmt.allocPrint(allocator, "{d} MiB / {d} MiB ({d}%) [Swap: {d} MiB / {d} MiB]", .{
                bytes_used_kb / 1024,
                bytes_total_kb / 1024,
                percent,
                bytes_swap_used_kb / 1024,
                bytes_swap_total_kb / 1024,
            });
        }
        return fmt.allocPrint(allocator, "{d} MiB / {d} MiB ({d}%)", .{
            bytes_used_kb / 1024,
            bytes_total_kb / 1024,
            percent,
        });
    }

    if (comptime native_os == .macos) {
        var bytes_mem_total: u64 = 0;
        var bytes_mem_size: usize = @sizeOf(u64);
        if (c.sysctlbyname("hw.memsize", &bytes_mem_total, &bytes_mem_size, null, 0) != 0) {
            return "Unknown";
        }

        var vm_stats: c.vm_statistics64_data_t = undefined;
        var vm_stats_count: c.mach_msg_type_number_t = c.HOST_VM_INFO64_COUNT;
        if (c.host_statistics64(c.mach_host_self(), c.HOST_VM_INFO64, @ptrCast(&vm_stats), &vm_stats_count) != 0) {
            return fmt.allocPrint(allocator, "{d} MiB", .{bytes_mem_total / (1024 * 1024)});
        }

        const pages_app = @as(u64, vm_stats.internal_page_count) -| @as(u64, vm_stats.purgeable_count);
        const pages_wired = @as(u64, vm_stats.wire_count);
        const pages_compressed = @as(u64, vm_stats.compressor_page_count);

        const pages_used = pages_app + pages_wired + pages_compressed;
        const bytes_used = pages_used * bytes_per_page;
        const percent = if (bytes_mem_total > 0) (bytes_used * 100 / bytes_mem_total) else 0;

        const MiB = 1024 * 1024;
        return fmt.allocPrint(allocator, "{d} MiB / {d} MiB ({d}%) [App: {d} MiB, Wired: {d} MiB, Compressed: {d} MiB]", .{
            bytes_used / MiB,
            bytes_mem_total / MiB,
            percent,
            (pages_app * bytes_per_page) / MiB,
            (pages_wired * bytes_per_page) / MiB,
            (pages_compressed * bytes_per_page) / MiB,
        });
    }

    return "Unknown";
}

/// Gets the system page size in bytes.
fn fetchPageSize() u64 {
    if (comptime native_os == .macos) {
        var bytes_per_page: u32 = 0;
        var bpp_size: usize = @sizeOf(u32);
        if (c.sysctlbyname("hw.pagesize", &bytes_per_page, &bpp_size, null, 0) == 0) {
            return bytes_per_page;
        }
    }

    if (comptime native_os == .linux) {
        return @intCast(c.getpagesize());
    }

    return 4096;
}

/// Gets the terminal name from environment variables.
fn getTerminal() []const u8 {
    return std.posix.getenv("TERM_PROGRAM") orelse
        std.posix.getenv("TERM") orelse "Unknown";
}

/// Gets installed package count (behind --all flag since it may be slow).
fn getPackages(allocator: mem.Allocator) ![]const u8 {
    var parts: std.ArrayList(u8) = .empty;

    if (comptime native_os == .macos) {
        // Count Homebrew packages
        const brew_paths = [_][]const u8{ "/opt/homebrew/Cellar", "/usr/local/Cellar" };
        for (brew_paths) |brew_path| {
            var dir = fs.openDirAbsolute(brew_path, .{ .iterate = true }) catch continue;
            defer dir.close();
            var count: u32 = 0;
            var iter = dir.iterate();
            while (try iter.next()) |_| count += 1;
            if (count > 0) {
                const entry = try fmt.allocPrint(allocator, "{d} (brew)", .{count});
                try parts.appendSlice(allocator, entry);
            }
            break; // only use the first found path
        }
    }

    if (comptime native_os == .linux) {
        // dpkg
        var dir = fs.openDirAbsolute("/var/lib/dpkg/info", .{ .iterate = true }) catch return "Unknown";
        defer dir.close();
        var count: u32 = 0;
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (mem.endsWith(u8, entry.name, ".list")) count += 1;
        }
        if (count > 0) {
            const entry = try fmt.allocPrint(allocator, "{d} (dpkg)", .{count});
            try parts.appendSlice(allocator, entry);
        }
    }

    return if (parts.items.len > 0) parts.items else "Unknown";
}

/// Gets the local IP address using getifaddrs.
fn getLocalIp(allocator: mem.Allocator) ![]const u8 {
    var ifap: ?*c.struct_ifaddrs = null;
    if (c.getifaddrs(&ifap) != 0) return "Unknown";
    defer c.freeifaddrs(ifap);

    var parts: std.ArrayList(u8) = .empty;
    var ifa = ifap;
    while (ifa) |a| : (ifa = a.ifa_next) {
        const sa = a.ifa_addr orelse continue;
        if (sa.*.sa_family != c.AF_INET) continue;

        const name = mem.sliceTo(a.ifa_name, 0);
        // Skip loopback
        if (mem.eql(u8, name, "lo") or mem.eql(u8, name, "lo0")) continue;

        var addr_buf: [c.INET_ADDRSTRLEN]u8 = undefined;
        const sin: *const c.struct_sockaddr_in = @ptrCast(@alignCast(sa));
        const result = c.inet_ntop(c.AF_INET, &sin.sin_addr, &addr_buf, c.INET_ADDRSTRLEN);
        if (result == null) continue;

        const ip = mem.sliceTo(&addr_buf, 0);
        if (parts.items.len > 0) try parts.appendSlice(allocator, ", ");
        const entry = try fmt.allocPrint(allocator, "{s} ({s})", .{ ip, name });
        try parts.appendSlice(allocator, entry);
    }

    return if (parts.items.len > 0) parts.items else "Unknown";
}

/// Parses a /proc/meminfo line of the form "Key:   12345 kB" and returns the kB value.
pub fn parseKbLine(line: []const u8) u64 {
    const colon_pos = mem.indexOfScalar(u8, line, ':') orelse return 0;
    const rest = mem.trim(u8, line[colon_pos + 1 ..], " \t");
    // Strip " kB" suffix before parsing the integer.
    const kb_suffix_pos = mem.indexOf(u8, rest, " kB") orelse rest.len;
    return fmt.parseInt(u64, rest[0..kb_suffix_pos], 10) catch 0;
}

test "format uptime: seconds only" {
    // Values below 60 s should show only seconds.
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
    // 1 hour + 1 minute + 1 second — seconds are dropped at the hours scale.
    const result = try formatUptime(std.testing.allocator, 3661);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 hour, 1 min", result);
}

test "format uptime: days hours minutes" {
    // 1 day + 1 hour + 1 minute + 1 second.
    const result = try formatUptime(std.testing.allocator, 90061);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1 day, 1 hour, 1 min", result);
}

test "format uptime: plural days" {
    // 2 days + 3 hours + 5 minutes
    const result = try formatUptime(std.testing.allocator, 2 * 86400 + 3 * 3600 + 5 * 60);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("2 days, 3 hours, 5 mins", result);
}

test "parse kb line" {
    // Standard /proc/meminfo format with varying amounts of whitespace.
    try std.testing.expectEqual(@as(u64, 16280284), parseKbLine("MemTotal:       16280284 kB"));
    try std.testing.expectEqual(@as(u64, 8123456), parseKbLine("MemAvailable:    8123456 kB"));
    try std.testing.expectEqual(@as(u64, 0), parseKbLine("InvalidLine"));
}
