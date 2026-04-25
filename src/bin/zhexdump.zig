//! zhexdump: color-coded hex dump of files or stdin.

const std = @import("std");
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const term = zigcli.term;
const util = @import("util.zig");

const Options = struct {
    length: ?usize = null,
    skip: ?usize = null,
    @"no-color": bool = false,
    help: bool = false,
    version: bool = false,

    pub const __shorts__ = .{
        .length = .n,
        .skip = .s,
        .@"no-color" = .C,
        .help = .h,
        .version = .v,
    };

    pub const __messages__ = .{
        .length = "Only read N bytes.",
        .skip = "Skip N bytes from the start.",
        .@"no-color" = "Disable color output.",
        .help = "Print help information.",
        .version = "Print version.",
    };
};

fn byteColor(byte: u8) term.Style.Color {
    return switch (byte) {
        0x00 => .bright_black,
        0xFF => .bright_white,
        0x09, 0x0A, 0x0D, 0x20 => .yellow,
        0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => .red,
        0x21...0x4F => .green,
        0x50...0x7E => .bright_green,
        0x80...0xBF => .blue,
        0xC0...0xEF => .bright_blue,
        0xF0...0xFE => .magenta,
    };
}

fn printRow(
    writer: *std.Io.Writer,
    offset: u64,
    bytes: []const u8,
    use_color: bool,
) !void {
    // Offset column.
    try writer.print("{x:0>8}  ", .{offset});

    // Hex bytes: 4 groups of 4, double-space between each group.
    for (0..16) |i| {
        if (i > 0 and i % 4 == 0) try writer.writeAll(" "); // extra space between groups
        if (i < bytes.len) {
            const b = bytes[i];
            if (use_color) {
                const color = byteColor(b);
                try writer.writeAll(color.toEscapeCode());
                try writer.print("{x:0>2}", .{b});
                try writer.writeAll(term.Style.Color.reset);
            } else {
                try writer.print("{x:0>2}", .{b});
            }
        } else {
            try writer.writeAll("  "); // padding for short last row
        }
        if (i < 15) try writer.writeAll(" ");
    }

    // ASCII panel.
    try writer.writeAll("  |");
    for (0..16) |i| {
        if (i < bytes.len) {
            const b = bytes[i];
            const ch: u8 = if (b >= 0x20 and b <= 0x7E) b else '.';
            if (use_color) {
                const color = byteColor(b);
                try writer.writeAll(color.toEscapeCode());
                try writer.writeByte(ch);
                try writer.writeAll(term.Style.Color.reset);
            } else {
                try writer.writeByte(ch);
            }
        } else {
            try writer.writeAll(" ");
        }
    }
    try writer.writeAll("|\n");
}

pub fn main(init: std.process.Init) anyerror!void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try structargs.parse(
        allocator,
        init.io,
        init.minimal.args,
        Options,
        .{
            .argument_prompt = "[file]",
            .version_string = util.get_build_info(),
        },
    );
    defer opt.deinit();
}

const testing = std.testing;

test "byteColor null byte" {
    try testing.expectEqual(term.Style.Color.bright_black, byteColor(0x00));
}

test "byteColor FF byte" {
    try testing.expectEqual(term.Style.Color.bright_white, byteColor(0xFF));
}

test "byteColor whitespace" {
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0x0A)); // newline
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0x20)); // space
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0x09)); // tab
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0x0D)); // CR
}

test "byteColor control chars" {
    try testing.expectEqual(term.Style.Color.red, byteColor(0x01));
    try testing.expectEqual(term.Style.Color.red, byteColor(0x7F)); // DEL
}

test "byteColor printable ASCII low" {
    try testing.expectEqual(term.Style.Color.green, byteColor(0x21)); // '!'
    try testing.expectEqual(term.Style.Color.green, byteColor(0x41)); // 'A'
    try testing.expectEqual(term.Style.Color.green, byteColor(0x4F)); // 'O'
}

test "byteColor printable ASCII high" {
    try testing.expectEqual(term.Style.Color.bright_green, byteColor(0x50)); // 'P'
    try testing.expectEqual(term.Style.Color.bright_green, byteColor(0x7E)); // '~'
}

test "byteColor high bytes" {
    try testing.expectEqual(term.Style.Color.blue, byteColor(0x80));
    try testing.expectEqual(term.Style.Color.blue, byteColor(0xBF));
    try testing.expectEqual(term.Style.Color.bright_blue, byteColor(0xC0));
    try testing.expectEqual(term.Style.Color.bright_blue, byteColor(0xEF));
    try testing.expectEqual(term.Style.Color.magenta, byteColor(0xF0));
    try testing.expectEqual(term.Style.Color.magenta, byteColor(0xFE));
}

test "printRow no color simple" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const bytes = "Hello, World!\n\x00\xff";
    try printRow(&aw.writer, 0, bytes, false);
    const out = aw.written();
    // exact full output check
    try testing.expectEqualStrings(
        "00000000  48 65 6c 6c  6f 2c 20 57  6f 72 6c 64  21 0a 00 ff  |Hello, World!...|\n",
        out,
    );
    // meaningful substring checks
    try testing.expect(std.mem.startsWith(u8, out, "00000000  "));
    try testing.expect(std.mem.indexOf(u8, out, "48 65 6c 6c") != null);
    try testing.expect(std.mem.indexOf(u8, out, "|Hello, World!") != null);
    try testing.expect(std.mem.indexOf(u8, out, "..") != null);
}

test "printRow no color short last row" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const bytes = "Hi";
    try printRow(&aw.writer, 0x10, bytes, false);
    const out = aw.written();
    // exact full output check
    try testing.expectEqualStrings(
        "00000010  48 69                                               |Hi              |\n",
        out,
    );
    // meaningful substring checks
    try testing.expect(std.mem.startsWith(u8, out, "00000010  "));
    try testing.expect(std.mem.indexOf(u8, out, "|Hi") != null);
    try testing.expect(std.mem.endsWith(u8, out, "|\n"));
}

test "printRow color wraps bytes with escape codes" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const bytes = "\x00A"; // null byte (bright_black) + 'A' (green)
    try printRow(&aw.writer, 0, bytes, true);
    const out = aw.written();
    // Both escape code prefix and reset must appear
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null); // some escape code present
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null); // reset present
    // Hex values still present within the escape sequences
    try testing.expect(std.mem.indexOf(u8, out, "00") != null);
    try testing.expect(std.mem.indexOf(u8, out, "41") != null);
}
