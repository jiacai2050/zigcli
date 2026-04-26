//! pretty-table prints aligned and formatted tables.

const std = @import("std");
const term = @import("term.zig");
const Writer = std.Io.Writer;

pub const String = []const u8;

/// A table cell with optional per-cell ANSI styling and column spanning.
pub const Cell = struct {
    text: String,
    bold: bool = false,
    italic: bool = false,
    /// Foreground (text) color.
    fg: ?term.Style.Color = null,
    /// Background color.
    bg: ?term.Style.Color = null,
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
    pub fn withFg(self: Cell, fg_color: term.Style.Color) Cell {
        var cell = self;
        cell.fg = fg_color;
        return cell;
    }

    /// Returns a copy of this cell with the given background color.
    pub fn withBg(self: Cell, bg_color: term.Style.Color) Cell {
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

fn rowFromValues(comptime len: usize, values: anytype) Row(len) {
    return switch (@TypeOf(values)) {
        Row(len) => values,
        else => {
            var row: Row(len) = undefined;
            inline for (0..len) |index| {
                const value = values[index];
                row[index] = switch (@TypeOf(value)) {
                    Cell => value,
                    else => Cell.init(value),
                };
            }
            return row;
        },
    };
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
        /// Render each data row as a vertical key-value block.
        transpose: bool = false,

        const Self = @This();

        pub const Owned = struct {
            table: Self = .{ .rows = &.{} },
            rows: std.ArrayList(Row(len)) = .empty,

            const OwnedTable = @This();

            pub const Options = struct {
                mode: Separator.Mode = .ascii,
                padding: usize = 0,
                column_align: [len]Align = [_]Align{.left} ** len,
                row_separator: bool = false,
                transpose: bool = false,
            };

            pub fn init(options: Options) OwnedTable {
                return .{
                    .table = .{
                        .rows = &.{},
                        .mode = options.mode,
                        .padding = options.padding,
                        .column_align = options.column_align,
                        .row_separator = options.row_separator,
                        .transpose = options.transpose,
                    },
                };
            }

            pub fn deinit(
                self: *OwnedTable,
                gpa: std.mem.Allocator,
            ) void {
                self.rows.deinit(gpa);
                self.* = undefined;
            }

            pub fn setHeader(
                self: *OwnedTable,
                values: anytype,
            ) void {
                self.table.header = rowFromValues(len, values);
            }

            pub fn setFooter(
                self: *OwnedTable,
                values: anytype,
            ) void {
                self.table.footer = rowFromValues(len, values);
            }

            pub fn addRow(
                self: *OwnedTable,
                gpa: std.mem.Allocator,
                values: anytype,
            ) !void {
                try self.rows.append(
                    gpa,
                    rowFromValues(len, values),
                );
            }

            pub fn addRowCells(
                self: *OwnedTable,
                gpa: std.mem.Allocator,
                cells: Row(len),
            ) !void {
                try self.rows.append(gpa, cells);
            }

            pub fn clearRetainingCapacity(
                self: *OwnedTable,
            ) void {
                self.rows.clearRetainingCapacity();
            }

            pub fn format(
                self: OwnedTable,
                writer: *std.Io.Writer,
            ) !void {
                var table = self.table;
                table.rows = self.rows.items;
                try table.format(writer);
            }
        };

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

                const style: term.Style = .{
                    .bold = cell.bold,
                    .italic = cell.italic,
                    .fg = cell.fg,
                    .bg = cell.bg,
                };
                try style.writeString(writer, "{s}", text);

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

        fn transposedCell(cell: Cell) Cell {
            var copy = cell;
            copy.hspan = 1;
            return copy;
        }

        fn writeTransposedRecord(
            self: Self,
            writer: *std.Io.Writer,
            record: []const Cell,
        ) !void {
            var column_lens = [_]usize{ 2 * self.padding, 2 * self.padding };
            const transposed = Table(2){
                .rows = &.{},
                .mode = self.mode,
                .padding = self.padding,
                .column_align = .{ .left, .left },
            };

            inline for (0..len) |column_index| {
                const key_cell = if (self.header) |header|
                    transposedCell(header[column_index])
                else
                    Cell.init("");
                const value_cell = if (column_index < record.len)
                    transposedCell(record[column_index])
                else
                    Cell.init("");
                column_lens[0] = @max(
                    column_lens[0],
                    key_cell.text.len + 2 * self.padding,
                );
                column_lens[1] = @max(
                    column_lens[1],
                    value_cell.text.len + 2 * self.padding,
                );
            }

            try transposed.writeRowDelimiter(writer, .First, column_lens);
            inline for (0..len) |column_index| {
                const key_cell = if (self.header) |header|
                    transposedCell(header[column_index])
                else
                    Cell.init("");
                const value_cell = if (column_index < record.len)
                    transposedCell(record[column_index])
                else
                    Cell.init("");
                const row = [2]Cell{ key_cell, value_cell };
                const row_table = Table(2){
                    .rows = &.{},
                    .mode = self.mode,
                    .padding = self.padding,
                    .column_align = .{ .left, self.column_align[column_index] },
                };
                try row_table.writeRow(writer, &row, column_lens);
                if (self.row_separator and column_index + 1 < len) {
                    try transposed.writeRowDelimiter(writer, .Sep, column_lens);
                }
            }
            try transposed.writeRowDelimiter(writer, .Last, column_lens);
        }

        fn renderTransposed(
            self: Self,
            writer: *std.Io.Writer,
        ) !void {
            for (self.rows, 0..) |row, row_index| {
                if (row_index > 0) {
                    try writer.writeAll("\n");
                }
                try self.writeTransposedRecord(writer, &row);
            }

            if (self.footer) |footer| {
                if (self.rows.len > 0) {
                    try writer.writeAll("\n");
                }
                try self.writeTransposedRecord(writer, &footer);
            }
        }

        pub fn format(
            self: Self,
            writer: *std.Io.Writer,
        ) !void {
            if (self.transpose) {
                return self.renderTransposed(writer);
            }

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

/// Runtime table with dynamic column count and optional truncation.
/// Unlike `Table(N)`, column count is determined at runtime. Rows are
/// slices of string slices.
pub const RuntimeTable = struct {
    header: ?[]const Cell = null,
    footer: ?[]const Cell = null,
    rows: std.ArrayList([]const Cell) = .empty,
    num_cols: usize,
    mode: Separator.Mode = .ascii,
    padding: usize = 0,
    column_align: []const Align = &.{},
    row_separator: bool = false,
    /// Max total table width. 0 means auto-detect terminal width.
    /// Internally converted to per-column max width.
    max_width: u16 = 0,
    /// Transpose: render each row as a vertical key-value block,
    /// using the header (if set) as keys.
    transpose: bool = false,
    allocator: std.mem.Allocator,
    col_widths: []usize,

    pub fn init(
        allocator: std.mem.Allocator,
        num_cols: usize,
    ) std.mem.Allocator.Error!RuntimeTable {
        std.debug.assert(num_cols > 0);
        return .{
            .allocator = allocator,
            .num_cols = num_cols,
            .col_widths = try allocator.alloc(usize, num_cols),
        };
    }

    pub fn deinit(self: *RuntimeTable) void {
        if (self.header) |h| self.allocator.free(h);
        if (self.footer) |f| self.allocator.free(f);
        for (self.rows.items) |row| self.allocator.free(row);
        self.rows.deinit(self.allocator);
        self.allocator.free(self.col_widths);
    }

    fn duplicateTextCells(
        self: *RuntimeTable,
        texts: []const []const u8,
    ) ![]const Cell {
        var cells = try self.allocator.alloc(
            Cell,
            self.num_cols,
        );
        errdefer self.allocator.free(cells);
        for (0..self.num_cols) |col| {
            cells[col] = Cell.init(
                if (col < texts.len) texts[col] else "",
            );
        }
        return cells;
    }

    fn duplicateCells(
        self: *RuntimeTable,
        source: []const Cell,
    ) ![]const Cell {
        var cells = try self.allocator.alloc(
            Cell,
            self.num_cols,
        );
        errdefer self.allocator.free(cells);
        for (0..self.num_cols) |col| {
            cells[col] = if (col < source.len)
                source[col]
            else
                Cell.init("");
        }
        return cells;
    }

    /// Set header from string slices.
    pub fn setHeader(
        self: *RuntimeTable,
        texts: []const []const u8,
    ) !void {
        const new_header = try self.duplicateTextCells(texts);
        if (self.header) |old_header| self.allocator.free(old_header);
        self.header = new_header;
    }

    /// Set header from pre-built Cells.
    pub fn setHeaderCells(
        self: *RuntimeTable,
        cells: []const Cell,
    ) !void {
        const new_header = try self.duplicateCells(cells);
        if (self.header) |old_header| self.allocator.free(old_header);
        self.header = new_header;
    }

    /// Set footer from string slices.
    pub fn setFooter(
        self: *RuntimeTable,
        texts: []const []const u8,
    ) !void {
        const new_footer = try self.duplicateTextCells(texts);
        if (self.footer) |old_footer| self.allocator.free(old_footer);
        self.footer = new_footer;
    }

    /// Set footer from pre-built Cells.
    pub fn setFooterCells(
        self: *RuntimeTable,
        cells: []const Cell,
    ) !void {
        const new_footer = try self.duplicateCells(cells);
        if (self.footer) |old_footer| self.allocator.free(old_footer);
        self.footer = new_footer;
    }

    /// Add a row from string slices.
    pub fn addRow(
        self: *RuntimeTable,
        texts: []const []const u8,
    ) !void {
        const cells = try self.allocator.alloc(
            Cell,
            self.num_cols,
        );
        errdefer self.allocator.free(cells);
        for (0..self.num_cols) |col| {
            cells[col] = Cell.init(
                if (col < texts.len) texts[col] else "",
            );
        }
        try self.rows.append(self.allocator, cells);
    }

    /// Add a row of pre-built Cells.
    pub fn addRowCells(
        self: *RuntimeTable,
        cells: []const Cell,
    ) !void {
        const row = try self.allocator.dupe(Cell, cells);
        errdefer self.allocator.free(row);
        try self.rows.append(self.allocator, row);
    }

    /// Format the table with `"{f}"`.
    pub fn format(
        self: RuntimeTable,
        writer: *std.Io.Writer,
    ) !void {
        try self.render(writer);
    }

    /// Render the table to a writer.
    pub fn render(
        self: RuntimeTable,
        writer: *std.Io.Writer,
    ) !void {
        if (self.transpose) {
            return self.renderTransposed(writer);
        }
        return self.renderNormal(writer);
    }

    fn renderTransposed(
        self: RuntimeTable,
        writer: *std.Io.Writer,
    ) !void {
        var record_index: usize = 0;
        const max_cell = self.cellWidthFromTotalForColumns(2);

        for (self.rows.items) |row| {
            if (record_index > 0) try writer.writeAll("\n");
            try self.writeTransposedRecord(
                writer,
                row,
                max_cell,
            );
            record_index += 1;
        }

        if (self.footer) |footer| {
            if (record_index > 0) try writer.writeAll("\n");
            try self.writeTransposedRecord(
                writer,
                footer,
                max_cell,
            );
        }
    }

    fn renderNormal(
        self: RuntimeTable,
        writer: *std.Io.Writer,
    ) !void {
        const max_cell = self.cellWidthFromTotal();
        const col_widths = self.col_widths;
        @memset(col_widths, 0);

        if (self.header) |h| {
            accumulateWidths(
                h,
                col_widths,
                self.num_cols,
                self.padding,
                max_cell,
            );
        }
        for (self.rows.items) |row| {
            accumulateWidths(
                row,
                col_widths,
                self.num_cols,
                self.padding,
                max_cell,
            );
        }
        if (self.footer) |footer| {
            accumulateWidths(
                footer,
                col_widths,
                self.num_cols,
                self.padding,
                max_cell,
            );
        }

        try writeHLine(writer, self.mode, .First, col_widths);
        if (self.header) |h| {
            try writeRow(
                writer,
                self.mode,
                h,
                col_widths,
                self.num_cols,
                self.padding,
                self.column_align,
                max_cell,
            );
            try writeHLine(
                writer,
                self.mode,
                .Sep,
                col_widths,
            );
        }
        for (self.rows.items, 0..) |row, index| {
            try writeRow(
                writer,
                self.mode,
                row,
                col_widths,
                self.num_cols,
                self.padding,
                self.column_align,
                max_cell,
            );
            if (self.row_separator and index + 1 < self.rows.items.len) {
                try writeHLine(writer, self.mode, .Sep, col_widths);
            }
        }
        if (self.footer) |footer| {
            try writeHLine(writer, self.mode, .Sep, col_widths);
            try writeRow(
                writer,
                self.mode,
                footer,
                col_widths,
                self.num_cols,
                self.padding,
                self.column_align,
                max_cell,
            );
        }
        try writeHLine(writer, self.mode, .Last, col_widths);
    }

    /// Convert total table width to per-column content width.
    /// Returns 0 (unlimited) if columns would each get 80+ chars.
    fn cellWidthFromTotal(self: RuntimeTable) u16 {
        return self.cellWidthFromTotalForColumns(self.num_cols);
    }

    fn cellWidthFromTotalForColumns(
        self: RuntimeTable,
        column_count: usize,
    ) u16 {
        const width = if (self.max_width > 0)
            self.max_width
        else
            term.stdoutWidth() orelse 0;
        if (width == 0 or column_count == 0) return 0;
        // Overhead: 1 border per column + 2*padding + 1 final.
        const overhead =
            column_count * (2 * self.padding + 1) + 1;
        if (width <= overhead) return 1;
        const available = @as(usize, width) - overhead;
        const per_col = available / column_count;
        if (per_col >= 80) return 0;
        return @intCast(@max(per_col, 3));
    }

    fn writeTransposedRecord(
        self: RuntimeTable,
        writer: *std.Io.Writer,
        record: []const Cell,
        max_cell: u16,
    ) !void {
        var col_widths = [_]usize{ 0, 0 };
        for (0..self.num_cols) |col| {
            const key = if (self.header) |header|
                (if (col < header.len) header[col].text else "")
            else
                "";
            const value = if (col < record.len)
                record[col]
            else
                Cell.init("");
            const key_display = textDisplayInfo(key, max_cell);
            const value_display = textDisplayInfo(value.text, max_cell);

            col_widths[0] = @max(
                col_widths[0],
                key_display.visual_len + 2 * self.padding,
            );
            col_widths[1] = @max(
                col_widths[1],
                value_display.visual_len + 2 * self.padding,
            );
        }

        try writeHLine(writer, self.mode, .First, &col_widths);
        for (0..self.num_cols) |col| {
            const key = if (self.header) |header|
                (if (col < header.len) header[col].text else "")
            else
                "";
            const value = if (col < record.len)
                record[col]
            else
                Cell.init("");
            const row = [_]Cell{ Cell.init(key), value };
            const alignments = [_]Align{
                .left,
                if (col < self.column_align.len)
                    self.column_align[col]
                else
                    .left,
            };
            try writeRow(
                writer,
                self.mode,
                &row,
                &col_widths,
                2,
                self.padding,
                &alignments,
                max_cell,
            );
            if (self.row_separator and col + 1 < self.num_cols) {
                try writeHLine(writer, self.mode, .Sep, &col_widths);
            }
        }
        try writeHLine(writer, self.mode, .Last, &col_widths);
    }

    fn accumulateWidths(
        cells: []const Cell,
        col_widths: []usize,
        num_cols: usize,
        padding: usize,
        max_cell: u16,
    ) void {
        for (0..@min(cells.len, num_cols)) |col| {
            const display = textDisplayInfo(
                cells[col].text,
                max_cell,
            );
            col_widths[col] = @max(
                col_widths[col],
                display.visual_len + 2 * padding,
            );
        }
    }

    const TextDisplayInfo = struct {
        text: []const u8,
        visual_len: usize,
        ellipsis: bool,
    };

    fn textDisplayInfoBytes(
        text: []const u8,
        max_cell: u16,
    ) TextDisplayInfo {
        if (max_cell == 0) {
            return .{
                .text = text,
                .visual_len = text.len,
                .ellipsis = false,
            };
        }

        if (text.len <= max_cell) {
            return .{
                .text = text,
                .visual_len = text.len,
                .ellipsis = false,
            };
        }

        const limit: usize =
            if (max_cell > 1) max_cell - 1 else 0;
        return .{
            .text = text[0..limit],
            .visual_len = max_cell,
            .ellipsis = true,
        };
    }

    // TODO: Measure terminal display width instead of Unicode scalar count for wide and combining
    // characters.
    fn textDisplayInfo(
        text: []const u8,
        max_cell: u16,
    ) TextDisplayInfo {
        const utf8_view = std.unicode.Utf8View.init(text) catch {
            return textDisplayInfoBytes(text, max_cell);
        };

        if (max_cell == 0) {
            var visual_len: usize = 0;
            var iterator = utf8_view.iterator();
            while (iterator.nextCodepointSlice()) |_| {
                visual_len += 1;
            }
            return .{
                .text = text,
                .visual_len = visual_len,
                .ellipsis = false,
            };
        }

        const limit: usize =
            if (max_cell > 1) max_cell - 1 else 0;
        var visual_len: usize = 0;
        var byte_len: usize = 0;
        var iterator = utf8_view.iterator();
        while (iterator.nextCodepointSlice()) |codepoint_slice| {
            if (visual_len == limit) {
                return .{
                    .text = text[0..byte_len],
                    .visual_len = max_cell,
                    .ellipsis = true,
                };
            }
            visual_len += 1;
            byte_len += codepoint_slice.len;
        }
        return .{
            .text = text,
            .visual_len = visual_len,
            .ellipsis = false,
        };
    }

    fn writeRow(
        writer: *std.Io.Writer,
        mode: Separator.Mode,
        cells: []const Cell,
        col_widths: []const usize,
        num_cols: usize,
        padding: usize,
        column_align: []const Align,
        max_cell: u16,
    ) !void {
        for (0..num_cols) |col| {
            const col_pos: Separator.Position =
                if (col == 0) .First else .Sep;
            try writer.writeAll(
                Separator.get(mode, .Text, col_pos),
            );
            const cell = if (col < cells.len)
                cells[col]
            else
                Cell.init("");
            const display = textDisplayInfo(
                cell.text,
                max_cell,
            );
            const visual = display.visual_len;
            const content_space = col_widths[col] -| (2 * padding);
            const remaining = content_space -| visual;
            const alignment = if (col < column_align.len)
                column_align[col]
            else
                .left;
            const left_pad: usize = switch (alignment) {
                .left => padding,
                .right => padding + remaining,
                .center => padding + @divFloor(remaining, 2),
            };
            const right_pad = col_widths[col] -| (left_pad + visual);
            for (0..left_pad) |_| {
                try writer.writeByte(' ');
            }
            const style: term.Style = .{
                .bold = cell.bold,
                .italic = cell.italic,
                .fg = cell.fg,
                .bg = cell.bg,
            };
            try style.writeString(writer, "{s}{s}", .{
                display.text,
                if (display.ellipsis) "\xe2\x80\xa6" else "",
            });
            for (0..right_pad) |_| try writer.writeByte(' ');
        }
        try writer.writeAll(
            Separator.get(mode, .Text, .Last),
        );
        try writer.writeAll("\n");
    }

    /// Write a horizontal separator line.
    fn writeHLine(
        writer: *std.Io.Writer,
        mode: Separator.Mode,
        pos: Separator.Position,
        col_widths: []const usize,
    ) !void {
        for (col_widths, 0..) |width, col| {
            const col_pos: Separator.Position =
                if (col == 0) .First else .Sep;
            try writer.writeAll(
                Separator.get(mode, pos, col_pos),
            );
            for (0..width) |_| {
                try writer.writeAll(
                    Separator.get(mode, pos, .Text),
                );
            }
        }
        try writer.writeAll(Separator.get(mode, pos, .Last));
        try writer.writeAll("\n");
    }
};

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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

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
    , out.written());
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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

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
    , out.written());
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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

    try std.testing.expectEqualStrings(
        \\+-------+-------+
        \\| Name  | Score |
        \\+-------+-------+
        \\| Alice |    10 |
        \\| Bob   |   200 |
        \\+-------+-------+
        \\
    , out.written());
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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

    try std.testing.expectEqualStrings(
        \\+---+----+-----+
        \\| A | B  |  C  |
        \\+---+----+-----+
        \\| x | yy | zzz |
        \\+---+----+-----+
        \\
    , out.written());
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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

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
    , out.written());
}

