//! Run a command with bounded time
//! https://github.com/coreutils/coreutils/blob/v9.6/src/timeout.c

const std = @import("std");
const posix = std.posix;
const util = @import("util.zig");

pub var child: std.process.Child = undefined;
pub var spawn_success = false;
pub var child_io: std.Io = undefined;

fn alarmHandler(got: posix.SIG) callconv(.c) void {
    _ = got;
    if (spawn_success) {
        child.kill(child_io);
    }
    std.process.exit(124);
}

pub fn main(init: std.process.Init) !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();
    child_io = init.io;

    posix.sigaction(.ALRM, &posix.Sigaction{
        .handler = .{ .handler = alarmHandler },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len < 3) {
        std.debug.print(
            \\Usage:
            \\ {s} SECONDS COMMAND [ARG]...
            \\
        , .{args[0]});
        std.process.exit(1);
    }

    const ttl_seconds = try std.fmt.parseInt(c_uint, args[1], 10);
    const cmds = args[2..];
    _ = std.c.alarm(ttl_seconds);

    child = try std.process.spawn(init.io, .{ .argv = cmds });
    spawn_success = true;
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |status| std.process.exit(status),
        else => {
            std.log.err("Child internal error, term:{any}", .{term});
            std.process.exit(125);
        },
    }
}
