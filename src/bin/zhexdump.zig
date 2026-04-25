//! zhexdump: color-coded hex dump of files or stdin, matching hexyl's output format.

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
        0x09, 0x0A, 0x0D, 0x20 => .green,
        0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => .green,
        0x21...0x7E => .cyan,
        0x80...0xFF => .yellow,
    };
}

// Maps a byte to its hexyl-style character panel representation (Default table).
fn byteChar(byte: u8) []const u8 {
    return switch (byte) {
        0x00 => "⋄",
        0x20 => " ",
        0x09, 0x0A, 0x0D => "_",
        0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => "•",
        0x21...0x7E => &[_]u8{byte},
        0x80...0xFF => "×",
    };
}

// ┌────────┬─────────────────────────┬─────────────────────────┬────────┬────────┐
fn printHeader(writer: *std.Io.Writer) !void {
    try writer.writeAll("┌────────┬─────────────────────────┬─────────────────────────┬────────┬────────┐\n");
}

// └────────┴─────────────────────────┴─────────────────────────┴────────┴────────┘
fn printFooter(writer: *std.Io.Writer) !void {
    try writer.writeAll("└────────┴─────────────────────────┴─────────────────────────┴────────┴────────┘\n");
}

// │00000000│ xx xx xx xx xx xx xx xx ┊ xx xx xx xx xx xx xx xx │charchar┊charchar│
fn printRow(
    writer: *std.Io.Writer,
    offset: u64,
    bytes: []const u8,
    use_color: bool,
) !void {
    // Left border + offset.
    try writer.writeAll("│");
    if (use_color) try writer.writeAll(term.Style.Color.bright_black.toEscapeCode());
    try writer.print("{x:0>8}", .{offset});
    if (use_color) try writer.writeAll(term.Style.Color.reset);
    try writer.writeAll("│");

    // Hex panels: two panels of 8 bytes, separated by ┊.
    for (0..16) |i| {
        if (i == 8) {
            // Inner separator between the two 8-byte panels.
            try writer.writeAll(" ┊");
        }
        try writer.writeAll(" ");
        if (i < bytes.len) {
            const b = bytes[i];
            if (use_color) {
                try writer.writeAll(byteColor(b).toEscapeCode());
                try writer.print("{x:0>2}", .{b});
                try writer.writeAll(term.Style.Color.reset);
            } else {
                try writer.print("{x:0>2}", .{b});
            }
        } else {
            try writer.writeAll("  ");
        }
    }
    try writer.writeAll(" ");

    // Separator before char panel.
    try writer.writeAll("│");

    // Char panels: two panels of 8 chars, separated by ┊.
    for (0..16) |i| {
        if (i == 8) try writer.writeAll("┊");
        if (i < bytes.len) {
            const b = bytes[i];
            const ch = byteChar(b);
            if (use_color) {
                try writer.writeAll(byteColor(b).toEscapeCode());
                try writer.writeAll(ch);
                try writer.writeAll(term.Style.Color.reset);
            } else {
                try writer.writeAll(ch);
            }
        } else {
            try writer.writeAll(" ");
        }
    }

    // Right border.
    try writer.writeAll("│\n");
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

    const options = opt.options;
    const use_color = !options.@"no-color" and term.isTty(std.Io.File.stdout());

    // Open input: file arg or stdin.
    var file: std.Io.File = if (opt.positional_arguments.len > 0) blk: {
        break :blk try std.Io.Dir.cwd().openFile(
            init.io,
            opt.positional_arguments[0],
            .{},
        );
    } else std.Io.File.stdin();
    defer if (opt.positional_arguments.len > 0) file.close(init.io);

    var reader_buf: [4096]u8 = undefined;
    var reader = file.reader(init.io, &reader_buf);

    // Apply --skip by consuming and discarding bytes.
    if (options.skip) |skip| {
        _ = try reader.interface.discardShort(skip);
    }

    const max_bytes: ?usize = options.length;

    var stdout = std.Io.File.stdout();
    var writer_buf: [4096]u8 = undefined;
    var writer = stdout.writer(init.io, &writer_buf);

    var row_buf: [16]u8 = undefined;
    var offset: u64 = options.skip orelse 0;
    var total_read: usize = 0;
    var has_output = false;

    while (true) {
        const remaining = if (max_bytes) |max| max - total_read else 16;
        if (remaining == 0) break;
        const to_read = @min(16, remaining);
        const n = try reader.interface.readSliceShort(row_buf[0..to_read]);
        if (n == 0) break;
        if (!has_output) {
            try printHeader(&writer.interface);
            has_output = true;
        }
        try printRow(&writer.interface, offset, row_buf[0..n], use_color);
        offset += n;
        total_read += n;
    }
    if (has_output) try printFooter(&writer.interface);
    try writer.interface.flush();
}

