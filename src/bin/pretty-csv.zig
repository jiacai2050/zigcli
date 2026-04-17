//! pretty-csv: Pretty-print CSV files as aligned tables.

const std = @import("std");
const zigcli = @import("zigcli");
const csv = zigcli.csv;
const structargs = zigcli.structargs;
const pt = zigcli.pretty_table;
const term = zigcli.term;
const util = @import("util.zig");
const mem = std.mem;

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try structargs.parse(allocator, struct {
        delimiter: []const u8 = ",",
        style: pt.Separator.Mode = .box,
        padding: u8 = 1,
        @"row-separator": bool = false,
        @"no-header": bool = false,
        /// Comma-separated original column indices (1-based) to right-align.
        @"right-columns": []const u8 = "",
        /// Maximum total table width (0 = auto-fit terminal).
        @"max-width": u16 = 0,
        /// Show each record as a vertical key-value block.
        transpose: bool = false,
        /// Comma-separated column indices (1-based) to display.
        columns: []const u8 = "",
        /// Max input file size in MiB.
        @"max-size": u16 = 64,
        help: bool = false,
        version: bool = false,

        pub const __shorts__ = .{
            .delimiter = .d,
            .style = .s,
            .padding = .p,
            .@"right-columns" = .r,
            .help = .h,
            .@"max-width" = .w,
            .transpose = .t,
            .columns = .c,
        };

        pub const __messages__ = .{
            .delimiter = "Field delimiter (default: ',')",
            .style = "Border style: ascii, box, dos",
            .padding = "Cell padding",
            .@"row-separator" = "Insert separator lines between data rows",
            .@"no-header" = "Treat first row as data",
            .@"right-columns" = "Original column indices to right-align (1-based, comma-separated)",
            .@"max-width" = "Max total table width (0 = auto-fit terminal)",
            .transpose = "Transpose: show each record vertically",
            .columns = "Column indices to show (1-based, comma-separated)",
            .@"max-size" = "Max input file size in MiB",
        };
    }, .{
        .argument_prompt = "[file]",
        .version_string = util.get_build_info(),
    });
    defer opt.deinit();

    const delim: u8 = if (opt.options.delimiter.len > 0)
        opt.options.delimiter[0]
    else
        ',';

    const max_bytes: usize =
        @as(usize, opt.options.@"max-size") * 1024 * 1024;

    const input = if (opt.positional_arguments.len > 0)
        try std.fs.cwd().readFileAlloc(
            allocator,
            opt.positional_arguments[0],
            max_bytes,
        )
    else
        try std.fs.File.stdin().readToEndAlloc(
            allocator,
            max_bytes,
        );
    defer allocator.free(input);

    var document = try csv.parseDocument(allocator, input, .{
        .delimiter = delim,
    });
    defer document.deinit(allocator);
    if (document.rows.len == 0 or document.num_cols == 0) return;

    // Parse --columns filter.
    const col_filter = try parseColFilter(
        allocator,
        opt.options.columns,
        document.num_cols,
    );
    defer if (col_filter) |f| allocator.free(f);
    const right_filter = try parseColFilter(
        allocator,
        opt.options.@"right-columns",
        document.num_cols,
    );
    defer if (right_filter) |f| allocator.free(f);

    const display_cols = if (col_filter) |f|
        f.len
    else
        document.num_cols;

    const stdout = std.fs.File.stdout();
    const utf8_console = if (opt.options.style != .ascii)
        term.enableUtf8ConsoleOutput(stdout)
    else
        term.Utf8ConsoleOutput.noop;
    defer utf8_console.deinit();

    var output_buf: [8192]u8 = undefined;
    var stdout_writer = stdout.writer(&output_buf);
    const writer = &stdout_writer.interface;

    var table = try pt.RuntimeTable.init(allocator, display_cols);
    defer table.deinit();
    table.mode = opt.options.style;
    table.padding = opt.options.padding;
    table.row_separator = opt.options.@"row-separator";
    table.max_width = opt.options.@"max-width";
    table.transpose = opt.options.transpose;
    const alignments = try buildColumnAlignments(
        allocator,
        display_cols,
        col_filter,
        right_filter,
    );
    defer allocator.free(alignments);
    table.column_align = alignments;

    var empty_filter_buf = [_][]const u8{};
    const filter_buf: [][]const u8 = if (col_filter) |filter|
        try allocator.alloc([]const u8, filter.len)
    else
        empty_filter_buf[0..];
    defer if (col_filter != null) allocator.free(filter_buf);

    const data_start: usize =
        if (opt.options.@"no-header") 0 else 1;
    if (!opt.options.@"no-header" and
        document.rows.len > 0)
    {
        try table.setHeader(
            filterRow(
                document.rows[0],
                col_filter,
                filter_buf,
            ),
        );
    }
    for (document.rows[data_start..]) |row| {
        try table.addRow(
            filterRow(row, col_filter, filter_buf),
        );
    }
    try table.render(writer);
    try writer.flush();
}

