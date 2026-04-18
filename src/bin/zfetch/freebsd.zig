//! FreeBSD platform implementation for zfetch.

const std = @import("std");
const common = @import("common.zig");
const mem = std.mem;
const fmt = std.fmt;

const c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h");
});
const c_timeval = extern struct {
    tv_sec: c_long,
    tv_usec: c_long,
};
extern "c" fn time(tloc: ?*i64) i64;

/// Reads a sysctl string value into the provided buffer.
fn sysctlString(
    name: [*:0]const u8,
    buf: []u8,
) ?[]const u8 {
    var size: usize = buf.len;
    if (c.sysctlbyname(name, buf.ptr, &size, null, 0) != 0) {
        return null;
    }
    return mem.trimEnd(u8, buf[0..size], &[_]u8{0});
}

pub const getHostname = common.getHostname;
pub const getKernel = common.getKernel;

pub fn getOs(allocator: mem.Allocator) ![]const u8 {
    // FreeBSD also has /etc/os-release on recent versions.
    return common.getOsFromRelease(allocator, "FreeBSD");
}

pub fn getCpu(allocator: mem.Allocator) ![]const u8 {
    // FreeBSD exposes CPU model via hw.model sysctl.
    var buf: [256]u8 = undefined;
    const model = sysctlString("hw.model", &buf) orelse
        return "Unknown";

    var ncpu: u32 = 0;
    var ncpu_size: usize = @sizeOf(u32);
    if (c.sysctlbyname(
        "hw.ncpu",
        &ncpu,
        &ncpu_size,
        null,
        0,
    ) != 0) {
        return allocator.dupe(u8, model);
    }

    return fmt.allocPrint(
        allocator,
        "{s} ({d} cores)",
        .{ model, ncpu },
    );
}

pub fn getHost(allocator: mem.Allocator) ![]const u8 {
    // Try DMI first (works on x86 FreeBSD).
    return common.getHostFromDmi(allocator, "FreeBSD");
}

pub fn getDiskMounts() []const [:0]const u8 {
    return &[_][:0]const u8{ "/", "/home" };
}

pub fn getResolution(allocator: mem.Allocator) ![]const u8 {
    // FreeBSD uses DRM sysfs like Linux.
    return common.getResolutionFromDrm(allocator);
}

pub fn getBattery(allocator: mem.Allocator) ![]const u8 {
    // FreeBSD ACPI battery: read from sysctl.
    var life: u32 = 0;
    var life_size: usize = @sizeOf(u32);
    if (c.sysctlbyname(
        "hw.acpi.battery.life",
        &life,
        &life_size,
        null,
        0,
    ) != 0) {
        return "No Battery";
    }

    var state: u32 = 0;
    var state_size: usize = @sizeOf(u32);
    _ = c.sysctlbyname(
        "hw.acpi.battery.state",
        &state,
        &state_size,
        null,
        0,
    );

    // state: 0 = on AC, 1 = discharging, 2 = charging.
    const status: []const u8 = switch (state) {
        2 => "Charging",
        1 => "Discharging",
        else => "AC Power",
    };

    return fmt.allocPrint(
        allocator,
        "{d}% [{s}]",
        .{ life, status },
    );
}

pub fn getTheme() []const u8 {
    // FreeBSD desktop users typically use GTK.
    return common.getThemeFromGtk();
}

pub fn getMemory(
    allocator: mem.Allocator,
    bytes_per_page: u64,
) ![]const u8 {
    // hw.physmem for total, vm.stats.vm.v_free_count for free pages.
    var physmem: u64 = 0;
    var physmem_size: usize = @sizeOf(u64);
    if (c.sysctlbyname(
        "hw.physmem",
        &physmem,
        &physmem_size,
        null,
        0,
    ) != 0) {
        return "Unknown";
    }

    var free_count: u32 = 0;
    var fc_size: usize = @sizeOf(u32);
    if (c.sysctlbyname(
        "vm.stats.vm.v_free_count",
        &free_count,
        &fc_size,
        null,
        0,
    ) != 0) {
        return common.fmtSize(allocator, physmem);
    }

    var inactive_count: u32 = 0;
    var ic_size: usize = @sizeOf(u32);
    _ = c.sysctlbyname(
        "vm.stats.vm.v_inactive_count",
        &inactive_count,
        &ic_size,
        null,
        0,
    );

    const bytes_free = (@as(u64, free_count) + @as(u64, inactive_count)) * bytes_per_page;
    const bytes_used = physmem -| bytes_free;
    const percent = if (physmem > 0)
        (bytes_used * 100 / physmem)
    else
        0;

    const used = try common.fmtSize(allocator, bytes_used);
    const total = try common.fmtSize(allocator, physmem);
    return fmt.allocPrint(
        allocator,
        "{s} / {s} ({d}%)",
        .{ used, total, percent },
    );
}

pub fn getUptime(allocator: mem.Allocator) ![]const u8 {
    // FreeBSD has kern.boottime sysctl like macOS.
    var boot_time: c_timeval = undefined;
    var boot_time_size: usize = @sizeOf(c_timeval);
    if (c.sysctlbyname(
        "kern.boottime",
        &boot_time,
        &boot_time_size,
        null,
        0,
    ) != 0) {
        return "Unknown";
    }
    const now_s: i64 = time(null);
    const boot_s: i64 = @intCast(boot_time.tv_sec);
    if (now_s < boot_s) return "Unknown";
    const uptime_s: u64 = @intCast(now_s - boot_s);
    return common.formatUptime(allocator, uptime_s);
}

pub fn getPackages(allocator: mem.Allocator) ![]const u8 {
    return common.getPackagesPkg(allocator);
}
