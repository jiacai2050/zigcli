const std = @import("std");
const Writer = std.io.Writer;

pub const String = []const u8;

/// A table cell with optional per-cell ANSI styling and column spanning.
pub const Cell = struct {
    text: String,
    bold: bool = false,
    italic: bool = false,
    /// Foreground (text) color.
    fg: ?Color = null,
    /// Background color.
    bg: ?Color = null,
    /// Number of columns this cell spans (must be ≥ 1).
    hspan: usize = 1,

    /// Creates a plain cell containing `text`.
    pub fn init(text: String) Cell {
        return .{ .text = text };
    }

    /// Creates an empty placeholder cell for positions consumed by a spanning cell.
    pub fn span() Cell {
        return .{ .text = "" };
    }

    /// Returns a copy of this cell with bold text enabled.
    pub fn withBold(self: Cell) Cell {
        var cell = self;
        cell.bold = true;
        return cell;
    }

    /// Returns a copy of this cell with italic text enabled.
    pub fn withItalic(self: Cell) Cell {
        var cell = self;
        cell.italic = true;
        return cell;
    }

    /// Returns a copy of this cell with the given foreground color.
    pub fn withFg(self: Cell, fg_color: Color) Cell {
        var cell = self;
        cell.fg = fg_color;
        return cell;
    }

    /// Returns a copy of this cell with the given background color.
    pub fn withBg(self: Cell, bg_color: Color) Cell {
        var cell = self;
        cell.bg = bg_color;
        return cell;
    }

    /// Returns a copy of this cell that spans `column_count` columns (must be ≥ 1).
    /// Fill the following `column_count - 1` positions in the row with `Cell.span()`.
    pub fn withHspan(self: Cell, column_count: usize) Cell {
        std.debug.assert(column_count >= 1);
        var cell = self;
        cell.hspan = column_count;
        return cell;
    }
};

