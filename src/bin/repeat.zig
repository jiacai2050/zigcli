//! Repeat a command until it succeeds.

const std = @import("std");
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const util = @import("util.zig");
const mem = std.mem;
const time = std.time;

pub fn main(init: std.process.Init) !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try structargs.parse(allocator, init.io, init.minimal.args, struct {
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
    }, .{
        .argument_prompt = "command",
        .version_string = util.get_build_info(),
    });
    defer opt.deinit();

    const argv = if (opt.positional_arguments.len == 0) {
        return error.NoCommand;
    } else opt.positional_arguments;

    var keep_running = true;
    var i: usize = 0;
    while (keep_running) {
        i += 1;
        if (opt.options.max) |max| {
            if (max != 0 and i >= max) {
                keep_running = false;
            }
        }
        if (try run(init.io, argv)) |exit_code| {
            if (exit_code == 0) keep_running = false;
        }

        if (keep_running) {
            if (opt.options.interval) |pause| {
                try std.Io.sleep(
                    init.io,
                    .{ .nanoseconds = @intCast(pause * time.ns_per_s) },
                    .awake,
                );
            }
        }
    }
}

fn run(io: std.Io, argv: []const []const u8) !?u8 {
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}
