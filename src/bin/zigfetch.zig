const std = @import("std");
const curl = @import("curl");
const simargs = @import("simargs");
const util = @import("util.zig");
const fs = std.fs;
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;
const print = std.debug.print;
const Child = std.process.Child;
const ArrayList = std.ArrayList;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const opt = try simargs.parse(
        allocator,
        struct {
            help: bool = false,
        },
        "[package-url]",
        util.get_build_info(),
    );

    if (opt.positional_args.len == 0) {
        const stdout = std.io.getStdOut();
        try opt.printHelp(stdout.writer());
        return;
    }
    const url = opt.positional_args[0];
    const easy = try curl.Easy.init(allocator, .{});
    try easy.setFollowLocation(true);
    try easy.setVerbose(true);
    defer easy.deinit();

    const resp = try easy.get(url);
    defer resp.deinit();
    if (resp.status_code != 200) {
        log.err("Failed to fetch {s}: {d}\n", .{ url, resp.status_code });
        return;
    }

    try untar(allocator, "/tmp/abcd", resp.body.?.items);
    // std.debug.print("Status code: {d}\nBody: {s}\n", .{
    //     resp.status_code,
    //     resp.body.?.items,
    // });
    // const s = fs.path.sep_str;
    // const cache_root = "/tmp/zig-cache";
    // const rand_int = std.crypto.random.int(u64);
    // const tmp_dir_sub_path = "tmp" ++ s ++ hex64(rand_int);
    // std.debug.print("Hello, world!\n", .{});
}

const hex_charset = "0123456789abcdef";

pub fn hex64(x: u64) [16]u8 {
    var result: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const byte = @as(u8, @truncate(x >> @as(u6, @intCast(8 * i))));
        result[i * 2 + 0] = hex_charset[byte >> 4];
        result[i * 2 + 1] = hex_charset[byte & 15];
    }
    return result;
}

fn untar(allocator: Allocator, out_dir: []const u8, src: []const u8) !void {
    _ = fs.openDirAbsolute(out_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("{s} not existing, try create it...", .{out_dir});
            try fs.makeDirAbsolute(out_dir);
        },
        else => return err,
    };

    const argv = [_][]const u8{
        "tar",
        "-xz",
        "--strip-components=1",
        "-C",
        out_dir,
    };
    var child = Child.init(&argv, allocator);
    child.stdin_behavior = .Pipe;
    try child.spawn();

    const stdin = child.stdin.?;
    try stdin.writeAll(src);
    // Those following 2 lines are require to let tar exit, otherwise child process wait stdin forever!
    stdin.close();
    child.stdin = null;

    const term = try child.wait();
    switch (term) {
        .Exited => |rc| {
            if (rc == 0) {
                return;
            }
        },
        else => {},
    }
    log.err("Failed to untar, term:{any}", .{term});
    return error.Untar;
}

// fn unzip(out_dir: fs.Dir, reader: anytype) !void {}
