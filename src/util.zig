const std = @import("std");
const info = @import("build_info");
const builtin = @import("builtin");
const mem = std.mem;

pub const StringUtil = struct {
    const SIZE_UNIT = [_][]const u8{ "B", "K", "M", "G", "T" };

    pub fn humanSize(allocator: mem.Allocator, n: u64) ![]const u8 {
        var remaining: f64 = @floatFromInt(n);
        var i: usize = 0;
        while (remaining > 1024) {
            remaining /= 1024;
            i += 1;
        }
        return std.fmt.allocPrint(allocator, "{d:.2}{s}", .{ remaining, SIZE_UNIT[i] });
    }
};

pub fn get_build_info() []const u8 {
    return std.fmt.comptimePrint(
        \\Git commit: {s}
        \\Build date: {s}
        \\Zig version: {s}
        \\Zig backend: {s}
    , .{
        info.build_date,
        info.git_commit,
        builtin.zig_version_string,
        builtin.zig_backend,
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
