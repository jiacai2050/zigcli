//! Tree(1) in Zig
//! https://linux.die.net/man/1/tree
//!
//! Order:
//! - Files first, directory last
//! - Asc

const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const gitignore = @import("gitignore");
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
    @"no-gitignore": bool = false,
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
        .@"no-gitignore" = "Do not use .gitignore rules to filter files.",
        .version = "Print version.",
        .help = "Print help information.",
    };
};

pub fn main() anyerror!void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try simargs.parse(
        allocator,
        WalkOptions,
        .{
            .argument_prompt = "[directory]",
            .version_string = util.get_build_info(),
        },
    );
    defer opt.deinit();

    const root_dir = if (opt.positional_arguments.len == 0)
        "."
    else
        opt.positional_arguments[0];

    const stdout = std.fs.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer = stdout.writer(&buf);

    try writer.interface.writeAll(root_dir);
    try writer.interface.writeAll("\n");

    var dir = try fs.cwd().openDir(root_dir, .{ .iterate = true });
    defer dir.close();

    var gi_stack = gitignore.GitignoreStack.init();
    defer gi_stack.deinit(allocator);
    if (!opt.options.@"no-gitignore") {
        _ = try gi_stack.tryPushDir(dir, "", allocator);
    }

    var iter = dir.iterate();
    const ret = try walk(allocator, opt.options, &gi_stack, &iter, &writer.interface, "", "", 1);

    var summary_buf: [64]u8 = undefined;
    const summary = try std.fmt.bufPrint(&summary_buf, "\n{d} directories, {d} files\n", .{
        ret.directories,
        ret.files,
    });
    try writer.interface.writeAll(summary);
    try writer.interface.flush();
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
    /// Long-lived allocator for GitignoreStack patterns and data that outlives this call.
    allocator: mem.Allocator,
    walk_ctx: WalkOptions,
    gi_stack: *gitignore.GitignoreStack,
    iter: *fs.Dir.Iterator,
    writer: *std.Io.Writer,
    prefix: []const u8,
    /// Path of current directory relative to walk root, e.g. "" or "src/bin"
    rel_dir: []const u8,
    level: usize,
) !WalkResult {
    // Per-level arena for temporary strings (rel_path, dupe_name, new_prefix, etc.)
    // Freed when this call returns, so memory doesn't accumulate across the tree.
    var local_arena = std.heap.ArenaAllocator.init(allocator);
    defer local_arena.deinit();
    const local = local_arena.allocator();

    var ret = WalkResult{ .files = 0, .directories = 0 };
    if (walk_ctx.level) |max| {
        if (level > max) {
            return ret;
        }
    }

    var files: std.ArrayList(fs.Dir.Entry) = .empty;

    while (try iter.next()) |entry| {
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

        const rel_path = if (rel_dir.len == 0)
            entry.name
        else
            try std.fmt.allocPrint(local, "{s}/{s}", .{ rel_dir, entry.name });

        if (gi_stack.shouldIgnore(rel_path, entry.kind == .directory)) continue;

        const dupe_name = try local.dupe(u8, entry.name);
        try files.append(local, .{ .name = dupe_name, .kind = entry.kind });
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
        try writer.writeAll(prefix);

        if (i < files.items.len - 1) {
            try writer.writeAll(getPrefix(walk_ctx.mode, Position.Normal));
        } else {
            try writer.writeAll(getPrefix(walk_ctx.mode, Position.Last));
        }
        try writer.writeAll(entry.name);

        if (walk_ctx.size) {
            const stat = try iter.dir.statFile(entry.name);
            try writer.writeAll(" [");
            try writer.writeAll(try StringUtil.humanSize(local, stat.size));
            try writer.writeAll("]");
        }
        switch (entry.kind) {
            .directory => {
                try writer.writeAll("\n");
                ret.directories += 1;
                var sub_dir = try iter.dir.openDir(entry.name, .{ .iterate = true });
                defer sub_dir.close();
                var sub_iter_dir = sub_dir.iterate();

                const new_prefix =
                    if (i < files.items.len - 1)
                        try std.fmt.allocPrint(local, "{s}{s}", .{ prefix, getPrefix(walk_ctx.mode, Position.UpperNormal) })
                    else
                        try std.fmt.allocPrint(local, "{s}{s}", .{ prefix, getPrefix(walk_ctx.mode, Position.UpperLast) });

                const new_rel_dir = if (rel_dir.len == 0)
                    entry.name
                else
                    try std.fmt.allocPrint(local, "{s}/{s}", .{ rel_dir, entry.name });

                // Push gitignore layer using the long-lived allocator (patterns outlive this call)
                const layer_pushed = if (!walk_ctx.@"no-gitignore")
                    try gi_stack.tryPushDir(sub_dir, new_rel_dir, allocator)
                else
                    false;
                defer if (layer_pushed) gi_stack.pop(allocator);

                ret.add(try walk(allocator, walk_ctx, gi_stack, &sub_iter_dir, writer, new_prefix, new_rel_dir, level + 1));
            },
            .sym_link => {
                ret.files += 1;
                const linked_name = try iter.dir.readLink(entry.name, &buf);
                try writer.writeAll(" -> ");
                try writer.writeAll(linked_name);
                try writer.writeAll("\n");
            },
            else => {
                ret.files += 1;
                try writer.writeAll("\n");
            },
        }
    }

    return ret;
}
