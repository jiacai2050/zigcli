//! Yes in Zig
//! Output a string repeatedly until killed
//! https://man7.org/linux/man-pages/man1/yes.1.html
//!
const std = @import("std");

const BUFFER_CAP = 32 * 1024;

fn fillBuffer(buf: []u8, text: []const u8) usize {
    std.mem.copy(u8, buf, text);
    std.mem.copy(u8, buf[text.len..], "\n");

    if (text.len + 1 > buf.len / 2) { // plus one newline
        return buf.len;
    }

    var buffer_size = text.len + 1;
    while (buffer_size < buf.len / 2) {
        std.mem.copy(u8, buf[buffer_size..], buf[0..buffer_size]);
        buffer_size *= 2;
    }

    return buffer_size;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var iter = try std.process.argsWithAllocator(allocator);
    _ = iter.next() orelse unreachable; // program
    const input = iter.next() orelse "y";

    var buffer: [BUFFER_CAP]u8 = undefined;
    const size = fillBuffer(&buffer, input);
    const stdout = std.io.getStdOut();
    var writer = stdout.writer();
    while ((try writer.write(buffer[0..size])) > 0) {}
}
