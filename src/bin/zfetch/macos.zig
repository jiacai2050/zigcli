//! macOS platform implementation for zfetch.

const std = @import("std");
const common = @import("common.zig");
const mem = std.mem;
const fmt = std.fmt;
const Io = std.Io;
const Environ = std.process.Environ;

const c = @cImport({
    @cInclude("sys/time.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/mount.h");
});

// Minimal CoreGraphics bindings — declared manually because @cImport of
// <CoreGraphics/CoreGraphics.h> fails under arocc.
const CGDirectDisplayID = u32;
const CGDisplayModeRef = ?*anyopaque;
const CGError = i32;
extern "c" fn CGGetOnlineDisplayList(
    maxDisplays: u32,
    onlineDisplays: ?[*]CGDirectDisplayID,
    displayCount: *u32,
) CGError;
extern "c" fn CGDisplayCopyDisplayMode(display: CGDirectDisplayID) CGDisplayModeRef;
extern "c" fn CGDisplayModeRelease(mode: CGDisplayModeRef) void;
extern "c" fn CGDisplayModeGetWidth(mode: CGDisplayModeRef) usize;
extern "c" fn CGDisplayModeGetHeight(mode: CGDisplayModeRef) usize;
extern "c" fn CGDisplayModeGetRefreshRate(mode: CGDisplayModeRef) f64;
extern "c" fn CGDisplayIsBuiltin(display: CGDirectDisplayID) c.boolean_t;
extern "c" fn zfetch_get_battery(buffer: [*]u8, buffer_size: usize) c_int;
extern "c" fn zfetch_is_dark_theme() c_int;
extern "c" fn zfetch_get_memory(
    bytes_total: *u64,
    pages_app: *u64,
    pages_wired: *u64,
    pages_compressed: *u64,
) c_int;

pub const getHostname = common.getHostname;
pub const getKernel = common.getKernel;

pub fn getOs(_: Io, allocator: mem.Allocator) ![]const u8 {
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

pub fn getCpu(_: Io, allocator: mem.Allocator) ![]const u8 {
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

pub fn getGpu(_: Io, _: mem.Allocator) ![]const u8 {
    return "Unknown";
}

pub fn getHost(_: Io, allocator: mem.Allocator) ![]const u8 {
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

pub fn getResolution(_: Io, allocator: mem.Allocator) ![]const u8 {
    var display_count: u32 = 0;
    if (CGGetOnlineDisplayList(
        0,
        null,
        &display_count,
    ) != 0 or display_count == 0) {
        return "Unknown";
    }

    const display_ids = try allocator.alloc(CGDirectDisplayID, display_count);
    if (CGGetOnlineDisplayList(
        display_count,
        display_ids.ptr,
        &display_count,
    ) != 0 or display_count == 0) {
        return "Unknown";
    }

    var parts: std.ArrayList(u8) = .empty;
    for (display_ids[0..display_count]) |did| {
        const mode = CGDisplayCopyDisplayMode(did);
        if (mode == null) continue;
        defer CGDisplayModeRelease(mode);

        const w: u32 = @intCast(CGDisplayModeGetWidth(mode));
        const h: u32 = @intCast(CGDisplayModeGetHeight(mode));
        const hz = CGDisplayModeGetRefreshRate(mode);

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
        if (CGDisplayIsBuiltin(did) != 0) {
            try parts.appendSlice(allocator, " (built-in)");
        }
    }
    return if (parts.items.len > 0) parts.items else "Unknown";
}

pub fn getBattery(_: Io, allocator: mem.Allocator) ![]const u8 {
    var battery_buf: [64]u8 = undefined;
    const battery_len = zfetch_get_battery(
        &battery_buf,
        battery_buf.len,
    );
    if (battery_len < 0) return error.BatteryReadFailed;
    const battery_len_usize = @as(usize, @intCast(battery_len));
    if (battery_len_usize >= battery_buf.len) return error.BatteryReadFailed;
    return allocator.dupe(u8, battery_buf[0..battery_len_usize]);
}

pub fn getTheme(_: Io, _: *const Environ.Map) []const u8 {
    if (zfetch_is_dark_theme() != 0) {
        return "Dark";
    }
    return "Light";
}

pub fn getMemory(
    _: Io,
    allocator: mem.Allocator,
    bytes_per_page: u64,
) ![]const u8 {
    var bytes_total: u64 = 0;
    var pages_app: u64 = 0;
    var pages_wired: u64 = 0;
    var pages_compressed: u64 = 0;
    const memory_result = zfetch_get_memory(
        &bytes_total,
        &pages_app,
        &pages_wired,
        &pages_compressed,
    );
    if (memory_result < 0) {
        return "Unknown";
    }
    if (memory_result > 0) {
        return fmt.allocPrint(
            allocator,
            "{d} MiB",
            .{bytes_total / (1024 * 1024)},
        );
    }

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

pub fn getUptime(io: Io, allocator: mem.Allocator) ![]const u8 {
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
    const now_s: i64 = Io.Clock.now(.real, io).toSeconds();
    const boot_s: i64 = @intCast(boot_time.tv_sec);
    if (now_s < boot_s) return "Unknown";
    const uptime_s: u64 = @intCast(now_s - boot_s);
    return common.formatUptime(allocator, uptime_s);
}

pub fn getPackages(io: Io, allocator: mem.Allocator) ![]const u8 {
    const brew_paths = [_][]const u8{
        "/opt/homebrew/Cellar",
        "/usr/local/Cellar",
    };
    for (brew_paths) |brew_path| {
        var dir = std.Io.Dir.cwd().openDir(io, brew_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        var count: u32 = 0;
        while (try it.next(io)) |_| count += 1;
        if (count > 0) {
            return fmt.allocPrint(allocator, "{d} (brew)", .{count});
        }
        break; // Only use the first found path.
    }
    return "Unknown";
}
