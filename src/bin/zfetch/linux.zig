//! Linux platform implementation for zfetch.

const std = @import("std");
const common = @import("common.zig");
const mem = std.mem;
const fmt = std.fmt;
const Io = std.Io;
const Environ = std.process.Environ;

pub const getHostname = common.getHostname;
pub const getKernel = common.getKernel;

pub fn getOs(io: Io, allocator: mem.Allocator) ![]const u8 {
    return common.getOsFromRelease(io, allocator, "Linux");
}

pub fn getCpu(io: Io, allocator: mem.Allocator) ![]const u8 {
    return common.getCpuFromProc(io, allocator);
}

pub fn getHost(io: Io, allocator: mem.Allocator) ![]const u8 {
    return common.getHostFromDmi(io, allocator, "Linux");
}

pub fn getDiskMounts() []const [:0]const u8 {
    return &[_][:0]const u8{ "/", "/home" };
}

pub fn getResolution(io: Io, allocator: mem.Allocator) ![]const u8 {
    return common.getResolutionFromDrm(io, allocator);
}

pub fn getBattery(io: Io, allocator: mem.Allocator) ![]const u8 {
    return common.getBatteryFromSys(io, allocator);
}

pub fn getTheme(io: Io, env: *const Environ.Map) []const u8 {
    return common.getThemeFromGtk(io, env);
}

pub fn getMemory(
    io: Io,
    allocator: mem.Allocator,
    _: u64,
) ![]const u8 {
    return common.getMemoryFromProc(io, allocator);
}

pub fn getUptime(io: Io, allocator: mem.Allocator) ![]const u8 {
    return common.getUptimeFromProc(io, allocator);
}

pub fn getPackages(io: Io, allocator: mem.Allocator) ![]const u8 {
    return common.getPackagesDpkg(io, allocator);
}
