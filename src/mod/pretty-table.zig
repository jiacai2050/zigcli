const std = @import("std");

pub const String = []const u8;
pub fn Row(comptime num: usize) type {
    return [num]String;
}

pub const Separator = struct {
    const box = [_][4]String{
        .{ "┌", "─", "┬", "┐" },
        .{ "│", "─", "│", "│" },
        .{ "├", "─", "┼", "┤" },
        .{ "└", "─", "┴", "┘" },
    };

    const ascii = [_][4]String{
        .{ "+", "-", "+", "+" },
        .{ "|", "-", "|", "|" },
        .{ "+", "-", "+", "|" },
        .{ "+", "-", "+", "+" },
    };

    const RowPos = enum { First, Text, Sep, Last };
    const ColPos = enum { First, Middle, Sep, Last };
    pub const Mode = enum {
        ascii,
        box,
    };

    fn get(mode: Mode, row_pos: RowPos, col_pos: ColPos) []const u8 {
        const prefix = switch (mode) {
            .ascii => ascii,
            .box => box,
        };

        return prefix[@intFromEnum(row_pos)][@intFromEnum(col_pos)];
    }
};

pub fn Table(comptime len: usize) type {
    return struct {
        header: ?Row(len) = null,
        footer: ?Row(len) = null,
        rows: []const Row(len),
        mode: Separator.Mode = .ascii,

        const Self = @This();

        fn writeRowDelimiter(self: Self, writer: anytype, row_pos: Separator.RowPos, col_lens: [len]usize) !void {
            inline for (0..len, col_lens) |col_idx, max_len| {
                const first_col = col_idx == 0;
                if (first_col) {
                    try writer.writeAll(Separator.get(self.mode, row_pos, .First));
                } else {
                    try writer.writeAll(Separator.get(self.mode, row_pos, .Sep));
                }

                for (0..max_len) |_| {
                    try writer.writeAll(Separator.get(self.mode, row_pos, .Middle));
                }
            }

            try writer.writeAll(Separator.get(self.mode, row_pos, .Last));
            try writer.writeAll("\n");
        }

        fn writeRow(
            self: Self,
            writer: anytype,
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

                try writer.writeAll(column);

                var left: usize = col_len - column.len;
                for (0..left) |_| {
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

            return lens;
        }

        pub fn format(
            self: Self,
            comptime fmt: String,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            _ = options;
            _ = fmt;
            const column_lens = self.calculateColumnLens();

            try self.writeRowDelimiter(writer, .First, column_lens);
            if (self.header) |header| {
                try self.writeRow(
                    writer,
                    &header,
                    column_lens,
                );
            }

            for (self.rows) |row| {
                try self.writeRowDelimiter(writer, .Sep, column_lens);
                try self.writeRow(writer, &row, column_lens);
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

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try out.writer().print("{}", .{t});

    try std.testing.expectEqualStrings(out.items,
        \\+-------+----------+
        \\|Version|Date      |
        \\+-------+----------|
        \\|0.7.1  |2020-12-13|
        \\+-------+----------|
        \\|0.7.0  |2020-11-08|
        \\+-------+----------|
        \\|0.6.0  |2020-04-13|
        \\+-------+----------|
        \\|0.5.0  |2019-09-30|
        \\+-------+----------+
        \\
    );
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

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try out.writer().print("{}", .{t});

    try std.testing.expectEqualStrings(out.items,
        \\+--------+-----+
        \\|Language|Files|
        \\+--------+-----|
        \\|Zig     |3    |
        \\+--------+-----|
        \\|Python  |2    |
        \\+--------+-----|
        \\|Total   |5    |
        \\+--------+-----+
        \\
    );
}
