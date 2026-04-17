//! macOS platform implementation for zfetch.

const std = @import("std");
const common = @import("common.zig");
const mem = std.mem;
const fmt = std.fmt;

// Manual extern declarations for the few symbols we use. Zig 0.16's arocc
// C translator cannot handle Apple's CoreGraphics/CoreFoundation block-typedef
// headers, so @cImport fails there. We instead declare what we need directly.
const c = struct {
    // libc time
    pub extern "c" fn time(tloc: ?*i64) i64;

    // sysctl
    pub extern "c" fn sysctlbyname(
        name: [*:0]const u8,
        oldp: ?*anyopaque,
        oldlenp: ?*usize,
        newp: ?*const anyopaque,
        newlen: usize,
    ) c_int;

    // <sys/time.h>
    pub const struct_timeval = extern struct {
        tv_sec: c_long,
        tv_usec: c_int,
    };

    // <mach/...>
    pub const mach_port_t = c_uint;
    pub const host_t = mach_port_t;
    pub const mach_msg_type_number_t = c_uint;
    pub const integer_t = c_int;
    pub const natural_t = c_uint;
    pub const host_flavor_t = integer_t;
    pub const kern_return_t = c_int;

    pub const vm_statistics64_data_t = extern struct {
        free_count: natural_t,
        active_count: natural_t,
        inactive_count: natural_t,
        wire_count: natural_t,
        zero_fill_count: u64,
        reactivations: u64,
        pageins: u64,
        pageouts: u64,
        faults: u64,
        cow_faults: u64,
        lookups: u64,
        hits: u64,
        purges: u64,
        purgeable_count: natural_t,
        speculative_count: natural_t,
        decompressions: u64,
        compressions: u64,
        swapins: u64,
        swapouts: u64,
        compressor_page_count: natural_t,
        throttled_count: natural_t,
        external_page_count: natural_t,
        internal_page_count: natural_t,
        total_uncompressed_pages_in_compressor: u64,
    };

    pub const HOST_VM_INFO64: host_flavor_t = 4;
    pub const HOST_VM_INFO64_COUNT: mach_msg_type_number_t =
        @sizeOf(vm_statistics64_data_t) / @sizeOf(integer_t);

    pub extern "c" fn mach_host_self() host_t;
    pub extern "c" fn host_statistics64(
        host_priv: host_t,
        flavor: host_flavor_t,
        host_info_out: *anyopaque,
        host_info_outCnt: *mach_msg_type_number_t,
    ) kern_return_t;

    // CoreFoundation
    pub const CFTypeRef = ?*anyopaque;
    pub const CFStringRef = ?*anyopaque;
    pub const CFArrayRef = ?*anyopaque;
    pub const CFDictionaryRef = ?*anyopaque;
    pub const CFNumberRef = ?*anyopaque;
    pub const CFBooleanRef = ?*anyopaque;
    pub const CFAllocatorRef = ?*anyopaque;
    pub const CFIndex = c_long;
    pub const CFStringEncoding = u32;
    pub const CFNumberType = c_long;
    pub const Boolean = u8;

    pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;
    pub const kCFNumberSInt32Type: CFNumberType = 3;

    pub extern "c" fn CFRelease(cf: CFTypeRef) void;
    pub extern "c" fn CFArrayGetCount(theArray: CFArrayRef) CFIndex;
    pub extern "c" fn CFArrayGetValueAtIndex(theArray: CFArrayRef, idx: CFIndex) ?*const anyopaque;
    pub extern "c" fn CFStringCreateWithCString(
        alloc: CFAllocatorRef,
        cStr: [*:0]const u8,
        encoding: CFStringEncoding,
    ) CFStringRef;
    pub extern "c" fn CFDictionaryGetValue(theDict: CFDictionaryRef, key: ?*const anyopaque) ?*const anyopaque;
    pub extern "c" fn CFNumberGetValue(number: CFNumberRef, theType: CFNumberType, valuePtr: *anyopaque) Boolean;
    pub extern "c" fn CFBooleanGetValue(boolean: CFBooleanRef) Boolean;
    pub extern "c" fn CFPreferencesCopyAppValue(key: CFStringRef, applicationID: CFStringRef) CFTypeRef;
    pub extern "c" const kCFPreferencesAnyApplication: CFStringRef;

    // CoreGraphics
    pub const CGDirectDisplayID = u32;
    pub const CGDisplayModeRef = ?*anyopaque;
    pub const CGError = i32;

    pub extern "c" fn CGGetActiveDisplayList(
        maxDisplays: u32,
        activeDisplays: [*]CGDirectDisplayID,
        displayCount: *u32,
    ) CGError;
    pub extern "c" fn CGDisplayCopyDisplayMode(display: CGDirectDisplayID) CGDisplayModeRef;
    pub extern "c" fn CGDisplayModeRelease(mode: CGDisplayModeRef) void;
    pub extern "c" fn CGDisplayModeGetWidth(mode: CGDisplayModeRef) usize;
    pub extern "c" fn CGDisplayModeGetHeight(mode: CGDisplayModeRef) usize;
    pub extern "c" fn CGDisplayModeGetRefreshRate(mode: CGDisplayModeRef) f64;

    // IOKit / IOPS
    pub extern "c" fn IOPSCopyPowerSourcesInfo() CFTypeRef;
    pub extern "c" fn IOPSCopyPowerSourcesList(blob: CFTypeRef) CFArrayRef;
    pub extern "c" fn IOPSGetPowerSourceDescription(blob: CFTypeRef, ps: ?*const anyopaque) CFDictionaryRef;
    pub const kIOPSCurrentCapacityKey: [*:0]const u8 = "Current Capacity";
    pub const kIOPSIsChargingKey: [*:0]const u8 = "Is Charging";
};

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
    const version = mem.trimEnd(
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
    const brand = mem.trimEnd(
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
    const model = mem.trimEnd(
        u8,
        model_buf[0..model_size],
        &[_]u8{0},
    );
    return allocator.dupe(u8, model);
}

pub fn getDiskMounts() []const [:0]const u8 {
    return &[_][:0]const u8{"/"};
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
            @constCast(val_cap),
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
            @constCast(val_chg),
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

    const used = try common.fmtSize(allocator, bytes_used);
    const total = try common.fmtSize(allocator, bytes_total);
    const app = try common.fmtSize(
        allocator,
        pages_app * bytes_per_page,
    );
    const wired = try common.fmtSize(
        allocator,
        pages_wired * bytes_per_page,
    );
    const compressed = try common.fmtSize(
        allocator,
        pages_compressed * bytes_per_page,
    );
    return fmt.allocPrint(
        allocator,
        "{s} / {s} ({d}%)" ++
            " [App: {s}, Wired: {s}, Compressed: {s}]",
        .{ used, total, percent, app, wired, compressed },
    );
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
    const now_s: i64 = c.time(null);
    const boot_s: i64 = @intCast(boot_time.tv_sec);
    if (now_s < boot_s) return "Unknown";
    const uptime_s: u64 = @intCast(now_s - boot_s);
    return common.formatUptime(allocator, uptime_s);
}

pub fn getPackages(allocator: mem.Allocator) ![]const u8 {
    const brew_paths = [_][*:0]const u8{
        "/opt/homebrew/Cellar",
        "/usr/local/Cellar",
    };
    for (brew_paths) |brew_path| {
        const dp = opendir(brew_path) orelse continue;
        defer _ = closedir(dp);
        var count: u32 = 0;
        while (readdir(dp)) |entry| {
            const name = mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.*.d_name)), 0);
            if (mem.eql(u8, name, ".") or mem.eql(u8, name, "..")) continue;
            count += 1;
        }
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

// Minimal dirent bindings — we don't use the fields other than d_name here.
const DIR = opaque {};
const dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};
extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
extern "c" fn closedir(dirp: *DIR) c_int;
extern "c" fn readdir(dirp: *DIR) ?*dirent;
