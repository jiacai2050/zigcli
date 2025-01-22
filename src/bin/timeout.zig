const std = @import("std");
const posix = std.posix;
const Child = std.process.Child;

pub fn main() !void {
    try posix.sigaction(posix.SIG.ALRM, &posix.Sigaction{
        .handler = .{
            .handler = struct {
                pub fn handler(got: c_int) callconv(.C) void {
                    std.debug.print("Get {any}\n", .{got});

                    // TODO: handle update
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
        std.debug.print("timeout [OPTION] DURATION COMMAND [ARG]...", .{});
        posix.exit(1);
    }

    const ttl_seconds = try std.fmt.parseInt(c_uint, args[1], 10);
    const cmds = args[2..];
    const ret = std.c.alarm(ttl_seconds);
    std.debug.print("{any}\n", .{ret});
    for (cmds, 1..) |cmd, i| {
        std.debug.print("{d}. {s}\n", .{ i, cmd });
    }

    var child = Child.init(cmds, allocator);
    const term = try child.spawnAndWait();

    std.debug.print("{any}\n", .{term});
}
