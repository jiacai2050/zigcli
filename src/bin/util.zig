const std = @import("std");
const info = @import("build_info");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const mem = std.mem;
const fmt = std.fmt;

pub const Allocator = struct {
    debug_allocator: std.heap.DebugAllocator(.{}),
    is_debug: bool,

    pub const instance: Allocator = .{
        .debug_allocator = .init,
        .is_debug = switch (builtin.mode) {
            .Debug, .ReleaseSafe => true,
            .ReleaseFast, .ReleaseSmall => false,
        },
    };

    pub fn allocator(self: *Allocator) mem.Allocator {
        if (native_os == .wasi) return std.heap.wasm_allocator;
        return switch (builtin.mode) {
            .Debug, .ReleaseSafe => self.debug_allocator.allocator(),
            .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
        };
    }

    pub fn deinit(self: *Allocator) void {
        if (self.is_debug and self.debug_allocator.deinit() != .ok) {
            @panic("mem leaked");
        }
    }
};

pub const MAX_I32: i32 = std.math.maxInt(i32);
pub const StringUtil = struct {
    const SIZE_UNIT = [_][]const u8{ "B", "K", "M", "G", "T" };

    pub fn humanSize(allocator: mem.Allocator, n: u64) ![]const u8 {
        var remaining: f64 = @floatFromInt(n);
        var i: usize = 0;
        while (remaining > 1024) {
            remaining /= 1024;
            i += 1;
        }
        return fmt.allocPrint(allocator, "{d:.2}{s}", .{ remaining, SIZE_UNIT[i] });
    }
};

pub fn get_build_info() []const u8 {
    return fmt.comptimePrint(
        \\Zigcli
        \\ - version: {s}
        \\ - commit: https://github.com/jiacai2050/zigcli/commit/{s}
        \\
        \\Build Config:
        \\ - build date: {s}
        \\ - build mode: {s}
        \\ - zig version: {s}
        \\ - zig backend: {s}
    , .{
        info.version,
        info.git_commit,
        info.build_date,
        info.build_mode,
        builtin.zig_version_string,
        @tagName(builtin.zig_backend),
    });
}

pub fn SliceIter(comptime T: type) type {
    return struct {
        slice: []const T,
        idx: usize,

        const Self = @This();

        pub fn init(slice: []const T) Self {
            return .{
                .slice = slice,
                .idx = 0,
            };
        }

        pub fn next(self: *Self) ?T {
            if (self.idx == self.slice.len) {
                return null;
            }
            const value = self.slice[self.idx];
            self.idx += 1;
            return value;
        }
    };
}

test "slice iter" {
    var iter = SliceIter(u8).init(&[_]u8{ 1, 2, 3 });
    try std.testing.expectEqual(iter.next().?, 1);
    try std.testing.expectEqual(iter.next().?, 2);
    try std.testing.expectEqual(iter.next().?, 3);
    try std.testing.expectEqual(iter.next(), null);
}

// global var, used in one binary program.
var verbose: bool = false;

pub const enableVerbose = struct {
    pub fn call() void {
        verbose = true;
    }
};

pub fn debugPrint(
    comptime format: []const u8,
    args: anytype,
) void {
    if (verbose) {
        std.log.debug(format, args);
    }
}

pub fn getCpuCount() u32 {
    return std.Thread.getCpuCount() orelse 1;
}

pub fn isLinux() bool {
    return builtin.os.tag == .linux;
}

pub fn isWindows() bool {
    return builtin.os.tag == .windows;
}

pub fn checkCErr(ret: isize) !isize {
    if (ret < 0) {
        return error.CErr;
    }

    return ret;
}
