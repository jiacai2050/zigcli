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
                try writer.writeAll(column);
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
            const column_lens = self.calculateColumnLens();

            try self.writeRowDelimiter(writer, .First, column_lens);
            if (self.header) |header| {
                try self.writeRow(
                    writer,
                    &header,
                    column_lens,
                );
            }

            try self.writeRowDelimiter(writer, .Sep, column_lens);
            for (self.rows, 0..) |row, i| {
                try self.writeRow(writer, &row, column_lens);
                if (self.row_separator and i + 1 < self.rows.len) {
                    try self.writeRowDelimiter(writer, .Sep, column_lens);
                }
            }

            if (self.footer) |footer| {
                try self.writeRowDelimiter(writer, .Sep, column_lens);
                try self.writeRow(writer, &footer, column_lens);
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
