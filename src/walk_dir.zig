const std = @import("std");
const testing = std.testing;

const Rule = struct {
    is_dir: bool,

    const State = union(enum) { begin, end, anything, exact: []const u8 };

    const Self = @This();

    fn init(input: []const u8) Self {
        _ = input;
        return .{ .is_dir = true };
    }
};

test "init rule" {
    const r = Rule.init("abc");
    try testing.expectEqual(true, r.is_dir);
}