pub fn Row(comptime num: usize) type {
    return [num]Cell;
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
    // Bright (high-intensity) variants.
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

    /// Returns the ANSI escape sequence that activates this background color.
    pub fn toBgEscapeCode(self: Color) []const u8 {
        return switch (self) {
            .black => "\x1b[40m",
            .red => "\x1b[41m",
            .green => "\x1b[42m",
            .yellow => "\x1b[43m",
            .blue => "\x1b[44m",
            .magenta => "\x1b[45m",
            .cyan => "\x1b[46m",
            .white => "\x1b[47m",
            .bright_black => "\x1b[100m",
            .bright_red => "\x1b[101m",
            .bright_green => "\x1b[102m",
            .bright_yellow => "\x1b[103m",
            .bright_blue => "\x1b[104m",
            .bright_magenta => "\x1b[105m",
            .bright_cyan => "\x1b[106m",
            .bright_white => "\x1b[107m",
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

    pub const Position = enum { First, Text, Sep, Last };

    pub fn get(mode: Mode, row_pos: Position, col_pos: Position) []const u8 {
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

        fn writeRowDelimiter(
            self: Self,
            writer: *Writer,
            row_pos: Separator.Position,
            col_lens: [len]usize,
        ) !void {
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
            row: []const Cell,
            col_lens: [len]usize,
        ) !void {
            // Track which column positions are absorbed by a spanning cell.
            var covered = [_]bool{false} ** len;

            for (row, 0..) |cell, col_idx| {
                if (covered[col_idx]) continue;

                // Clamp the span to the remaining columns in the row.
                const effective_span = @min(cell.hspan, len - col_idx);

                // Mark the columns consumed by this span (beyond the first).
                for (1..effective_span) |offset| covered[col_idx + offset] = true;

                const first_col = col_idx == 0;
                if (first_col) {
                    try writer.writeAll(Separator.get(self.mode, .Text, .First));
                } else {
                    try writer.writeAll(Separator.get(self.mode, .Text, .Sep));
                }

                // Combined visual width: sum of spanned column widths plus the
                // absorbed separator characters between them.
                var cell_width = col_lens[col_idx];
                for (1..effective_span) |offset| cell_width += 1 + col_lens[col_idx + offset];

                const text = cell.text;
                const content_space = if (cell_width >= 2 * self.padding)
                    cell_width - 2 * self.padding
                else
                    0;
                const remaining = if (content_space >= text.len) content_space - text.len else 0;

                const left_spaces: usize = switch (self.column_align[col_idx]) {
                    .left => self.padding,
                    .right => self.padding + remaining,
                    .center => self.padding + @divFloor(remaining, 2),
                };
                const right_spaces: usize = if (cell_width >= left_spaces + text.len)
                    cell_width - left_spaces - text.len
                else
                    0;

                for (0..left_spaces) |_| try writer.writeAll(" ");

                // Emit ANSI styling codes before the text content.
                if (cell.bold) try writer.writeAll("\x1b[1m");
                if (cell.italic) try writer.writeAll("\x1b[3m");
                if (cell.fg) |fg_color| try writer.writeAll(fg_color.toEscapeCode());
                if (cell.bg) |bg_color| try writer.writeAll(bg_color.toBgEscapeCode());
                try writer.writeAll(text);
                if (cell.bold or cell.italic or cell.fg != null or cell.bg != null) {
                    try writer.writeAll(Color.reset);
                }

                for (0..right_spaces) |_| try writer.writeAll(" ");
            }
            try writer.writeAll(Separator.get(self.mode, .Text, .Last));
            try writer.writeAll("\n");
        }

        fn calculateColumnLens(self: Self) [len]usize {
            var lens = std.mem.zeroes([len]usize);

            const RowOps = struct {
                // First pass: contribute text widths for non-spanning cells.
                fn accumulateNonSpanning(
                    row: []const Cell,
                    col_lens: []usize,
                    padding: usize,
                ) void {
                    for (row, 0..) |cell, col_idx| {
                        if (cell.hspan == 1) {
                            col_lens[col_idx] = @max(
                                cell.text.len + 2 * padding,
                                col_lens[col_idx],
                            );
                        }
                    }
                }
                // Second pass: expand the last spanned column so that spanning
                // cells fit within their allocated width.
                fn expandSpanning(
                    row: []const Cell,
                    col_lens: []usize,
                    end: usize,
                    padding: usize,
                ) void {
                    for (row, 0..) |cell, start_col| {
                        if (cell.hspan <= 1 or start_col >= end) continue;
                        const effective_span = @min(cell.hspan, end - start_col);
                        // Available space = combined widths of spanned columns
                        // plus the separator characters between them.
                        var available: usize = 0;
                        for (start_col..start_col + effective_span) |col| {
                            available += col_lens[col];
                        }
                        available += effective_span - 1;
                        const needed = cell.text.len + 2 * padding;
                        if (needed > available) {
                            col_lens[start_col + effective_span - 1] += needed - available;
                        }
                    }
                }
            };

            if (self.header) |header| RowOps.accumulateNonSpanning(&header, &lens, self.padding);
            for (self.rows) |row| RowOps.accumulateNonSpanning(&row, &lens, self.padding);
            if (self.footer) |footer| RowOps.accumulateNonSpanning(&footer, &lens, self.padding);

            if (self.header) |header| RowOps.expandSpanning(&header, &lens, len, self.padding);
            for (self.rows) |row| RowOps.expandSpanning(&row, &lens, len, self.padding);
            if (self.footer) |footer| RowOps.expandSpanning(&footer, &lens, len, self.padding);

            return lens;
        }

        pub fn format(
            self: Self,
            writer: *std.Io.Writer,
        ) !void {
            const column_lens = self.calculateColumnLens();

            try self.writeRowDelimiter(writer, .First, column_lens);
            if (self.header) |header| {
                try self.writeRow(writer, &header, column_lens);
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

/// Runtime table builder with dynamic rows. Column count is still comptime-fixed
/// for type safety. Renders by delegating to `Table(len)`.
pub fn TableBuilder(comptime len: usize) type {
    return struct {
        rows: std.ArrayList(Row(len)),
        allocator: std.mem.Allocator,
        header: ?Row(len) = null,
        footer: ?Row(len) = null,
        mode: Separator.Mode,
        padding: usize,
        column_align: [len]Align,
        row_separator: bool,

        const Self = @This();

        pub const Options = struct {
            mode: Separator.Mode = .ascii,
            padding: usize = 0,
            column_align: [len]Align = [_]Align{.left} ** len,
            row_separator: bool = false,
        };

        pub fn init(allocator: std.mem.Allocator, opts: Options) Self {
            return .{
                .rows = .empty,
                .allocator = allocator,
                .mode = opts.mode,
                .padding = opts.padding,
                .column_align = opts.column_align,
                .row_separator = opts.row_separator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.rows.deinit(self.allocator);
        }

        /// Set header from string literals or Cell values.
        pub fn setHeader(self: *Self, texts: anytype) void {
            self.header = toCells(texts);
        }

        /// Set footer from string literals or Cell values.
        pub fn setFooter(self: *Self, texts: anytype) void {
            self.footer = toCells(texts);
        }

        /// Add a row from string literals. Each element is wrapped in Cell.init().
        pub fn addRow(self: *Self, texts: anytype) !void {
            try self.rows.append(self.allocator, toCells(texts));
        }

        /// Add a row of pre-built Cell values for full styling control.
        pub fn addRowCells(self: *Self, cells: Row(len)) !void {
            try self.rows.append(self.allocator, cells);
        }

        /// Convert a tuple of strings or Cells into a Row.
        fn toCells(tuple: anytype) Row(len) {
            var row: Row(len) = undefined;
            inline for (0..len) |i| {
                const val = tuple[i];
                row[i] = switch (@TypeOf(val)) {
                    Cell => val,
                    else => Cell.init(val),
                };
            }
            return row;
        }

        /// Render the table to a writer.
        pub fn format(self: Self, writer: *std.Io.Writer) !void {
            const t = Table(len){
                .header = self.header,
                .footer = self.footer,
                .rows = self.rows.items,
                .mode = self.mode,
                .padding = self.padding,
                .column_align = self.column_align,
                .row_separator = self.row_separator,
            };
            try t.format(writer);
        }
    };
}

test "normal usage" {
    const t = Table(2){
        .header = [_]Cell{ Cell.init("Version"), Cell.init("Date") },
        .rows = &[_][2]Cell{
            .{ Cell.init("0.7.1"), Cell.init("2020-12-13") },
            .{ Cell.init("0.7.0"), Cell.init("2020-11-08") },
            .{ Cell.init("0.6.0"), Cell.init("2020-04-13") },
            .{ Cell.init("0.5.0"), Cell.init("2019-09-30") },
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
        .header = [_]Cell{ Cell.init("Language"), Cell.init("Files") },
        .rows = &[_][2]Cell{
            .{ Cell.init("Zig"), Cell.init("3") },
            .{ Cell.init("Python"), Cell.init("2") },
        },
        .footer = [2]Cell{ Cell.init("Total"), Cell.init("5") },
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
        .header = [_]Cell{ Cell.init("Name"), Cell.init("Score") },
        .rows = &[_][2]Cell{
            .{ Cell.init("Alice"), Cell.init("10") },
            .{ Cell.init("Bob"), Cell.init("200") },
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
        .header = [_]Cell{ Cell.init("A"), Cell.init("B"), Cell.init("C") },
        .rows = &[_][3]Cell{
            .{ Cell.init("x"), Cell.init("yy"), Cell.init("zzz") },
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
        .header = [_]Cell{ Cell.init("K"), Cell.init("V") },
        .rows = &[_][2]Cell{
            .{ Cell.init("a"), Cell.init("1") },
            .{ Cell.init("b"), Cell.init("2") },
            .{ Cell.init("c"), Cell.init("3") },
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

test "per-cell foreground color" {
    const t = Table(2){
        .header = [_]Cell{ Cell.init("Status"), Cell.init("Value") },
        .rows = &[_][2]Cell{
            .{ Cell.init("OK").withFg(.green), Cell.init("100") },
            .{ Cell.init("FAIL").withFg(.red), Cell.init("0") },
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

test "header and footer colors via cell styling" {
    const t = Table(2){
        .header = [_]Cell{
            Cell.init("Name").withFg(.bright_cyan),
            Cell.init("Score").withFg(.bright_cyan),
        },
        .rows = &[_][2]Cell{
            .{ Cell.init("Alice"), Cell.init("95") },
        },
        .footer = [2]Cell{
            Cell.init("Total").withFg(.yellow),
            Cell.init("95").withFg(.yellow),
        },
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

test "bold and italic cell styling" {
    const t = Table(2){
        .header = [_]Cell{ Cell.init("A"), Cell.init("B") },
        .rows = &[_][2]Cell{
            .{ Cell.init("bold").withBold(), Cell.init("italic").withItalic() },
            .{ Cell.init("both").withBold().withItalic(), Cell.init("plain") },
        },
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1mbold\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[3mitalic\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1m\x1b[3mboth\x1b[0m") != null);
    // Plain cells produce no escape sequences.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[" ++ "mplain") == null);
}

test "background color" {
    const t = Table(2){
        .header = [_]Cell{ Cell.init("X"), Cell.init("Y") },
        .rows = &[_][2]Cell{
            .{ Cell.init("hi").withBg(.red), Cell.init("ok") },
        },
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[41mhi\x1b[0m") != null);
}

test "hspan basic" {
    // 3-column table; middle row has a cell spanning 2 columns.
    const t = Table(3){
        .header = [_]Cell{ Cell.init("A"), Cell.init("B"), Cell.init("C") },
        .rows = &[_][3]Cell{
            .{ Cell.init("x"), Cell.init("y"), Cell.init("z") },
            // "wide" spans columns 1-2; position 2 is a placeholder.
            .{ Cell.init("a"), Cell.init("wide").withHspan(2), Cell.span() },
        },
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    // The spanning cell "wide" should appear in the output.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "wide") != null);
    // The placeholder text (empty) is not rendered as a separate column in the span row.
    // Row with span: |a|wide |   (no extra | between "wide" and the right border).
    // The span row must NOT contain "|" between the two spanned columns.
    const span_row_start = std.mem.indexOf(u8, out.items, "|a|") orelse unreachable;
    const span_row_end = std.mem.indexOfPos(u8, out.items, span_row_start, "\n") orelse unreachable;
    const span_row = out.items[span_row_start..span_row_end];
    // The span row should have exactly 3 `|` characters (left, after col 0, right border).
    var pipe_count: usize = 0;
    for (span_row) |ch| {
        if (ch == '|') pipe_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), pipe_count);
}

test "hspan of 3 columns" {
    // 4-column table; one row has a cell spanning all 3 right-hand columns.
    // Use 3-character names ("Who", "Amy", "Bob") so col 0 width is exactly 3,
    // which means the Bob row starts with exactly `|Bob|` in the output.
    const t = Table(4){
        .header = [_]Cell{ Cell.init("Who"), Cell.init("Q1"), Cell.init("Q2"), Cell.init("Q3") },
        .rows = &[_][4]Cell{
            .{ Cell.init("Amy"), Cell.init("90"), Cell.init("85"), Cell.init("92") },
            // "On leave" spans columns 1-3 (Q1, Q2, Q3).
            .{ Cell.init("Bob"), Cell.init("On leave").withHspan(3), Cell.span(), Cell.span() },
        },
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.writer(std.testing.allocator).print("{f}", .{t});

    // The spanning cell text must appear in the output.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "On leave") != null);
    // The span row for Bob should have exactly 3 `|` characters:
    // opening `|`, separator after col 0, and the closing `|`.
    const span_row_start = std.mem.indexOf(u8, out.items, "|Bob|") orelse unreachable;
    const span_row_end = std.mem.indexOfPos(u8, out.items, span_row_start, "\n") orelse unreachable;
    const span_row = out.items[span_row_start..span_row_end];
    var pipe_count: usize = 0;
    for (span_row) |ch| {
        if (ch == '|') pipe_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), pipe_count);
}

test "builder basic" {
    const allocator = std.testing.allocator;
    var t = TableBuilder(2).init(allocator, .{ .mode = .box, .padding = 1 });
    defer t.deinit();

    t.setHeader(.{ "Name", "Score" });
    try t.addRow(.{ "Alice", "100" });
    try t.addRow(.{ "Bob", "200" });
    t.setFooter(.{ "Total", "300" });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.writer(allocator).print("{f}", .{t});

    try std.testing.expectEqualStrings(
        \\┌───────┬───────┐
        \\│ Name  │ Score │
        \\├───────┼───────┤
        \\│ Alice │ 100   │
        \\│ Bob   │ 200   │
        \\├───────┼───────┤
        \\│ Total │ 300   │
        \\└───────┴───────┘
        \\
    , out.items);
}

test "builder with styled cells" {
    const allocator = std.testing.allocator;
    var t = TableBuilder(2).init(allocator, .{});
    defer t.deinit();

    t.setHeader(.{ "K", "V" });
    try t.addRowCells(.{ Cell.init("ok").withFg(.green), Cell.init("1") });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.writer(allocator).print("{f}", .{t});

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[32mok\x1b[0m") != null);
}
