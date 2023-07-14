//! Repeat a command until it succeeds.
//!
const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const os = std.os;
const process = std.process;
const mem = std.mem;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = try simargs.parse(allocator, struct {
        max: ?usize,
        version: bool = false,
        help: bool = false,

        pub const __shorts__ = .{
            .max = .m,
            .version = .v,
            .help = .h,
        };

        pub const __messages__ = .{
            .help = "Print help information",
            .version = "Print version",
            .max = "Max times to repeat",
        };
    }, "command", util.get_build_info());
    defer opt.deinit();

    const argv = if (opt.positional_args.items.len == 0) {
        return error.NoCommand;
    } else opt.positional_args.items;

    var keep_running = true;
    var i: usize = 0;
    while (keep_running) {
        i += 1;
        if (opt.args.max) |max| {
            if (max != 0 and i >= max) {
                keep_running = false;
            }
        }
        var term = try run(allocator, argv);
        switch (term) {
            .Exited => |rc| {
                if (rc == 0) {
                    keep_running = false;
                }
            },
            else => unreachable,
        }
    }
}

fn run(allocator: mem.Allocator, argv: []const []const u8) !process.Child.Term {
    var child = process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var poller = std.io.poll(allocator, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    var out = std.io.getStdOut();
    var err = std.io.getStdErr();
    // Currently stdout & stderr will be mixed, no ordering guaranteed.
    while (try poller.poll()) {
        const child_stdout = poller.fifo(.stdout);
        if (child_stdout.readableLength() > 0) {
            try out.writeAll(child_stdout.readableSlice(0));
            child_stdout.discard(child_stdout.count);
        }
        const child_stderr = poller.fifo(.stderr);
        if (child_stderr.readableLength() > 0) {
            try err.writeAll(child_stderr.readableSlice(0));
            child_stderr.discard(child_stderr.count);
        }
    }

    return try child.wait();
}
