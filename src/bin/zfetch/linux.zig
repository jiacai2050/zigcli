//! Linux platform implementation for zfetch.

const std = @import("std");
const common = @import("common.zig");
const mem = std.mem;
const fmt = std.fmt;

const c = @cImport({
    @cInclude("unistd.h");
});

pub fn getOs(allocator: mem.Allocator) ![]const u8 {
    return common.getOsFromRelease(allocator, "Linux");
}

pub fn getCpu(allocator: mem.Allocator) ![]const u8 {
    return common.getCpuFromProc(allocator);
}

pub fn getHost(allocator: mem.Allocator) ![]const u8 {
    return common.getHostFromDmi(allocator, "Linux");
}

pub fn getDiskMounts() []const []const u8 {
    return &[_][]const u8{ "/", "/home" };
}

pub fn getResolution(allocator: mem.Allocator) ![]const u8 {
    return common.getResolutionFromDrm(allocator);
}

pub fn getBattery(allocator: mem.Allocator) ![]const u8 {
    return common.getBatteryFromSys(allocator);
}

pub fn getTheme() []const u8 {
    return common.getThemeFromGtk();
}

pub fn getMemory(
    allocator: mem.Allocator,
    _: u64,
) ![]const u8 {
    return common.getMemoryFromProc(allocator);
}

pub fn fetchPageSize() u64 {
    return @intCast(c.getpagesize());
}

pub fn getUptime(allocator: mem.Allocator) ![]const u8 {
    return common.getUptimeFromProc(allocator);
}

pub fn getPackages(allocator: mem.Allocator) ![]const u8 {
    return common.getPackagesDpkg(allocator);
}
