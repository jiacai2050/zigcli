const std = @import("std");
const Writer = std.io.Writer;

pub const String = []const u8;
pub fn Row(comptime num: usize) type {
    return [num]String;
}

/// Text alignment within a table column.
pub const Align = enum {
    left,
    center,
    right,
};

/// ANSI terminal foreground color for a table cell.
pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    // Bright (high-intensity) variants
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    /// The ANSI SGR reset sequence that cancels all styling.
    pub const reset = "\x1b[0m";

    /// Returns the ANSI escape sequence that activates this foreground color.
    pub fn toEscapeCode(self: Color) []const u8 {
        return switch (self) {
            .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .white => "\x1b[37m",
            .bright_black => "\x1b[90m",
            .bright_red => "\x1b[91m",
            .bright_green => "\x1b[92m",
            .bright_yellow => "\x1b[93m",
            .bright_blue => "\x1b[94m",
            .bright_magenta => "\x1b[95m",
            .bright_cyan => "\x1b[96m",
            .bright_white => "\x1b[97m",
        };
    }
};

pub const Separator = struct {
    pub const Mode = enum {
        ascii,
        box,
        dos,
    };

    const box = [_][4]String{
        .{ "┌", "─", "┬", "┐" },
        .{ "│", "─", "│", "│" },
        .{ "├", "─", "┼", "┤" },
        .{ "└", "─", "┴", "┘" },
    };

    const ascii = [_][4]String{
        .{ "+", "-", "+", "+" },
        .{ "|", "-", "|", "|" },
        .{ "+", "-", "+", "+" },
        .{ "+", "-", "+", "+" },
    };

    const dos = [_][4]String{
        .{ "╔", "═", "╦", "╗" },
        .{ "║", "═", "║", "║" },
        .{ "╠", "═", "╬", "╣" },
        .{ "╚", "═", "╩", "╝" },
    };

    const Position = enum { First, Text, Sep, Last };

    fn get(mode: Mode, row_pos: Position, col_pos: Position) []const u8 {
        const sep_table = switch (mode) {
            .ascii => ascii,
            .box => box,
            .dos => dos,
        };

        return sep_table[@intFromEnum(row_pos)][@intFromEnum(col_pos)];
    }
};

pub fn Table(comptime len: usize) type {
    return struct {
        header: ?Row(len) = null,
        footer: ?Row(len) = null,
        rows: []const Row(len),
        mode: Separator.Mode = .ascii,
        /// Number of spaces added to both the left and right side of each cell's content.
        padding: usize = 0,
        /// Per-column text alignment; defaults to left-alignment for all columns.
        column_align: [len]Align = [_]Align{.left} ** len,
        /// When true, a separator line is printed between every pair of adjacent data rows.
        row_separator: bool = false,
        /// Per-cell foreground colors for data rows.
        /// When non-null, length must equal `rows.len`.
        /// A null entry means no color is applied to that cell.
        cell_colors: ?[]const [len]?Color = null,
        /// Foreground colors for the header row (one per column, null = no color).
        header_color: ?[len]?Color = null,
        /// Foreground colors for the footer row (one per column, null = no color).
        footer_color: ?[len]?Color = null,

        const Self = @This();

        fn writeRowDelimiter(self: Self, writer: *Writer, row_pos: Separator.Position, col_lens: [len]usize) !void {
            inline for (0..len, col_lens) |col_idx, max_len| {
                const first_col = col_idx == 0;
                if (first_col) {
                    try writer.writeAll(Separator.get(self.mode, row_pos, .First));
                } else {
                    try writer.writeAll(Separator.get(self.mode, row_pos, .Sep));
                }

                for (0..max_len) |_| {
                    try writer.writeAll(Separator.get(self.mode, row_pos, .Text));
                }
            }

            try writer.writeAll(Separator.get(self.mode, row_pos, .Last));
            try writer.writeAll("\n");
        }

        fn writeRow(
            self: Self,
            writer: *Writer,
            row: []const String,
            col_lens: [len]usize,
            colors: ?[len]?Color,
        ) !void {
            const m = self.mode;
            for (row, col_lens, 0..) |column, col_len, col_idx| {
                const first_col = col_idx == 0;
                if (first_col) {
                    try writer.writeAll(Separator.get(m, .Text, .First));
                } else {
                    try writer.writeAll(Separator.get(m, .Text, .Sep));
                }

                // col_len = max_content_len + 2 * padding
                const content_space = col_len - 2 * self.padding;
                const remaining = content_space - column.len;

                const left_spaces: usize = switch (self.column_align[col_idx]) {
                    .left => self.padding,
                    .right => self.padding + remaining,
                    .center => self.padding + remaining / 2,
                };
                const right_spaces: usize = col_len - left_spaces - column.len;

                for (0..left_spaces) |_| {
                    try writer.writeAll(" ");
                }
                // Apply foreground color around the text content only (not padding),
                // so that column-width arithmetic is unaffected.
                const cell_color: ?Color = if (colors) |cs| cs[col_idx] else null;
                if (cell_color) |c| {
                    try writer.writeAll(c.toEscapeCode());
                }
                try writer.writeAll(column);
                if (cell_color != null) {
                    try writer.writeAll(Color.reset);
                }
                for (0..right_spaces) |_| {
                    try writer.writeAll(" ");
                }
            }
            try writer.writeAll(Separator.get(m, .Text, .Last));
            try writer.writeAll("\n");
        }

        fn calculateColumnLens(self: Self) [len]usize {
            var lens = std.mem.zeroes([len]usize);
            if (self.header) |header| {
                for (header, &lens) |column, *n| {
                    n.* = column.len;
                }
            }

            for (self.rows) |row| {
                for (row, &lens) |col, *n| {
                    n.* = @max(col.len, n.*);
                }
            }

            if (self.footer) |footer| {
                for (footer, &lens) |col, *n| {
                    n.* = @max(col.len, n.*);
                }
            }

            for (&lens) |*n| {
                // Each column is widened by padding on both left and right sides.
                n.* += self.padding * 2;
            }
            return lens;
        }

        pub fn format(
            self: Self,
            writer: *std.Io.Writer,
        ) !void {
            if (self.cell_colors) |cc| {
                std.debug.assert(cc.len == self.rows.len);
            }
            const column_lens = self.calculateColumnLens();

            try self.writeRowDelimiter(writer, .First, column_lens);
            if (self.header) |header| {
                try self.writeRow(
                    writer,
                    &header,
                    column_lens,
                    self.header_color,
                );
            }

            try self.writeRowDelimiter(writer, .Sep, column_lens);
            for (self.rows, 0..) |row, i| {
                const colors: ?[len]?Color = if (self.cell_colors) |cc| cc[i] else null;
                try self.writeRow(writer, &row, column_lens, colors);
                if (self.row_separator and i + 1 < self.rows.len) {
                    try self.writeRowDelimiter(writer, .Sep, column_lens);
                }
            }

            if (self.footer) |footer| {
                try self.writeRowDelimiter(writer, .Sep, column_lens);
                try self.writeRow(writer, &footer, column_lens, self.footer_color);
            }

            try self.writeRowDelimiter(writer, .Last, column_lens);
        }
    };
}

