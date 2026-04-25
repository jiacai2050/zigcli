//! zhexdump: color-coded hex dump of files or stdin, matching hexyl's output format.

const std = @import("std");
const assert = std.debug.assert;
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const term = zigcli.term;
const util = @import("util.zig");

const Options = struct {
    length: ?usize = null,
    skip: ?usize = null,
    @"no-color": bool = false,
    color: bool = false,
    @"no-squeezing": bool = false,
    @"print-color-table": bool = false,
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
        .color = "Force color output even when not a TTY.",
        .@"no-squeezing" = "Do not squeeze consecutive identical rows.",
        .@"print-color-table" = "Print a color reference table and exit.",
        .help = "Print help information.",
        .version = "Print version.",
    };
};

// hexyl uses \x1b[39m (default foreground reset) not \x1b[0m (full reset).
const color_reset = "\x1b[39m";

fn byteColor(byte: u8) term.Style.Color {
    return switch (byte) {
        0x00 => .bright_black,
        0x01...0x20, 0x7F => .green, // control chars, whitespace
        0x21...0x7E => .cyan,
        0x80...0xFF => .yellow,
    };
}

// Maps a byte to its hexyl-style character panel representation (Default table).
// Returns null for printable ASCII (0x21-0x7E): caller should write the byte directly.
fn byteChar(byte: u8) ?[]const u8 {
    return switch (byte) {
        0x00 => "⋄",
        0x20 => " ",
        0x09, 0x0A, 0x0C, 0x0D => "_", // Rust is_ascii_whitespace: tab, LF, FF, CR
        0x01...0x08, 0x0B, 0x0E...0x1F, 0x7F => "•",
        0x21...0x7E => null, // printable ASCII: write the byte itself
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

fn printColorTable(writer: *std.Io.Writer, use_color: bool) !void {
    try writer.writeAll("zhexdump color reference:\n\n");
    const Entry = struct { symbol: []const u8, color: term.Style.Color, label: []const u8 };
    const entries = [_]Entry{
        .{ .symbol = "⋄", .color = .bright_black, .label = "NULL bytes (0x00)" },
        .{ .symbol = "a", .color = .cyan, .label = "ASCII printable characters (0x21 - 0x7E)" },
        .{ .symbol = "_", .color = .green, .label = "ASCII whitespace (0x09 - 0x0D, 0x20)" },
        .{ .symbol = "•", .color = .green, .label = "ASCII control characters (except NULL and whitespace)" },
        .{ .symbol = "×", .color = .yellow, .label = "Non-ASCII bytes (0x80 - 0xFF)" },
    };
    for (entries) |e| {
        if (use_color) try writer.writeAll(e.color.toEscapeCode());
        try writer.writeAll(e.symbol);
        try writer.print(" {s}", .{e.label});
        if (use_color) try writer.writeAll(color_reset);
        try writer.writeAll("\n");
    }
}

// Returns true if the color for byte at index i differs from the previous byte in the panel.
// Always true at panel boundaries (i == 0, i == 8) so the first byte always sets its color.
fn colorChangedAt(bytes: []const u8, i: usize) bool {
    assert(i < bytes.len);
    if (i == 0 or i == 8) return true;
    return byteColor(bytes[i]) != byteColor(bytes[i - 1]);
}

// │00000000│ xx xx xx xx xx xx xx xx ┊ xx xx xx xx xx xx xx xx │charchar┊charchar│
fn printRow(
    writer: *std.Io.Writer,
    offset: u64,
    bytes: []const u8,
    use_color: bool,
) !void {
    assert(bytes.len > 0);
    assert(bytes.len <= 16);
    // Left border + offset.
    try writer.writeAll("│");
    if (use_color) try writer.writeAll(term.Style.Color.bright_black.toEscapeCode());
    try writer.print("{x:0>8}", .{offset});
    if (use_color) try writer.writeAll(color_reset);
    try writer.writeAll("│");

    // Hex panels: two panels of 8 bytes, separated by ┊.
    // hexyl optimization: emit color code only on color change, reset once per panel.
    for (0..16) |i| {
        if (i == 8) {
            // End of first panel: reset, then inner separator.
            if (use_color) try writer.writeAll(color_reset);
            try writer.writeAll(" ┊");
        }
        try writer.writeAll(" ");
        if (i < bytes.len) {
            const b = bytes[i];
            if (use_color and colorChangedAt(bytes, i))
                try writer.writeAll(byteColor(b).toEscapeCode());
            try writer.print("{x:0>2}", .{b});
        } else {
            try writer.writeAll("  ");
        }
    }
    // End of second panel: reset.
    if (use_color) try writer.writeAll(color_reset);
    try writer.writeAll(" ");

    // Separator before char panel.
    try writer.writeAll("│");

    // Char panels: two panels of 8 chars, separated by ┊.
    // Same optimization: color code only on change, reset once per panel.
    for (0..16) |i| {
        if (i == 8) {
            if (use_color) try writer.writeAll(color_reset);
            try writer.writeAll("┊");
        }
        if (i < bytes.len) {
            const b = bytes[i];
            if (use_color and colorChangedAt(bytes, i))
                try writer.writeAll(byteColor(b).toEscapeCode());
            if (byteChar(b)) |ch| {
                try writer.writeAll(ch);
            } else {
                try writer.writeByte(b);
            }
        } else {
            try writer.writeAll(" ");
        }
    }
    // End of second char panel: reset.
    if (use_color) try writer.writeAll(color_reset);

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
    const use_color = !options.@"no-color" and
        (options.color or term.isTty(std.Io.File.stdout()));

    if (options.@"print-color-table") {
        var stdout = std.Io.File.stdout();
        var writer_buf: [4096]u8 = undefined;
        var writer = stdout.writer(init.io, &writer_buf);
        try printColorTable(&writer.interface, use_color);
        try writer.interface.flush();
        return;
    }

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
    var prev_buf: [16]u8 = undefined;
    var prev_len: usize = 0;
    var offset: u64 = options.skip orelse 0;
    var total_read: usize = 0;
    var has_output = false;
    var squeezing = false;

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

        // Squeezing: collapse consecutive identical full rows into │*       │
        const is_full_row = n == 16;
        const is_repeat = !options.@"no-squeezing" and
            is_full_row and prev_len == 16 and
            std.mem.eql(u8, row_buf[0..16], prev_buf[0..16]);

        if (is_repeat) {
            if (!squeezing) {
                if (use_color) {
                    try writer.interface.writeAll("│" ++ "\x1b[90m" ++ "*" ++ "\x1b[39m" ++
                        "       │                        " ++ "\x1b[39m" ++
                        " ┊                        " ++ "\x1b[39m" ++
                        " │        " ++ "\x1b[39m" ++
                        "┊        " ++ "\x1b[39m" ++ "│\n");
                } else {
                    try writer.interface.writeAll("│*       │                         ┊                         │        ┊        │\n");
                }
                squeezing = true;
            }
        } else {
            squeezing = false;
            try printRow(&writer.interface, offset, row_buf[0..n], use_color);
        }

        @memcpy(prev_buf[0..n], row_buf[0..n]);
        prev_len = n;
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
    try testing.expectEqualStrings("⋄", byteChar(0x00).?);
    try testing.expectEqualStrings(" ", byteChar(0x20).?);
    try testing.expectEqualStrings("_", byteChar(0x0A).?);
    try testing.expectEqualStrings("_", byteChar(0x09).?);
    try testing.expectEqualStrings("_", byteChar(0x0C).?); // form feed
    try testing.expectEqualStrings("•", byteChar(0x01).?);
    try testing.expectEqualStrings("•", byteChar(0x7F).?);
    try testing.expect(byteChar(0x41) == null); // 'A' — printable, write byte directly
    try testing.expectEqualStrings("×", byteChar(0x80).?);
    try testing.expectEqualStrings("×", byteChar(0xFF).?);
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
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[39m") != null); // fg reset
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
