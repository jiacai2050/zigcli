const std = @import("std");
const curl = @import("curl");
const simargs = @import("simargs");
const util = @import("util.zig");
const Manifest = @import("./pkg/Manifest.zig");
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
            verbose: bool = false,
            out_dir: []const u8,

            pub const __shorts__ = .{
                .out_dir = .o,
                .verbose = .v,
                .help = .h,
            };
            pub const __messages__ = .{
                .out_dir = "Package output directory",
                .help = "Show help",
            };
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
    const out_dir = opt.args.out_dir;
    const verbose = opt.args.verbose;

    const buffer = try fetchPackage(allocator, url, verbose);
    log.info("buf size:{d}", .{buffer.items.len});
    defer buffer.deinit();
    try untar(allocator, out_dir, buffer.items);
    const manifest = try loadManifest(allocator, out_dir);
    log.info("manifest =  {any}", .{manifest});
}

fn fetchPackage(allocator: Allocator, url: [:0]const u8, verbose: bool) !curl.Buffer {
    const easy = try curl.Easy.init(allocator, .{});
    try easy.setFollowLocation(true);
    try easy.setVerbose(verbose);
    defer easy.deinit();

    const resp = try easy.get(url);
    // resp.
    defer resp.deinit();
    if (resp.status_code >= 400) {
        log.err("Failed to fetch {s}: {d}\n", .{ url, resp.status_code });
        return error.BadFetch;
    }
    return resp.body.?;
}

fn loadManifest(allocator: Allocator, dir: []const u8) !Manifest {
    const pkg_dir = try fs.openDirAbsolute(dir, .{ .iterate = true });
    const file = try pkg_dir.openFile(Manifest.basename, .{});
    defer file.close();
    const bytes = try file.readToEndAllocOptions(
        allocator,
        Manifest.max_bytes,
        null,
        1,
        0,
    );
    log.info("bytes:{s}", .{bytes});
    const ast = try std.zig.Ast.parse(allocator, bytes, .zon);
    return Manifest.parse(allocator, ast, .{
        .allow_missing_paths_field = true,
    });
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