const testing = std.testing;

test "byteColor null byte" {
    try testing.expectEqual(term.Style.Color.bright_black, byteColor(0x00));
}

test "byteColor FF byte" {
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0xFF));
}

test "byteColor whitespace" {
    try testing.expectEqual(term.Style.Color.green, byteColor(0x0A)); // newline
    try testing.expectEqual(term.Style.Color.green, byteColor(0x20)); // space
    try testing.expectEqual(term.Style.Color.green, byteColor(0x09)); // tab
    try testing.expectEqual(term.Style.Color.green, byteColor(0x0D)); // CR
}

test "byteColor control chars" {
    try testing.expectEqual(term.Style.Color.green, byteColor(0x01));
    try testing.expectEqual(term.Style.Color.green, byteColor(0x7F)); // DEL
}

test "byteColor printable ASCII" {
    try testing.expectEqual(term.Style.Color.cyan, byteColor(0x21)); // '!'
    try testing.expectEqual(term.Style.Color.cyan, byteColor(0x41)); // 'A'
    try testing.expectEqual(term.Style.Color.cyan, byteColor(0x50)); // 'P'
    try testing.expectEqual(term.Style.Color.cyan, byteColor(0x7E)); // '~'
}

test "byteColor high bytes" {
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0x80));
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0xBF));
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0xC0));
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0xEF));
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0xF0));
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0xFE));
}

test "byteChar categories" {
    try testing.expectEqualStrings("⋄", byteChar(0x00));
    try testing.expectEqualStrings(" ", byteChar(0x20));
    try testing.expectEqualStrings("_", byteChar(0x0A));
    try testing.expectEqualStrings("_", byteChar(0x09));
    try testing.expectEqualStrings("•", byteChar(0x01));
    try testing.expectEqualStrings("•", byteChar(0x7F));
    try testing.expectEqualStrings("A", byteChar(0x41));
    try testing.expectEqualStrings("×", byteChar(0x80));
    try testing.expectEqualStrings("×", byteChar(0xFF));
}

test "printRow no color simple" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const bytes = "Hello, World!\n\x00\xff";
    try printRow(&aw.writer, 0, bytes, false);
    const out = aw.written();
    try testing.expect(std.mem.startsWith(u8, out, "│00000000│"));
    try testing.expect(std.mem.indexOf(u8, out, "48 65 6c 6c") != null);
    try testing.expect(std.mem.indexOf(u8, out, "┊") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Hello, W") != null); // split across ┊
    try testing.expect(std.mem.indexOf(u8, out, "orld!_") != null);
    try testing.expect(std.mem.indexOf(u8, out, "⋄") != null); // null byte
    try testing.expect(std.mem.indexOf(u8, out, "×") != null); // 0xff
    try testing.expect(std.mem.indexOf(u8, out, "_") != null); // newline
}

test "printRow no color short last row" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const bytes = "Hi";
    try printRow(&aw.writer, 0x10, bytes, false);
    const out = aw.written();
    try testing.expect(std.mem.startsWith(u8, out, "│00000010│"));
    try testing.expect(std.mem.indexOf(u8, out, "Hi") != null);
    try testing.expect(std.mem.endsWith(u8, out, "│\n"));
}

test "printRow color wraps bytes with escape codes" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const bytes = "\x00A"; // null byte (bright_black) + 'A' (cyan)
    try printRow(&aw.writer, 0, bytes, true);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "00") != null);
    try testing.expect(std.mem.indexOf(u8, out, "41") != null);
}

test "printHeader" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try printHeader(&aw.writer);
    try testing.expect(std.mem.startsWith(u8, aw.written(), "┌────────┬"));
}

test "printFooter" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try printFooter(&aw.writer);
    try testing.expect(std.mem.startsWith(u8, aw.written(), "└────────┴"));
}
