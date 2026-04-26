//! hexdump: color-coded hex dump of files or stdin.
//!
//! Bytes are colored by semantic category:
//!   bright_black — null (0x00)
//!   green        — ASCII control chars and whitespace (0x01-0x20, 0x7F)
//!   cyan         — printable ASCII (0x21-0x7E)
//!   yellow       — non-ASCII (0x80-0xFF)

const std = @import("std");
const assert = std.debug.assert;
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const term = zigcli.term;
const util = @import("util.zig");

const ColorMode = enum { always, auto, never };

const Options = struct {
    length: ?usize = null,
    skip: ?usize = null,
    color: ColorMode = .auto,
    @"no-squeezing": bool = false,
    @"print-color-table": bool = false,
    include: bool = false,
    help: bool = false,
    version: bool = false,

    pub const __shorts__ = .{
        .length = .n,
        .skip = .s,
        .include = .i,
        .help = .h,
        .version = .v,
    };

    pub const __messages__ = .{
        .length = "Only read N bytes.",
        .skip = "Skip N bytes from the start.",
        .color = "When to use colors: always, auto, never. Default: auto.",
        .@"no-squeezing" = "Do not squeeze consecutive identical rows.",
        .@"print-color-table" = "Print a color reference table and exit.",
        .include = "Output a C include file (like xxd -i).",
        .help = "Print help information.",
        .version = "Print version.",
    };
};

// Use default foreground reset (\x1b[39m) rather than full reset (\x1b[0m)
// so that background colors set by the terminal theme are preserved.
const color_reset = "\x1b[39m";

fn byteColor(byte: u8) term.Style.Color {
    return switch (byte) {
        0x00 => .bright_black,
        0x01...0x20, 0x7F => .green,
        0x21...0x7E => .cyan,
        0x80...0xFF => .yellow,
    };
}

// Maps a byte to its character panel symbol, following hexyl's Default character table.
// Returns null for printable ASCII (0x21-0x7E): caller writes the byte directly to
// avoid returning a slice pointing to a local variable (dangling reference).
//   ⋄  (U+22C4) — null byte
//   ' '          — space, rendered as-is to keep the panel visually aligned
//   _            — ASCII whitespace: tab/LF/FF/CR (0x09, 0x0A, 0x0C, 0x0D)
//   •  (U+2022) — other ASCII control characters
//   ×  (U+00D7) — non-ASCII bytes
fn byteChar(byte: u8) ?[]const u8 {
    return switch (byte) {
        0x00 => "⋄",
        0x20 => " ",
        0x09, 0x0A, 0x0C, 0x0D => "_",
        0x01...0x08, 0x0B, 0x0E...0x1F, 0x7F => "•",
        0x21...0x7E => null,
        0x80...0xFF => "×",
    };
}

// Converts a filename (e.g. "11.jpeg") to a valid C identifier (e.g. "_11_jpeg").
fn filenameToCIdent(buf: []u8, name: []const u8) []u8 {
    var len: usize = 0;
    for (name) |c| {
        const out: u8 = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => c,
            else => '_',
        };
        if (len < buf.len) {
            buf[len] = out;
            len += 1;
        }
    }
    return buf[0..len];
}

fn printInclude(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    var_name: []const u8,
    max_bytes: ?usize,
) !usize {
    // Read all bytes first so we know the total and can omit the trailing comma.
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    defer bytes.deinit(gpa);
    var read_buf: [4096]u8 = undefined;
    while (true) {
        const remaining = if (max_bytes) |max| max - bytes.items.len else read_buf.len;
        if (remaining == 0) break;
        const n = try reader.readSliceShort(read_buf[0..@min(read_buf.len, remaining)]);
        if (n == 0) break;
        try bytes.appendSlice(gpa, read_buf[0..n]);
    }

    const data = bytes.items;
    try writer.print("unsigned char {s}[] = {{\n", .{var_name});
    for (data, 0..) |b, i| {
        if (i % 12 == 0) try writer.writeAll("  ");
        try writer.print("0x{x:0>2}", .{b});
        if (i + 1 < data.len) {
            try writer.writeAll(",");
            if (i % 12 == 11) try writer.writeAll("\n") else try writer.writeAll(" ");
        }
    }
    if (data.len > 0) try writer.writeAll("\n");
    try writer.writeAll("};\n");
    try writer.print("unsigned int {s}_len = {d};\n", .{ var_name, data.len });
    return data.len;
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
        if (use_color) try writer.print("{f}", .{e.color});
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
    if (use_color) try writer.print("{f}", .{term.Style.Color.bright_black});
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
                try writer.print("{f}", .{byteColor(b)});
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
                try writer.print("{f}", .{byteColor(b)});
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
    return run(init) catch |err| switch (err) {
        error.WriteFailed => {}, // broken pipe (e.g. piped to head)
        else => return err,
    };
}

