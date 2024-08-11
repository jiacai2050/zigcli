//! Repeat a command until it succeeds.

const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const os = std.os;
const process = std.process;
const mem = std.mem;
const time = std.time;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = try simargs.parse(allocator, struct {
        max: ?usize,
        interval: ?usize,
        version: bool = false,
        help: bool = false,

        pub const __shorts__ = .{
            .max = .m,
            .interval = .i,
            .version = .v,
            .help = .h,
        };

        pub const __messages__ = .{
            .max = "Max times to repeat",
            .interval = "Pause interval(in seconds) between repeats",
            .version = "Print version",
            .help = "Print help information",
        };
    }, "command", util.get_build_info());
    defer opt.deinit();

    const argv = if (opt.positional_args.len == 0) {
        return error.NoCommand;
    } else opt.positional_args;

    var keep_running = true;
    var i: usize = 0;
    while (keep_running) {
        i += 1;
        if (opt.args.max) |max| {
            if (max != 0 and i >= max) {
                keep_running = false;
            }
        }
        const term = try run(allocator, argv);
        switch (term) {
            .Exited => |rc| {
                if (rc == 0) {
                    keep_running = false;
                }
            },
            else => {},
        }

        if (keep_running) {
            if (opt.args.interval) |pause| {
                time.sleep(pause * time.ns_per_s);
            }
        }
    }
}

fn run(allocator: mem.Allocator, argv: []const []const u8) !process.Child.Term {
    var child = process.Child.init(argv, allocator);
    // By default, child will inherit stdout & stderr from its parents,
    // so child's output will be redirect to output of parents.
    return try child.spawnAndWait();
}
