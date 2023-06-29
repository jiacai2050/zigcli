const std = @import("std");
const info = @import("build_info");
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
    return std.fmt.comptimePrint("Build date: {s}\nGit commit: {s}", .{
        info.build_date,
        info.git_commit,
    });
}
