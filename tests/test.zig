//! `yes` unix command in Zig, optimized for speed
//! Reference to: https://github.com/cgati/yes

const std = @import("std");

const BUFFER_CAP = 64 * 1024;

fn fillBuffer(buf: *[BUFFER_CAP]u8, word: []const u8) []const u8 {
    if (word.len > buf.len / 2) {
        return word;
    }

    std.mem.copy(u8, buf, word);
    var buffer_size = word.len;
    while (buffer_size < buf.len / 2) {
        std.mem.copy(u8, buf[buffer_size..], buf[0..buffer_size]);
        buffer_size *= 2;
    }

    return buf[0..buffer_size];
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next();
    const word = if (args.next()) |arg| x: {
        var buf = std.ArrayList(u8).init(allocator);
        try buf.appendSlice(arg);
        try buf.append('\n');
        break :x buf.items;
    } else "y\n";

    var buffer: [BUFFER_CAP]u8 = undefined;
    const body = fillBuffer(&buffer, word);
    const stdout = std.io.getStdOut();
    var writer = stdout.writer();
    while (true) {
        try writer.writeAll(body);
    }
}
