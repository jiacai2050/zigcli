//! macOS platform implementation for zfetch.

const std = @import("std");
const common = @import("common.zig");
const mem = std.mem;
const fmt = std.fmt;

const c = @cImport({
    @cInclude("sys/time.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/mount.h");
    @cInclude("mach/mach_host.h");
    @cInclude("mach/mach_init.h");
    @cInclude("mach/vm_statistics.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("IOKit/ps/IOPowerSources.h");
    @cInclude("IOKit/ps/IOPSKeys.h");
});

pub const getHostname = common.getHostname;
pub const getKernel = common.getKernel;

pub fn getOs(allocator: mem.Allocator) ![]const u8 {
    var version_buf: [64]u8 = undefined;
    var version_size: usize = version_buf.len;
    if (c.sysctlbyname(
        "kern.osproductversion",
        &version_buf,
        &version_size,
        null,
        0,
    ) != 0) {
        return "macOS";
    }
    const version = mem.trimRight(
        u8,
        version_buf[0..version_size],
        &[_]u8{0},
    );
    return fmt.allocPrint(allocator, "macOS {s}", .{version});
}

pub fn getCpu(allocator: mem.Allocator) ![]const u8 {
    var cpu_buf: [256]u8 = undefined;
    var cpu_size: usize = cpu_buf.len;
    if (c.sysctlbyname(
        "machdep.cpu.brand_string",
        &cpu_buf,
        &cpu_size,
        null,
        0,
    ) != 0) {
        return "Unknown";
    }
    const brand = mem.trimRight(
        u8,
        cpu_buf[0..cpu_size],
        &[_]u8{0},
    );

    var cpu_physical_count: u32 = 0;
    var pc_size: usize = @sizeOf(u32);
    if (c.sysctlbyname(
        "hw.physicalcpu",
        &cpu_physical_count,
        &pc_size,
        null,
        0,
    ) != 0) {
        return allocator.dupe(u8, brand);
    }

    var p_cores_count: u32 = 0;
    var p_size: usize = @sizeOf(u32);
    _ = c.sysctlbyname(
        "hw.perflevel0.physicalcpu",
        &p_cores_count,
        &p_size,
        null,
        0,
    );

    var e_cores_count: u32 = 0;
    var e_size: usize = @sizeOf(u32);
    _ = c.sysctlbyname(
        "hw.perflevel1.physicalcpu",
        &e_cores_count,
        &e_size,
        null,
        0,
    );

    if (p_cores_count > 0 or e_cores_count > 0) {
        return fmt.allocPrint(
            allocator,
            "{s} ({d} cores: {d}P + {d}E)",
            .{ brand, cpu_physical_count, p_cores_count, e_cores_count },
        );
    }

    if (cpu_physical_count > 0) {
        return fmt.allocPrint(
            allocator,
            "{s} ({d} cores)",
            .{ brand, cpu_physical_count },
        );
    }

    return allocator.dupe(u8, brand);
}

pub fn getHost(allocator: mem.Allocator) ![]const u8 {
    var model_buf: [128]u8 = undefined;
    var model_size: usize = model_buf.len;
    if (c.sysctlbyname(
        "hw.model",
        &model_buf,
        &model_size,
        null,
        0,
    ) != 0) {
        return "Mac";
    }
    const model = mem.trimRight(
        u8,
        model_buf[0..model_size],
        &[_]u8{0},
    );
    return allocator.dupe(u8, model);
}

pub fn getDiskMounts() []const []const u8 {
    return &[_][]const u8{"/"};
}

pub fn getResolution(allocator: mem.Allocator) ![]const u8 {
    var display_ids: [8]c.CGDirectDisplayID = undefined;
    var display_count: u32 = 0;
    if (c.CGGetActiveDisplayList(
        display_ids.len,
        &display_ids,
        &display_count,
    ) != 0 or display_count == 0) {
        return "Unknown";
    }

    var parts: std.ArrayList(u8) = .empty;
    for (display_ids[0..display_count]) |did| {
        const mode = c.CGDisplayCopyDisplayMode(did);
        if (mode == null) continue;
        defer c.CGDisplayModeRelease(mode);

        const w: u32 = @intCast(c.CGDisplayModeGetWidth(mode));
        const h: u32 = @intCast(c.CGDisplayModeGetHeight(mode));
        const hz = c.CGDisplayModeGetRefreshRate(mode);

        if (parts.items.len > 0) {
            try parts.appendSlice(allocator, ", ");
        }
        if (hz > 0) {
            const entry = try fmt.allocPrint(
                allocator,
                "{d}x{d} @ {d}Hz",
                .{ w, h, @as(u32, @intFromFloat(hz)) },
            );
            try parts.appendSlice(allocator, entry);
        } else {
            const entry = try fmt.allocPrint(
                allocator,
                "{d}x{d}",
                .{ w, h },
            );
            try parts.appendSlice(allocator, entry);
        }
    }
    return if (parts.items.len > 0) parts.items else "Unknown";
}

pub fn getBattery(allocator: mem.Allocator) ![]const u8 {
    const info = c.IOPSCopyPowerSourcesInfo();
    defer _ = c.CFRelease(info);
    const list = c.IOPSCopyPowerSourcesList(info);
    defer _ = c.CFRelease(list);

    const count = c.CFArrayGetCount(list);
    if (count == 0) return "No Battery";

    const source = c.CFArrayGetValueAtIndex(list, 0);
    const desc = c.IOPSGetPowerSourceDescription(info, source);

    var capacity: i32 = 0;
    const key_cap = c.CFStringCreateWithCString(
        null,
        c.kIOPSCurrentCapacityKey,
        c.kCFStringEncodingUTF8,
    );
    defer _ = c.CFRelease(key_cap);
    const val_cap = c.CFDictionaryGetValue(desc, key_cap);
    if (val_cap != null) {
        _ = c.CFNumberGetValue(
            @ptrCast(val_cap),
            c.kCFNumberSInt32Type,
            &capacity,
        );
    }

    var is_charging = false;
    const key_chg = c.CFStringCreateWithCString(
        null,
        c.kIOPSIsChargingKey,
        c.kCFStringEncodingUTF8,
    );
    defer _ = c.CFRelease(key_chg);
    const val_chg = c.CFDictionaryGetValue(desc, key_chg);
    if (val_chg != null) {
        is_charging = c.CFBooleanGetValue(
            @ptrCast(val_chg),
        ) != 0;
    }

    return fmt.allocPrint(allocator, "{d}% [{s}]", .{
        capacity,
        if (is_charging) "Charging" else "Discharging",
    });
}

pub fn getTheme() []const u8 {
    const key = c.CFStringCreateWithCString(
        null,
        "AppleInterfaceStyle",
        c.kCFStringEncodingUTF8,
    );
    defer _ = c.CFRelease(key);
    const value = c.CFPreferencesCopyAppValue(
        key,
        c.kCFPreferencesAnyApplication,
    );
    if (value != null) {
        defer _ = c.CFRelease(value);
        return "Dark";
    }
    return "Light";
}

pub fn getMemory(
    allocator: mem.Allocator,
    bytes_per_page: u64,
) ![]const u8 {
    var bytes_total: u64 = 0;
    var size: usize = @sizeOf(u64);
    if (c.sysctlbyname(
        "hw.memsize",
        &bytes_total,
        &size,
        null,
        0,
    ) != 0) {
        return "Unknown";
    }

    var vm: c.vm_statistics64_data_t = undefined;
    var vm_count: c.mach_msg_type_number_t =
        c.HOST_VM_INFO64_COUNT;
    if (c.host_statistics64(
        c.mach_host_self(),
        c.HOST_VM_INFO64,
        @ptrCast(&vm),
        &vm_count,
    ) != 0) {
        return fmt.allocPrint(
            allocator,
            "{d} MiB",
            .{bytes_total / (1024 * 1024)},
        );
    }

    const pages_app = @as(u64, vm.internal_page_count) -|
        @as(u64, vm.purgeable_count);
    const pages_wired = @as(u64, vm.wire_count);
    const pages_compressed = @as(
        u64,
        vm.compressor_page_count,
    );

    const pages_used = pages_app + pages_wired + pages_compressed;
    const bytes_used = pages_used * bytes_per_page;
    const percent = if (bytes_total > 0)
        (bytes_used * 100 / bytes_total)
    else
        0;

    const MiB = 1024 * 1024;
    return fmt.allocPrint(
        allocator,
        "{d} MiB / {d} MiB ({d}%)" ++
            " [App: {d} MiB, Wired: {d} MiB, Compressed: {d} MiB]",
        .{
            bytes_used / MiB,
            bytes_total / MiB,
            percent,
            (pages_app * bytes_per_page) / MiB,
            (pages_wired * bytes_per_page) / MiB,
            (pages_compressed * bytes_per_page) / MiB,
        },
    );
}

pub fn fetchPageSize() u64 {
    var bytes_per_page: u32 = 0;
    var bpp_size: usize = @sizeOf(u32);
    if (c.sysctlbyname(
        "hw.pagesize",
        &bytes_per_page,
        &bpp_size,
        null,
        0,
    ) == 0) {
        return bytes_per_page;
    }
    return 4096;
}

pub fn getUptime(allocator: mem.Allocator) ![]const u8 {
    var boot_time: c.struct_timeval = undefined;
    var boot_time_size: usize = @sizeOf(c.struct_timeval);
    if (c.sysctlbyname(
        "kern.boottime",
        &boot_time,
        &boot_time_size,
        null,
        0,
    ) != 0) {
        return "Unknown";
    }
    const now_s: i64 = std.time.timestamp();
    const boot_s: i64 = @intCast(boot_time.tv_sec);
    if (now_s < boot_s) return "Unknown";
    const uptime_s: u64 = @intCast(now_s - boot_s);
    return common.formatUptime(allocator, uptime_s);
}

pub fn getPackages(allocator: mem.Allocator) ![]const u8 {
    const brew_paths = [_][]const u8{
        "/opt/homebrew/Cellar",
        "/usr/local/Cellar",
    };
    for (brew_paths) |brew_path| {
        var dir = std.fs.openDirAbsolute(
            brew_path,
            .{ .iterate = true },
        ) catch continue;
        defer dir.close();
        var count: u32 = 0;
        var iter = dir.iterate();
        while (try iter.next()) |_| count += 1;
        if (count > 0) {
            return fmt.allocPrint(
                allocator,
                "{d} (brew)",
                .{count},
            );
        }
        break; // Only use the first found path.
    }
    return "Unknown";
}
