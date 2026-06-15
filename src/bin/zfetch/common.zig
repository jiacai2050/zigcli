//! Shared utilities for zfetch, platform-independent.

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Io = std.Io;
const Environ = std.process.Environ;

const builtin = @import("builtin");

const max_read_bytes = 1024 * 1024;

const c = @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    if (builtin.os.tag != .linux) @cInclude("sys/statvfs.h");
    @cInclude("sys/utsname.h");
    @cInclude("netinet/in.h");
    @cInclude("ifaddrs.h");
    @cInclude("arpa/inet.h");
});

fn readAbsoluteAlloc(io: Io, allocator: mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return error.ReadFailed;
    defer file.close(io);
    var file_reader = file.reader(io, &.{});

    // This doesn't work because it can't read /proc files that report 0 size, even if they have data to read.
    // https://codeberg.org/ziglang/zig/issues/31946
    // return file_reader.interface.readAlloc(allocator, max_bytes);

    var result = try std.ArrayList(u8).initCapacity(allocator, 4096);
    errdefer result.deinit(allocator);

    while (result.items.len < max_bytes) {
        const remaining = max_bytes - result.items.len;
        const chunk_size = @min(remaining, 4096);
        const buf = try result.addManyAsSlice(allocator, chunk_size);
        const n = file_reader.interface.readSliceShort(buf) catch {
            result.shrinkRetainingCapacity(result.items.len - chunk_size);
            break;
        };
        result.shrinkRetainingCapacity(result.items.len - chunk_size + n);
        if (n < chunk_size) break;
    }
    return try result.toOwnedSlice(allocator);
}

fn readAbsoluteIntoBuf(io: Io, path: []const u8, buf: []u8) ?usize {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var file_reader = file.reader(io, &[0]u8{}); // empty buffer for reader interface
    return file_reader.interface.readSliceShort(buf) catch null;
}

/// Manual statvfs for Linux — the musl header has bitfields
/// that Zig's @cImport cannot translate. Other OSes use @cImport.
const Statvfs = if (builtin.os.tag == .linux)
    extern struct {
        f_bsize: c_ulong,
        f_frsize: c_ulong,
        f_blocks: c_ulong,
        f_bfree: c_ulong,
        f_bavail: c_ulong,
        f_files: c_ulong,
        f_ffree: c_ulong,
        f_favail: c_ulong,
        f_fsid: u64,
        f_flag: c_ulong,
        f_namemax: c_ulong,
        __f_spare: [6]c_int = .{0} ** 6,
    }
else
    c.struct_statvfs;

