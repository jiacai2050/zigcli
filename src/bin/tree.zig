//! Tree(1) in Zig
//! https://linux.die.net/man/1/tree
//!
//! Order:
//! - Files first, directory last
//! - Asc

const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const StringUtil = util.StringUtil;
const process = std.process;
const fs = std.fs;
const mem = std.mem;
const testing = std.testing;
const fmt = std.fmt;

pub const std_options: std.Options = .{
    .log_level = .info,
};

const Mode = enum {
    ascii,
    box,
    dos,
};

const Position = enum {
    Normal,
    // last file in current dir
    Last,
    UpperNormal,
    // last file is upper dir
    UpperLast,
};

const PREFIX_ARR = [_][4][]const u8{ // mode -> position
    .{ "|--", "\\--", "|  ", "   " },
    .{ "├──", "└──", "│  ", "   " },
    // https://en.m.wikipedia.org/wiki/Box-drawing_character#DOS
    .{ "╠══", "╚══", "║  ", "   " },
};

fn getPrefix(mode: Mode, pos: Position) []const u8 {
    return PREFIX_ARR[@intFromEnum(mode)][@intFromEnum(pos)];
}

pub const WalkOptions = struct {
    mode: Mode = .box,
    all: bool = false,
    size: bool = false,
    directory: bool = false,
    level: ?usize,
    version: bool = false,
    help: bool = false,

    pub const __shorts__ = .{
        .all = .a,
        .mode = .m,
        .size = .s,
        .directory = .d,
        .level = .L,
        .version = .v,
        .help = .h,
    };

    pub const __messages__ = .{
        .mode = "Line drawing characters.",
        .all = "All files are printed.",
        .size = "Print the size of each file in bytes along with the name.",
        .directory = "List directories only.",
        .level = "Max display depth of the directory tree.",
        .version = "Print version.",
        .help = "Print help information.",
    };
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = try simargs.parse(
        allocator,
        WalkOptions,
        "[directory]",
        util.get_build_info(),
    );
    defer opt.deinit();

    const root_dir = if (opt.positional_args.len == 0)
        "."
    else
        opt.positional_args[0];

    var writer = std.io.bufferedWriter(std.io.getStdOut().writer());
    _ = try writer.write(root_dir);
    _ = try writer.write("\n");

    var dir = try fs.cwd().openDir(root_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    const ret = try walk(allocator, opt.args, &iter, &writer, "", 1);

    _ = try writer.write(try std.fmt.allocPrint(allocator, "\n{d} directories, {d} files\n", .{
        ret.directories,
        ret.files,
    }));
    try writer.flush();
}

fn stringLessThan(a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    while (i < a.len and i < b.len) {
        if (a[i] != b[i]) {
            return a[i] < b[i];
        }
        i += 1;
    }
    return a.len < b.len;
}

test "testing string lessThan" {
    const testcases = .{
        .{ "a", "a", false },
        .{ "a", "aa", true },
        .{ "a", "b", true },
        .{ "b", "a", false },
        .{ "a", "A", false }, // A > a
    };
    inline for (testcases) |case| {
        try testing.expectEqual(case.@"2", stringLessThan(case.@"0", case.@"1"));
    }
}

const WalkResult = struct {
    files: usize,
    directories: usize,

    fn add(self: *@This(), other: @This()) void {
        self.directories += other.directories;
        self.files += other.files;
    }
};

fn walk(
    allocator: mem.Allocator,
    walk_ctx: anytype,
    iter: *fs.Dir.Iterator,
    writer: anytype,
    prefix: []const u8,
    level: usize,
) !WalkResult {
    var ret = WalkResult{ .files = 0, .directories = 0 };
    if (walk_ctx.level) |max| {
        if (level > max) {
            return ret;
        }
    }

    var files = std.ArrayList(fs.Dir.Entry).init(allocator);
    defer {
        for (files.items) |entry| {
            allocator.free(entry.name);
        }
        files.deinit();
    }

    while (try iter.next()) |entry| {
        const dupe_name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(dupe_name);

        if (walk_ctx.directory) {
            if (entry.kind != .directory) {
                continue;
            }
        }

        if (!walk_ctx.all) {
            if ('.' == entry.name[0]) {
                continue;
            }
        }

        try files.append(.{ .name = dupe_name, .kind = entry.kind });
    }

    std.sort.heap(fs.Dir.Entry, files.items, {}, struct {
        fn lessThan(ctx: void, a: fs.Dir.Entry, b: fs.Dir.Entry) bool {
            _ = ctx;

            // file < directory
            if (a.kind != b.kind) {
                if (a.kind == .directory) {
                    return false;
                }
                if (b.kind == .directory) {
                    return true;
                }
            }

            return stringLessThan(a.name, b.name);
        }
    }.lessThan);

    var buf: [fs.max_path_bytes]u8 = undefined;
    for (files.items, 0..) |entry, i| {
        _ = try writer.write(prefix);

        if (i < files.items.len - 1) {
            _ = try writer.write(getPrefix(walk_ctx.mode, Position.Normal));
        } else {
            _ = try writer.write(getPrefix(walk_ctx.mode, Position.Last));
        }
        _ = try writer.write(entry.name);

        if (walk_ctx.size) {
            const stat = try iter.dir.statFile(entry.name);
            _ = try writer.write(" [");
            _ = try writer.write(try StringUtil.humanSize(allocator, stat.size));
            _ = try writer.write("]");
        }
        switch (entry.kind) {
            .directory => {
                _ = try writer.write("\n");
                ret.directories += 1;
                var sub_dir = try iter.dir.openDir(entry.name, .{ .iterate = true });
                defer sub_dir.close();
                var sub_iter_dir = sub_dir.iterate();

                const new_prefix =
                    if (i < files.items.len - 1)
                        try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, getPrefix(walk_ctx.mode, Position.UpperNormal) })
                    else
                        try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, getPrefix(walk_ctx.mode, Position.UpperLast) });

                ret.add(try walk(allocator, walk_ctx, &sub_iter_dir, writer, new_prefix, level + 1));
            },
            .sym_link => {
                ret.files += 1;
                const linked_name = try iter.dir.readLink(entry.name, &buf);
                _ = try writer.write(" -> ");
                _ = try writer.write(linked_name);
                _ = try writer.write("\n");
            },
            else => {
                ret.files += 1;
                _ = try writer.write("\n");
            },
        }
    }

    return ret;
}