fn run(init: std.process.Init) anyerror!void {
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
    const use_color = switch (options.color) {
        .always => true,
        .never => false,
        .auto => term.isTty(std.Io.File.stdout()),
    };

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
        var skipped: usize = 0;
        while (skipped < skip) {
            const amt = try reader.interface.discardShort(skip - skipped);
            if (amt == 0) break;
            skipped += amt;
        }
    }

    const max_bytes: ?usize = options.length;

    var stdout = std.Io.File.stdout();
    var writer_buf: [4096]u8 = undefined;
    var writer = stdout.writer(init.io, &writer_buf);

    if (options.include) {
        var ident_buf: [256]u8 = undefined;
        const raw_name = if (opt.positional_arguments.len > 0)
            std.fs.path.basename(opt.positional_arguments[0])
        else
            "data";
        const var_name = filenameToCIdent(&ident_buf, raw_name);
        _ = try printInclude(allocator, &reader.interface, &writer.interface, var_name, max_bytes);
        try writer.interface.flush();
        return;
    }

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
                    try writer.interface.writeAll(
                        "│" ++ "\x1b[90m" ++ "*" ++ "\x1b[39m" ++ " " ** 7 ++ // offset (8)
                            "│" ++ " " ** 25 ++ "┊" ++ " " ** 25 ++ // hex panels (25+┊+25)
                            "│" ++ " " ** 8 ++ "┊" ++ " " ** 8 ++ // char panels (8+┊+8)
                            "│\n",
                    );
                } else {
                    try writer.interface.writeAll(
                        "│" ++ "*" ++ " " ** 7 ++ // offset (8)
                            "│" ++ " " ** 25 ++ "┊" ++ " " ** 25 ++ // hex panels (25+┊+25)
                            "│" ++ " " ** 8 ++ "┊" ++ " " ** 8 ++ // char panels (8+┊+8)
                            "│\n",
                    );
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

test "printRow no color full row" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // "Hello, World!\n\x00\xff" is exactly 16 bytes.
    try printRow(&aw.writer, 0, "Hello, World!\n\x00\xff", false);
    try testing.expectEqualStrings(
        "│00000000│ 48 65 6c 6c 6f 2c 20 57 ┊ 6f 72 6c 64 21 0a 00 ff │Hello, W┊orld!_⋄×│\n",
        aw.written(),
    );
}

test "printRow no color short last row" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try printRow(&aw.writer, 0x10, "Hi", false);
    try testing.expectEqualStrings(
        "│00000010│ 48 69                   ┊                         │Hi      ┊        │\n",
        aw.written(),
    );
}

test "printRow color full row" {
    // \x00 (bright_black=\x1b[90m) + 'A' (cyan=\x1b[36m), rest padding.
    // Colors only emitted on change; each panel resets with \x1b[39m at its end.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try printRow(&aw.writer, 0, "\x00A", true);
    try testing.expectEqualStrings(
        "│\x1b[90m00000000\x1b[39m│" ++
            " \x1b[90m00 \x1b[36m41                  \x1b[39m" ++
            " ┊                        \x1b[39m" ++
            " │\x1b[90m⋄\x1b[36mA      \x1b[39m┊        \x1b[39m│\n",
        aw.written(),
    );
}

test "printHeader" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try printHeader(&aw.writer);
    try testing.expectEqualStrings(
        "┌────────┬─────────────────────────┬─────────────────────────┬────────┬────────┐\n",
        aw.written(),
    );
}

test "printFooter" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try printFooter(&aw.writer);
    try testing.expectEqualStrings(
        "└────────┴─────────────────────────┴─────────────────────────┴────────┴────────┘\n",
        aw.written(),
    );
}
