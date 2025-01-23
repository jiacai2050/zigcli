const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const testing = std.testing;

const State = union(enum) { anything: bool, exact: []const u8 };
const StateMachine = std.ArrayList(State);
const PathIter = mem.SplitIterator(u8, .sequence);
const CheckResult = enum { Ignore, Exclude, None };

fn match_iter(states: []const State, paths: []const []const u8) bool {
    if (states.len == 0) {
        return paths.len == 0;
    }

    if (paths.len == 0) {
        for (states) |s| {
            if (.anything != s) {
                return false;
            }
        }
        return true;
    }

    switch (states[0]) {
        .anything => return match_iter(states, paths[1..]) or
            match_iter(states[1..], paths[1..]),
        .exact => |expect| {
            if (std.mem.eql(u8, expect, paths[0])) {
                return match_iter(states[1..], paths[1..]);
            }

            return false;
        },
    }
}

test "match iter" {
    inline for (.{
        .{ &[_]State{.{ .anything = true }}, "aaa", true },
        .{ &[_]State{.{ .anything = true }}, "b", true },
        .{ &[_]State{.{ .anything = true }}, "", true },
        .{ &[_]State{ .{ .anything = true }, .{ .exact = "b" } }, "a/a/b", true },
        .{ &[_]State{ .{ .anything = true }, .{ .exact = "b" } }, "a/a/b/c", false },
        .{ &[_]State{ .{ .anything = true }, .{ .exact = "b" } }, "a/b/a/b", true },
        .{ &[_]State{ .{ .anything = true }, .{ .exact = "b" }, .{ .anything = true } }, "a/a/b/c", true },
    }) |case| {
        const states = case.@"0";
        const input = case.@"1";
        const expected = case.@"2";
        var path_iter = mem.splitSequence(u8, input, "/");
        var paths = std.ArrayList([]const u8).init(testing.allocator);
        defer paths.deinit();
        while (path_iter.next()) |v| {
            paths.append(v) catch @panic("OOM");
        }
        try testing.expectEqual(match_iter(states, paths.items), expected);
    }
}

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

    fn check(self: Self, path: []const u8, file_entry: fs.IterableDir.Entry) !CheckResult {
        if (self.is_dir and file_entry.kind != .directory) {
            return if (self.is_exclude) .Exclude else .Ignore;
        }

        const remainings = mem.trimLeft(u8, path, self.dir);
        var path_iter = mem.splitSequence(u8, remainings, "/");
        var paths = std.ArrayList([]const u8);
        while (path_iter.next()) |v| {
            try paths.append(v);
        }
        const match = match_iter(self.state_machine.items, paths);
        if (match) {
            return if (self.is_exclude) .Exclude else .Ignore;
        }

        return .None;
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