test "per-cell foreground color" {
    const t = Table(2){
        .header = [_]Cell{ Cell.init("Status"), Cell.init("Value") },
        .rows = &[_][2]Cell{
            .{ Cell.init("OK").withFg(.green), Cell.init("100") },
            .{ Cell.init("FAIL").withFg(.red), Cell.init("0") },
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

    // Borders and column widths are unchanged by color escapes.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "+------+-----+") != null);
    // Green escape code wraps "OK", red escape code wraps "FAIL".
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[32mOK\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[31mFAIL\x1b[0m") != null);
    // Uncolored cells ("100", "0") do not have any escape codes.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[32m100") == null);
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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

    // Header cells are wrapped with bright cyan.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[96mName\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[96mScore\x1b[0m") != null);
    // Footer cells are wrapped with yellow.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[33mTotal\x1b[0m") != null);
    // Data row has no color escape codes.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[" ++ "mAlice") == null);
}

test "bold and italic cell styling" {
    const t = Table(2){
        .header = [_]Cell{ Cell.init("A"), Cell.init("B") },
        .rows = &[_][2]Cell{
            .{ Cell.init("bold").withBold(), Cell.init("italic").withItalic() },
            .{ Cell.init("both").withBold().withItalic(), Cell.init("plain") },
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[1mbold\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[3mitalic\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[1m\x1b[3mboth\x1b[0m") != null);
    // Plain cells produce no escape sequences.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[" ++ "mplain") == null);
}

test "background color" {
    const t = Table(2){
        .header = [_]Cell{ Cell.init("X"), Cell.init("Y") },
        .rows = &[_][2]Cell{
            .{ Cell.init("hi").withBg(.red), Cell.init("ok") },
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[41mhi\x1b[0m") != null);
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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

    // The spanning cell "wide" should appear in the output.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "wide") != null);
    // The placeholder text (empty) is not rendered as a separate column in the span row.
    // Row with span: |a|wide |   (no extra | between "wide" and the right border).
    // The span row must NOT contain "|" between the two spanned columns.
    const span_row_start = std.mem.indexOf(u8, out.written(), "|a|") orelse unreachable;
    const span_row_end = std.mem.indexOfPos(u8, out.written(), span_row_start, "\n") orelse unreachable;
    const span_row = out.written()[span_row_start..span_row_end];
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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{t});

    // The spanning cell text must appear in the output.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "On leave") != null);
    // The span row for Bob should have exactly 3 `|` characters:
    // opening `|`, separator after col 0, and the closing `|`.
    const span_row_start = std.mem.indexOf(u8, out.written(), "|Bob|") orelse unreachable;
    const span_row_end = std.mem.indexOfPos(u8, out.written(), span_row_start, "\n") orelse unreachable;
    const span_row = out.written()[span_row_start..span_row_end];
    var pipe_count: usize = 0;
    for (span_row) |ch| {
        if (ch == '|') pipe_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), pipe_count);
}

test "owned basic" {
    const allocator = std.testing.allocator;
    var table = Table(2).Owned.init(.{ .mode = .box, .padding = 1 });
    defer table.deinit(allocator);

    table.setHeader(.{ "Name", "Score" });
    try table.addRow(allocator, .{ "Alice", "100" });
    try table.addRow(allocator, .{ "Bob", "200" });
    table.setFooter(.{ "Total", "300" });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{table});

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
    , out.written());
}

test "owned with styled cells" {
    const allocator = std.testing.allocator;
    var table = Table(2).Owned.init(.{});
    defer table.deinit(allocator);

    table.setHeader(.{ "K", "V" });
    try table.addRowCells(
        allocator,
        .{ Cell.init("ok").withFg(.green), Cell.init("1") },
    );

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{table});

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[32mok\x1b[0m") != null);
}

test "table transpose" {
    const table = Table(2){
        .header = [_]Cell{ Cell.init("Name"), Cell.init("Score") },
        .rows = &[_][2]Cell{
            .{ Cell.init("Alice"), Cell.init("10") },
            .{ Cell.init("Bob"), Cell.init("200") },
        },
        .mode = .box,
        .padding = 1,
        .column_align = .{ .left, .right },
        .transpose = true,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{table});

    try std.testing.expectEqualStrings(
        \\┌───────┬───────┐
        \\│ Name  │ Alice │
        \\│ Score │    10 │
        \\└───────┴───────┘
        \\
        \\┌───────┬─────┐
        \\│ Name  │ Bob │
        \\│ Score │ 200 │
        \\└───────┴─────┘
        \\
    , out.written());
}

test "owned transpose" {
    const allocator = std.testing.allocator;
    var table = Table(2).Owned.init(.{
        .mode = .box,
        .padding = 1,
        .column_align = .{ .left, .right },
        .transpose = true,
    });
    defer table.deinit(allocator);

    table.setHeader(.{ "Name", "Score" });
    try table.addRow(allocator, .{ "Alice", "10" });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{table});

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "│ Score │    10 │") != null);
}

test "runtime table footer and format" {
    const allocator = std.testing.allocator;
    var table = try RuntimeTable.init(allocator, 2);
    defer table.deinit();
    table.mode = .box;
    table.padding = 1;

    try table.setHeader(&.{ "Language", "Files" });
    try table.addRow(&.{ "Zig", "3" });
    try table.addRow(&.{ "Python", "2" });
    try table.setFooter(&.{ "Total", "5" });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{table});

    try std.testing.expectEqualStrings(
        \\┌──────────┬───────┐
        \\│ Language │ Files │
        \\├──────────┼───────┤
        \\│ Zig      │ 3     │
        \\│ Python   │ 2     │
        \\├──────────┼───────┤
        \\│ Total    │ 5     │
        \\└──────────┴───────┘
        \\
    , out.written());
}

test "runtime table truncation keeps utf8 boundaries" {
    const display = RuntimeTable.textDisplayInfo("ééé", 2);

    try std.testing.expectEqualStrings("é", display.text);
    try std.testing.expectEqual(@as(usize, 2), display.visual_len);
    try std.testing.expect(display.ellipsis);
}

test "runtime table width counts utf8 code points" {
    const display = RuntimeTable.textDisplayInfo("你好", 0);

    try std.testing.expectEqualStrings("你好", display.text);
    try std.testing.expectEqual(@as(usize, 2), display.visual_len);
    try std.testing.expect(!display.ellipsis);
}

test "runtime table column alignment" {
    const allocator = std.testing.allocator;
    var table = try RuntimeTable.init(allocator, 2);
    defer table.deinit();
    table.padding = 1;
    table.column_align = &.{ .left, .right };

    try table.setHeader(&.{ "Name", "Score" });
    try table.addRow(&.{ "Alice", "10" });
    try table.addRow(&.{ "Bob", "200" });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{table});

    try std.testing.expectEqualStrings(
        \\+-------+-------+
        \\| Name  | Score |
        \\+-------+-------+
        \\| Alice |    10 |
        \\| Bob   |   200 |
        \\+-------+-------+
        \\
    , out.written());
}

test "runtime table transpose includes footer" {
    const allocator = std.testing.allocator;
    var table = try RuntimeTable.init(allocator, 2);
    defer table.deinit();
    table.mode = .box;
    table.padding = 1;
    table.transpose = true;

    try table.setHeader(&.{ "Key", "Value" });
    try table.addRow(&.{ "A", "1" });
    try table.setFooter(&.{ "Total", "1" });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{table});

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "│ Key   │ Total │") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "│ Value │ 1     │") != null);
}

test "runtime table row separator" {
    const allocator = std.testing.allocator;
    var table = try RuntimeTable.init(allocator, 2);
    defer table.deinit();
    table.row_separator = true;

    try table.setHeader(&.{ "K", "V" });
    try table.addRow(&.{ "a", "1" });
    try table.addRow(&.{ "b", "2" });
    try table.addRow(&.{ "c", "3" });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{table});

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
    , out.written());
}

test "runtime table header footer cell setters" {
    const allocator = std.testing.allocator;
    var table = try RuntimeTable.init(allocator, 2);
    defer table.deinit();

    try table.setHeaderCells(&.{
        Cell.init("Name").withFg(.bright_cyan),
        Cell.init("Score").withFg(.bright_cyan),
    });
    try table.addRow(&.{ "Alice", "95" });
    try table.setFooterCells(&.{
        Cell.init("Total").withFg(.yellow),
        Cell.init("95").withFg(.yellow),
    });

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print("{f}", .{table});

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[96mName\x1b[0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b[33mTotal\x1b[0m") != null);
}