fn buildColumnAlignments(
    allocator: mem.Allocator,
    display_cols: usize,
    col_filter: ?[]const usize,
    right_filter: ?[]const usize,
) ![]pt.Align {
    const alignments = try allocator.alloc(
        pt.Align,
        display_cols,
    );
    @memset(alignments, .left);

    const right_columns = right_filter orelse return alignments;
    for (0..display_cols) |display_col| {
        const source_col = if (col_filter) |filter|
            filter[display_col]
        else
            display_col;
        for (right_columns) |right_col| {
            if (source_col == right_col) {
                alignments[display_col] = .right;
                break;
            }
        }
    }
    return alignments;
}

// -- Column filter ----------------------------------------------

/// Return filtered view of a row. If no filter, returns as-is.
/// Uses caller-provided buffer to avoid allocation.
fn filterRow(
    fields: []const []const u8,
    col_filter: ?[]const usize,
    buf: [][]const u8,
) []const []const u8 {
    const filter = col_filter orelse return fields;
    std.debug.assert(filter.len <= buf.len);
    for (filter, 0..) |field_index, index| {
        buf[index] = if (field_index < fields.len)
            fields[field_index]
        else
            "";
    }
    return buf[0..filter.len];
}

/// Parse "1,3,5" into 0-based indices. Returns null if empty.
fn parseColFilter(
    allocator: mem.Allocator,
    spec: []const u8,
    num_cols: usize,
) !?[]const usize {
    if (spec.len == 0) return null;
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    var iter = mem.splitScalar(u8, spec, ',');
    while (iter.next()) |tok| {
        const trimmed = mem.trim(
            u8,
            tok,
            &std.ascii.whitespace,
        );
        if (trimmed.len == 0) continue;
        const n = std.fmt.parseInt(usize, trimmed, 10) catch {
            std.log.err(
                "invalid column index: '{s}'",
                .{trimmed},
            );
            return error.InvalidColumnIndex;
        };
        if (n < 1 or n > num_cols) {
            std.log.err(
                "column index {d} out of range 1..{d}",
                .{ n, num_cols },
            );
            return error.InvalidColumnIndex;
        }
        try indices.append(allocator, n - 1);
    }
    if (indices.items.len == 0) return null;
    return try allocator.dupe(usize, indices.items);
}

test "filterRow handles more than 256 filtered columns" {
    const allocator = std.testing.allocator;
    const column_count = 300;

    const fields = try allocator.alloc([]const u8, column_count);
    defer allocator.free(fields);
    @memset(fields, "x");
    fields[column_count - 1] = "last";

    const filter = try allocator.alloc(usize, column_count);
    defer allocator.free(filter);
    for (0..column_count) |index| {
        filter[index] = index;
    }

    const scratch = try allocator.alloc([]const u8, column_count);
    defer allocator.free(scratch);

    const filtered = filterRow(fields, filter, scratch);
    try std.testing.expectEqual(column_count, filtered.len);
    try std.testing.expectEqualStrings("last", filtered[column_count - 1]);
}