extern "c" fn statvfs(
    path: [*:0]const u8,
    buf: *Statvfs,
) c_int;

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

    if (days > 0) {
        return fmt.allocPrint(allocator, "{d} {s}, {d} {s}, {d} {s}", .{
            days,    plural(days, "day"),
            hours,   plural(hours, "hour"),
            minutes, plural(minutes, "min"),
        });
    }

    if (hours > 0) {
        return fmt.allocPrint(allocator, "{d} {s}, {d} {s}", .{
            hours,   plural(hours, "hour"),
            minutes, plural(minutes, "min"),
        });
    }

    if (minutes > 0) {
        return fmt.allocPrint(allocator, "{d} {s}, {d} {s}", .{
            minutes, plural(minutes, "min"),
            seconds, plural(seconds, "sec"),
        });
    }

    return fmt.allocPrint(allocator, "{d} {s}", .{
        seconds, plural(seconds, "sec"),
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

/// Formats bytes as "X MiB" or "X.Y GiB" (threshold: 1024 MiB).
pub fn fmtSize(allocator: mem.Allocator, bytes: u64) ![]const u8 {
    const mib = bytes / (1024 * 1024);
    if (mib >= 1024) {
        return fmt.allocPrint(
            allocator,
            "{d}.{d} GiB",
            .{ mib / 1024, (mib % 1024) * 10 / 1024 },
        );
    }
    return fmt.allocPrint(allocator, "{d} MiB", .{mib});
}

/// Gets disk usage for the given mount points.
pub fn getDiskMounts(
    allocator: mem.Allocator,
    mounts: []const [:0]const u8,
) ![]const u8 {
    var parts: std.ArrayList(u8) = .empty;
    const GiB = 1024 * 1024 * 1024;
    var seen_dev: [8]u64 = .{0} ** 8;
    var seen_count: usize = 0;

    for (mounts) |mount| {
        var vfs: Statvfs = undefined;
        if (statvfs(mount.ptr, &vfs) != 0) continue;

        // Deduplicate by filesystem ID.
        const fsid: u64 = vfs.f_fsid;
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

/// Gets shell name with version by running `<shell> --version` via PATH lookup.
pub fn getShellVersion(
    io: Io,
    allocator: mem.Allocator,
    shell: []const u8,
) ![]const u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ shell, "--version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch return allocator.dupe(u8, shell);
    defer allocator.free(result.stderr);

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
            const version_str = first_line[i..end];
            const out = try fmt.allocPrint(
                allocator,
                "{s} {s}",
                .{ shell, version_str },
            );
            allocator.free(result.stdout);
            return out;
        }
    }

    allocator.free(result.stdout);
    return allocator.dupe(u8, shell);
}

/// Gets the terminal name from environment variables.
pub fn getTerminal(env: *const Environ.Map) []const u8 {
    return env.get("TERM_PROGRAM") orelse
        env.get("TERM") orelse "Unknown";
}

/// Parses a /proc/meminfo line "Key: 12345 kB" and returns the kB value.
pub fn parseKbLine(line: []const u8) u64 {
    const colon_pos = mem.indexOfScalar(u8, line, ':') orelse return 0;
    const rest = mem.trim(u8, line[colon_pos + 1 ..], " \t");
    const kb_suffix_pos = mem.indexOf(u8, rest, " kB") orelse rest.len;
    return fmt.parseInt(u64, rest[0..kb_suffix_pos], 10) catch 0;
}

/// Reads PRETTY_NAME from /etc/os-release.
pub fn getOsFromRelease(io: Io, allocator: mem.Allocator, fallback: []const u8) ![]const u8 {
    const content = readAbsoluteAlloc(io, allocator, "/etc/os-release", max_read_bytes) catch return fallback;
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
pub fn getUptimeFromProc(io: Io, allocator: mem.Allocator) ![]const u8 {
    var buf: [64]u8 = undefined;
    const byte_count = readAbsoluteIntoBuf(io, "/proc/uptime", &buf) orelse return "Unknown";
    const content = buf[0..byte_count];

    const space_pos = mem.indexOfScalar(u8, content, ' ') orelse content.len;
    const dot_pos = mem.indexOfScalar(u8, content[0..space_pos], '.') orelse space_pos;
    const uptime_s = fmt.parseInt(u64, content[0..dot_pos], 10) catch return "Unknown";
    return formatUptime(allocator, uptime_s);
}

/// Reads battery from /sys/class/power_supply (Linux, FreeBSD).
pub fn getBatteryFromSys(io: Io, allocator: mem.Allocator) ![]const u8 {
    var ps_dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/power_supply", .{ .iterate = true }) catch
        return "No Battery";
    defer ps_dir.close(io);
    var iter = ps_dir.iterate();
    while (try iter.next(io)) |entry| {
        var path_buf: [256]u8 = undefined;

        const type_path = fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/type", .{entry.name}) catch continue;
        var type_buf: [16]u8 = undefined;
        const n_type = readAbsoluteIntoBuf(io, type_path, &type_buf) orelse continue;
        const dev_type = mem.trim(u8, type_buf[0..n_type], " \n\t");
        if (!mem.eql(u8, dev_type, "Battery")) continue;

        const cap_path = fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/capacity", .{entry.name}) catch continue;
        var cap_buf: [8]u8 = undefined;
        const n_cap = readAbsoluteIntoBuf(io, cap_path, &cap_buf) orelse continue;
        const capacity = fmt.parseInt(
            u32,
            mem.trim(u8, cap_buf[0..n_cap], " \n\t"),
            10,
        ) catch continue;

        const stat_path = fmt.bufPrint(&path_buf, "/sys/class/power_supply/{s}/status", .{entry.name}) catch continue;
        var stat_buf: [16]u8 = undefined;
        const n_stat = readAbsoluteIntoBuf(io, stat_path, &stat_buf) orelse continue;
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
pub fn getThemeFromGtk(io: Io, env: *const Environ.Map) []const u8 {
    const home = env.get("HOME") orelse return "Unknown";
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
        var read_buf: [32768]u8 = undefined;
        const n = readAbsoluteIntoBuf(io, path, &read_buf) orelse continue;
        for (needles) |needle| {
            if (mem.indexOf(u8, read_buf[0..n], needle) != null) return "Dark";
        }
    }

    return "Light";
}

/// Reads memory info from /proc/meminfo (Linux, FreeBSD with procfs).
pub fn getMemoryFromProc(io: Io, allocator: mem.Allocator) ![]const u8 {
    const content = readAbsoluteAlloc(io, allocator, "/proc/meminfo", max_read_bytes) catch return "Unknown";
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

    const used = try fmtSize(allocator, bytes_used_kb * 1024);
    const total = try fmtSize(allocator, bytes_total_kb * 1024);

    if (bytes_swap_total_kb > 0) {
        const sw_used = try fmtSize(allocator, bytes_swap_used_kb * 1024);
        const sw_total = try fmtSize(allocator, bytes_swap_total_kb * 1024);
        return fmt.allocPrint(
            allocator,
            "{s} / {s} ({d}%) [Swap: {s} / {s}]",
            .{ used, total, percent, sw_used, sw_total },
        );
    }
    return fmt.allocPrint(
        allocator,
        "{s} / {s} ({d}%)",
        .{ used, total, percent },
    );
}

fn isDrmCardName(name: []const u8) bool {
    if (!mem.startsWith(u8, name, "card")) return false;
    if (name.len == "card".len) return false;
    for (name["card".len..]) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

fn trimHexPrefix(value: []const u8) []const u8 {
    const trimmed = mem.trim(u8, value, " \n\r\t");
    if (mem.startsWith(u8, trimmed, "0x")) return trimmed[2..];
    if (mem.startsWith(u8, trimmed, "0X")) return trimmed[2..];
    return trimmed;
}

fn pciVendorName(vendor_id: []const u8) []const u8 {
    if (mem.eql(u8, vendor_id, "1002")) return "AMD";
    if (mem.eql(u8, vendor_id, "1022")) return "AMD";
    if (mem.eql(u8, vendor_id, "10de")) return "NVIDIA";
    if (mem.eql(u8, vendor_id, "8086")) return "Intel";
    if (mem.eql(u8, vendor_id, "1414")) return "Microsoft";
    if (mem.eql(u8, vendor_id, "1af4")) return "Virtio";
    if (mem.eql(u8, vendor_id, "1234")) return "QEMU";
    return "Unknown";
}

fn findPciDeviceName(
    io: Io,
    allocator: mem.Allocator,
    vendor_id: []const u8,
    device_id: []const u8,
) ?[]const u8 {
    const pci_id_paths = [_][]const u8{
        "/usr/share/hwdata/pci.ids",
        "/usr/share/misc/pci.ids",
        "/usr/share/pci.ids",
    };

    for (pci_id_paths) |path| {
        const content = readAbsoluteAlloc(io, allocator, path, 8 * 1024 * 1024) catch continue;
        var in_vendor = false;
        var iter = mem.splitScalar(u8, content, '\n');
        while (iter.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;

            if (line[0] != '\t') {
                if (line.len >= 4 and mem.eql(u8, line[0..4], vendor_id)) {
                    in_vendor = true;
                } else if (in_vendor) {
                    break;
                }
                continue;
            }

            if (!in_vendor) continue;
            if (line.len < 6 or line[1] == '\t') continue;
            if (!mem.eql(u8, line[1..5], device_id)) continue;
            return mem.trim(u8, line[5..], " \t");
        }
    }

    return null;
}

/// Reads GPU info from DRM sysfs.
pub fn getGpuFromDrm(io: Io, allocator: mem.Allocator) ![]const u8 {
    var drm_dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/drm", .{ .iterate = true }) catch
        return "Unknown";
    defer drm_dir.close(io);

    var parts: std.ArrayList(u8) = .empty;
    var seen: [16]struct { vendor: [4]u8, device: [4]u8 } = undefined;
    var seen_count: usize = 0;

    var iter = drm_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (!isDrmCardName(entry.name)) continue;

        var path_buf: [256]u8 = undefined;
        const vendor_path = fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/device/vendor", .{entry.name}) catch continue;
        var vendor_buf: [16]u8 = undefined;
        const vendor_n = readAbsoluteIntoBuf(io, vendor_path, &vendor_buf) orelse continue;
        const vendor_id = trimHexPrefix(vendor_buf[0..vendor_n]);
        if (vendor_id.len != 4) continue;

        const device_path = fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/device/device", .{entry.name}) catch continue;
        var device_buf: [16]u8 = undefined;
        const device_n = readAbsoluteIntoBuf(io, device_path, &device_buf) orelse continue;
        const device_id = trimHexPrefix(device_buf[0..device_n]);
        if (device_id.len != 4) continue;

        var duplicate = false;
        for (seen[0..seen_count]) |item| {
            if (mem.eql(u8, &item.vendor, vendor_id) and mem.eql(u8, &item.device, device_id)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        if (seen_count < seen.len) {
            @memcpy(&seen[seen_count].vendor, vendor_id);
            @memcpy(&seen[seen_count].device, device_id);
            seen_count += 1;
        }

        const vendor = pciVendorName(vendor_id);
        const device_name = findPciDeviceName(io, allocator, vendor_id, device_id);
        if (parts.items.len > 0) {
            try parts.appendSlice(allocator, ", ");
        }
        if (device_name) |name| {
            const entry_text = try fmt.allocPrint(allocator, "{s} {s}", .{ vendor, name });
            try parts.appendSlice(allocator, entry_text);
        } else if (!mem.eql(u8, vendor, "Unknown")) {
            const entry_text = try fmt.allocPrint(allocator, "{s} GPU ({s}:{s})", .{ vendor, vendor_id, device_id });
            try parts.appendSlice(allocator, entry_text);
        } else {
            const entry_text = try fmt.allocPrint(allocator, "GPU ({s}:{s})", .{ vendor_id, device_id });
            try parts.appendSlice(allocator, entry_text);
        }
    }

    return if (parts.items.len > 0) parts.items else "Unknown";
}

/// Reads CPU info from /proc/cpuinfo.
pub fn getCpuFromProc(io: Io, allocator: mem.Allocator) ![]const u8 {
    const content = readAbsoluteAlloc(io, allocator, "/proc/cpuinfo", max_read_bytes) catch return "Unknown";
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
pub fn getHostFromDmi(io: Io, allocator: mem.Allocator, fallback: []const u8) ![]const u8 {
    const vendor = readAbsoluteAlloc(io, allocator, "/sys/class/dmi/id/sys_vendor", max_read_bytes) catch return fallback;
    const product = readAbsoluteAlloc(io, allocator, "/sys/class/dmi/id/product_name", max_read_bytes) catch return fallback;

    return fmt.allocPrint(allocator, "{s} {s}", .{
        mem.trim(u8, vendor, " \n\t"),
        mem.trim(u8, product, " \n\t"),
    });
}

/// Reads display resolution from DRM sysfs.
pub fn getResolutionFromDrm(io: Io, allocator: mem.Allocator) ![]const u8 {
    var drm_dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/drm", .{ .iterate = true }) catch
        return "Unknown";
    defer drm_dir.close(io);
    var parts: std.ArrayList(u8) = .empty;
    var iter = drm_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (!mem.startsWith(u8, entry.name, "card")) continue;
        if (mem.indexOfScalar(u8, entry.name[4..], '-') == null) continue;

        var path_buf: [256]u8 = undefined;
        const modes_path = fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/modes", .{entry.name}) catch continue;
        var buf: [64]u8 = undefined;
        const n = readAbsoluteIntoBuf(io, modes_path, &buf) orelse continue;
        if (n == 0) continue;
        const first_line = mem.sliceTo(buf[0..n], '\n');
        const mode_str = mem.trim(u8, first_line, " \n\r\t");
        if (mode_str.len == 0) continue;

        if (parts.items.len > 0) {
            try parts.appendSlice(allocator, ", ");
        }
        try parts.appendSlice(allocator, mode_str);

        // Try to get refresh rate from EDID
        const refresh_hz = getRefreshFromEdid(io, &path_buf, entry.name);
        if (refresh_hz > 0) {
            const hz_str = fmt.allocPrint(allocator, " @ {d}Hz", .{refresh_hz}) catch continue;
            try parts.appendSlice(allocator, hz_str);
        }

        // Optional: add (built-in) indicator for internal displays
        if (mem.indexOf(u8, entry.name, "eDP") != null or mem.indexOf(u8, entry.name, "LVDS") != null) {
            try parts.appendSlice(allocator, " (built-in)");
        }
    }
    return if (parts.items.len > 0) parts.items else "Unknown";
}

/// Parse refresh rate from EDID. Checks Monitor Range Limits descriptor
/// for max vertical rate first (preferred for VRR/high-refresh panels),
/// then falls back to computing from the first Detailed Timing Descriptor.
fn getRefreshFromEdid(io: Io, path_buf: *[256]u8, connector_name: []const u8) u32 {
    const edid_path = fmt.bufPrint(path_buf, "/sys/class/drm/{s}/edid", .{connector_name}) catch return 0;
    var edid_buf: [128]u8 = undefined;
    const edid_n = readAbsoluteIntoBuf(io, edid_path, &edid_buf) orelse return 0;
    if (edid_n < 128) return 0;

    // Check descriptor blocks at offsets 54, 72, 90, 108 for Monitor Range Limits (tag 0xFD).
    // Its max vertical rate (byte 6 within descriptor) gives the panel's native max refresh.
    for ([_]usize{ 54, 72, 90, 108 }) |off| {
        if (edid_buf[off] == 0 and edid_buf[off + 1] == 0 and edid_buf[off + 3] == 0xFD) {
            const max_v = edid_buf[off + 6];
            if (max_v > 0) return max_v;
        }
    }

    // Fall back to first DTD refresh rate calculation.
    const dtd = edid_buf[54..72];
    const pixel_clock: u32 = @as(u32, dtd[0]) | (@as(u32, dtd[1]) << 8);
    if (pixel_clock == 0) return 0;
    const h_active: u32 = @as(u32, dtd[2]) | (@as(u32, dtd[4] >> 4) << 8);
    const h_blank: u32 = @as(u32, dtd[3]) | (@as(u32, dtd[4] & 0x0f) << 8);
    const v_active: u32 = @as(u32, dtd[5]) | (@as(u32, dtd[7] >> 4) << 8);
    const v_blank: u32 = @as(u32, dtd[6]) | (@as(u32, dtd[7] & 0x0f) << 8);
    const h_total = h_active + h_blank;
    const v_total = v_active + v_blank;
    if (h_total == 0 or v_total == 0) return 0;
    return (pixel_clock * 10000 + h_total * v_total / 2) / (h_total * v_total);
}

/// Counts dpkg packages from /var/lib/dpkg/info.
pub fn getPackagesDpkg(io: Io, allocator: mem.Allocator) ![]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, "/var/lib/dpkg/info", .{ .iterate = true }) catch
        return "Unknown";
    defer dir.close(io);
    var count: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (mem.endsWith(u8, entry.name, ".list")) count += 1;
    }
    if (count > 0) {
        return fmt.allocPrint(allocator, "{d} (dpkg)", .{count});
    }
    return "Unknown";
}

/// Counts pkg packages from /var/db/pkg (FreeBSD).
pub fn getPackagesPkg(io: Io, allocator: mem.Allocator) ![]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, "/var/db/pkg", .{ .iterate = true }) catch
        return "Unknown";
    defer dir.close(io);
    var count: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
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