test "normal usage" {
    const t = Table(2){
        .header = [_]String{ "Version", "Date" },
        .rows = &[_][2]String{
            .{ "0.7.1", "2020-12-13" },
            .{ "0.7.0", "2020-11-08" },
            .{ "0.6.0", "2020-04-13" },
            .{ "0.5.0", "2019-09-30" },
        },
        .footer = null,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    try std.testing.expectEqualStrings(
        \\+-------+----------+
        \\|Version|Date      |
        \\+-------+----------+
        \\|0.7.1  |2020-12-13|
        \\|0.7.0  |2020-11-08|
        \\|0.6.0  |2020-04-13|
        \\|0.5.0  |2019-09-30|
        \\+-------+----------+
        \\
    , out.items);
}

test "footer usage" {
    const t = Table(2){
        .header = [_]String{ "Language", "Files" },
        .rows = &[_][2]String{
            .{ "Zig", "3" },
            .{ "Python", "2" },
        },
        .footer = [2]String{ "Total", "5" },
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    try std.testing.expectEqualStrings(
        \\+--------+-----+
        \\|Language|Files|
        \\+--------+-----+
        \\|Zig     |3    |
        \\|Python  |2    |
        \\+--------+-----+
        \\|Total   |5    |
        \\+--------+-----+
        \\
    , out.items);
}

test "right alignment with padding" {
    const t = Table(2){
        .header = [_]String{ "Name", "Score" },
        .rows = &[_][2]String{
            .{ "Alice", "10" },
            .{ "Bob", "200" },
        },
        .column_align = .{ .left, .right },
        .padding = 1,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    try std.testing.expectEqualStrings(
        \\+-------+-------+
        \\| Name  | Score |
        \\+-------+-------+
        \\| Alice |    10 |
        \\| Bob   |   200 |
        \\+-------+-------+
        \\
    , out.items);
}

test "center alignment" {
    const t = Table(3){
        .header = [_]String{ "A", "B", "C" },
        .rows = &[_][3]String{
            .{ "x", "yy", "zzz" },
        },
        .column_align = .{ .center, .center, .center },
        .padding = 1,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    try std.testing.expectEqualStrings(
        \\+---+----+-----+
        \\| A | B  |  C  |
        \\+---+----+-----+
        \\| x | yy | zzz |
        \\+---+----+-----+
        \\
    , out.items);
}

test "row separator" {
    const t = Table(2){
        .header = [_]String{ "K", "V" },
        .rows = &[_][2]String{
            .{ "a", "1" },
            .{ "b", "2" },
            .{ "c", "3" },
        },
        .row_separator = true,
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    try std.testing.expectEqualStrings(
        \\+-+-+
        \\|K|V|
        \\+-+-+
        \\|a|1|
        \\+-+-+
        \\|b|2|
        \\+-+-+
        \\|c|3|
        \\+-+-+
        \\
    , out.items);
}

test "cell colors produce ANSI escape codes" {
    const t = Table(2){
        .header = [_]String{ "Status", "Value" },
        .rows = &[_][2]String{
            .{ "OK", "100" },
            .{ "FAIL", "0" },
        },
        .cell_colors = &[_][2]?Color{
            .{ .green, null },
            .{ .red, null },
        },
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    // Borders and column widths are unchanged by color escapes.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "+------+-----+") != null);
    // Green escape code wraps "OK", red escape code wraps "FAIL".
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[32mOK\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[31mFAIL\x1b[0m") != null);
    // Uncolored cells ("100", "0") do not have any escape codes.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[32m100") == null);
}

test "header and footer colors" {
    const t = Table(2){
        .header = [_]String{ "Name", "Score" },
        .rows = &[_][2]String{
            .{ "Alice", "95" },
        },
        .footer = [2]String{ "Total", "95" },
        .header_color = [2]?Color{ .bright_cyan, .bright_cyan },
        .footer_color = [2]?Color{ .yellow, .yellow },
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    // Header cells are wrapped with bright cyan.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[96mName\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[96mScore\x1b[0m") != null);
    // Footer cells are wrapped with yellow.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[33mTotal\x1b[0m") != null);
    // Data row has no color escape codes.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[" ++ "mAlice") == null);
}
