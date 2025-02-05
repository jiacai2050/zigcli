//! Run a command with bounded time
//! https://github.com/coreutils/coreutils/blob/v9.6/src/timeout.c

const std = @import("std");
const posix = std.posix;
const Child = std.process.Child;

pub var child: Child = undefined;
pub var spawn_success = false;

pub fn main() !void {
    posix.sigaction(posix.SIG.ALRM, &posix.Sigaction{
        .handler = .{
            .handler = struct {
                pub fn handler(got: c_int) callconv(.C) void {
                    std.debug.assert(got == posix.SIG.ALRM);
                    _ = child.kill() catch |e| {
                        std.log.err("Kill child failed, err:{any}", .{e});
                        return;
                    };
                    posix.exit(124); // timeout
                }
            }.handler,
        },
        .mask = posix.empty_sigset,
        .flags = 0,
    }, null);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print(
            \\Usage:
            \\ {s} SECONDS COMMAND [ARG]...
            \\
        , .{args[0]});
        posix.exit(1);
    }

    const ttl_seconds = try std.fmt.parseInt(c_uint, args[1], 10);
    const cmds = args[2..];
    const ret = std.c.alarm(ttl_seconds);
    if (ret != 0) {
        std.log.err("Set alarm signal failed, retcode:{d}", .{ret});
        posix.exit(1);
    }

    child = Child.init(cmds, allocator);
    try child.spawn();
    spawn_success = true;
    const term = try child.wait();
    switch (term) {
        .Exited => |status| {
            posix.exit(status);
        },
        else => {
            std.log.err("Child internal error, term:{any}", .{term});
            posix.exit(125);
        },
    }
}
