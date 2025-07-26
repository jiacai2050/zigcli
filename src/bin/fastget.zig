const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const log = std.log;

const sl = log.scoped(.fastget);

const CliOptions = struct {
    help: bool = false,
    timeout: usize = 60,
    verbose: bool = true,

    pub const __messages__ = .{
        .help = "Print this help",
        .verbose = "Show verbose log",
        .timeout = "HTTP timeout in seconds",
    };
};

const App = struct {
    root_dir: []const u8,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const opt = try simargs.parse(
        allocator,
        CliOptions,
        "[binary-url]",
        util.get_build_info(),
    );
    defer opt.deinit();

    if (opt.positional_args.len == 0) {
        const stdout = std.io.getStdOut();
        try opt.printHelp(stdout.writer());
        return;
    }

    const root_dir = std.process.getEnvVarOwned(allocator, "FASTGET_ROOT") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => blk: {
            const home = std.posix.getenv("HOME") orelse @panic("cannot find HOME dir");
            break :blk try std.fmt.allocPrint(allocator, "{s}/.fastget", .{home});
        },
        else => return e,
    };
    std.debug.print("got {any}-{s}", .{ opt.args, root_dir });
    defer allocator.free(root_dir);
    std.fs.accessAbsolute(root_dir, .{}) catch |e| switch (e) {
        error.FileNotFound => try initDirectories(allocator, root_dir),
        else => return e,
    };
}

fn initDirectories(allocator: Allocator, root_dir: []const u8) !void {
    sl.debug("init dirs({s})", .{root_dir});
    try ensureDir(root_dir);
    inline for (.{ "bin", "installed", "tmp" }) |sub_dir| {
        const bin_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root_dir, sub_dir });
        defer allocator.free(bin_dir);
        try ensureDir(bin_dir);
    }
}

fn ensureDir(dir: []const u8) !void {
    std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}
