const std = @import("std");
const fs = std.fs;

const testing = std.testing;

const State = union(enum) { anything: bool, exact: []const u8 };
const StateMachine = std.ArrayList(State);

const CheckResult = enum { Ignore, Exclude };

const IgnoreRule = struct {
    is_dir: bool,
    is_exclude: bool,
    state_machine: StateMachine,
    dir: []const u8,

    const Self = @This();

    fn init(allocator: std.mem.Allocator, dir: []const u8) Self {
        return .{
            .is_dir = false,
            .is_exclude = false,
            .state_machine = StateMachine.init(allocator),
            .dir = dir,
        };
    }

    fn deinit(self: Self) void {
        self.state_machine.deinit();
    }

    fn pushState(self: *Self, state: State) !void {
        try self.state_machine.append(state);
    }

    fn check(self: Self, path: []const u8, file_entry: fs.IterableDir.Entry) CheckResult {
        if (self.is_dir and file_entry.kind != .directory) {
            return if (self.is_exclude) .Exclude else .Ignore;
        }

        const remainings = std.mem.trimLeft(u8, path, self.dir);
        for(self.state_machine.items) |state| {
            switch (state) {
                .anything => {},
                .exact => {
                    unreachable,
                },
            }
        }
    }

    fn printState(self: Self, buf: anytype) !void {
        try buf.writeAll("state: [");
        for (self.state_machine.items, 0..) |item, i| {
            if (i > 0) {
                try buf.writeAll(", ");
            }
            switch (item) {
                .anything => try buf.writeAll("any"),
                .exact => |exact| try buf.writeAll(exact),
            }
        }
        try buf.writeAll("]");
    }
};

const IgnoreParser = struct {
    allocator: std.mem.Allocator,
    dir: []const u8,

    const Self = @This();
    fn init(allocator: std.mem.Allocator, dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .dir = dir,
        };
    }

    fn parse(self: Self, input: []const u8) !?IgnoreRule {
        if (std.mem.startsWith(u8, input, "#") or std.mem.eql(u8, input, "")) {
            return null;
        }

        var rule = IgnoreRule.init(self.allocator, self.dir);
        var start: usize = 0;
        var end: usize = input.len;
        if (std.mem.startsWith(u8, input, "!")) {
            rule.is_exclude = true;
            start = 1;
        }
        if (std.mem.endsWith(u8, input, "/")) {
            rule.is_dir = true;
            end = end - 1;
        }

        var it = std.mem.splitScalar(u8, input[start..end], '/');
        var first_item = it.first();
        if (!std.mem.eql(u8, "", first_item)) {
            try rule.pushState(State{ .anything = true });
            try rule.pushState(State{ .exact = first_item });
        }

        while (it.next()) |item| {
            if (std.mem.eql(u8, "**", item)) {
                try rule.pushState(State{ .anything = true });
            } else {
                try rule.pushState(State{ .exact = item });
            }
        }

        return rule;
    }
};

test "parser rule" {
    const parser = IgnoreParser.init(std.testing.allocator, "/tmp");

    // https://www.atlassian.com/git/tutorials/saving-changes/gitignore#git-ignore-patterns
    // https://git-scm.com/docs/gitignore
    inline for (.{
        // (input, is_dir, is_exclude, state)
        .{ "/a/b/c", false, false, "state: [a, b, c]" },
        .{ "a/b/", true, false, "state: [any, a, b]" },
        .{ "/a/b/", true, false, "state: [a, b]" },
        .{ "!/a/b/", true, true, "state: [a, b]" },
        .{ "!/a/**/b/", true, true, "state: [a, any, b]" },
    }) |case| {
        const input = case.@"0";
        const is_dir = case.@"1";
        const is_exclude = case.@"2";
        const state = case.@"3";

        const rule = parser.parse(input) catch unreachable orelse unreachable;
        defer rule.deinit();

        try testing.expectEqual(is_dir, rule.is_dir);
        try testing.expectEqual(is_exclude, rule.is_exclude);

        var collector = std.ArrayList(u8).init(std.testing.allocator);
        defer collector.deinit();
        try rule.printState(collector.writer());
        try testing.expectEqualStrings(state, collector.items);
    }
}
