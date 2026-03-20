//! pretty-csv: Pretty-print CSV files as aligned tables.

const std = @import("std");
const simargs = @import("simargs");
const pt = @import("pretty-table");
const util = @import("util.zig");
const mem = std.mem;

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try simargs.parse(allocator, struct {
        delimiter: []const u8 = ",",
        style: pt.Separator.Mode = .box,
        padding: u8 = 1,
        @"no-header": bool = false,
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
            .help = .h,
            .@"max-width" = .w,
            .transpose = .t,
            .columns = .c,
        };

        pub const __messages__ = .{
            .delimiter = "Field delimiter (default: ',')",
            .style = "Border style: ascii, box, dos",
            .padding = "Cell padding",
            .@"no-header" = "Treat first row as data",
            .@"max-width" =
            "Max total table width (0 = auto-fit terminal)",
            .transpose = "Transpose: show each record vertically",
            .columns =
            "Column indices to show (1-based, comma-separated)",
            .@"max-size" =
            "Max input file size in MiB (default: 64)",
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

    // Parse all rows.
    var all_rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (all_rows.items) |row| allocator.free(row);
        all_rows.deinit(allocator);
    }

    var num_cols: usize = 0;
    var lines = mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const trimmed = mem.trimRight(u8, line, "\r");
        if (trimmed.len == 0) continue;
        const fields = try parseLine(allocator, trimmed, delim);
        if (num_cols == 0) num_cols = fields.len;
        try all_rows.append(allocator, fields);
    }
    if (all_rows.items.len == 0 or num_cols == 0) return;

    // Parse --columns filter.
    const col_filter = try parseColFilter(
        allocator,
        opt.options.columns,
        num_cols,
    );
    defer if (col_filter) |f| allocator.free(f);

    const display_cols = if (col_filter) |f|
        f.len
    else
        num_cols;

    const stdout = std.fs.File.stdout();
    var output_buf: [8192]u8 = undefined;
    var stdout_writer = stdout.writer(&output_buf);
    const writer = &stdout_writer.interface;

    var table = pt.DynTable.init(allocator, display_cols);
    defer table.deinit();
    table.mode = opt.options.style;
    table.padding = opt.options.padding;
    table.max_width = opt.options.@"max-width";
    table.transpose = opt.options.transpose;

    // Scratch buffer for column filtering (avoids per-row alloc).
    var filter_buf: [256][]const u8 = undefined;

    const data_start: usize =
        if (opt.options.@"no-header") 0 else 1;
    if (!opt.options.@"no-header" and
        all_rows.items.len > 0)
    {
        try table.setHeader(
            filterRow(
                all_rows.items[0],
                col_filter,
                &filter_buf,
            ),
        );
    }
    for (all_rows.items[data_start..]) |row| {
        try table.addRow(
            filterRow(row, col_filter, &filter_buf),
        );
    }
    try table.render(writer);
    try writer.flush();
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
    const n = @min(filter.len, buf.len);
    for (0..n) |i| {
        buf[i] = if (filter[i] < fields.len)
            fields[filter[i]]
        else
            "";
    }
    return buf[0..n];
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

// -- CSV parsing ------------------------------------------------

fn parseLine(
    allocator: mem.Allocator,
    line: []const u8,
    delim: u8,
) ![]const []const u8 {
    // Count fields by scanning for unquoted delimiters.
    var num_fields: usize = 1;
    var in_quotes = false;
    for (line) |ch| {
        if (ch == '"') {
            in_quotes = !in_quotes;
        } else if (ch == delim and !in_quotes) {
            num_fields += 1;
        }
    }

    const fields = try allocator.alloc([]const u8, num_fields);
    var col: usize = 0;
    var pos: usize = 0;

    // Bounded by line.len and num_fields.
    while (pos < line.len and col < num_fields) {
        if (line[pos] == '"') {
            // Quoted field: skip opening quote.
            pos += 1;
            const field_start = pos;
            while (pos < line.len) {
                if (line[pos] == '"') {
                    // Escaped quote ("") — skip both.
                    if (pos + 1 < line.len and
                        line[pos + 1] == '"')
                    {
                        pos += 2;
                    } else {
                        break;
                    }
                } else {
                    pos += 1;
                }
            }
            fields[col] = line[field_start..pos];
            // Skip closing quote and delimiter.
            if (pos < line.len and line[pos] == '"') {
                pos += 1;
            }
            if (pos < line.len and line[pos] == delim) {
                pos += 1;
            }
        } else {
            // Unquoted field.
            const field_start = pos;
            while (pos < line.len and line[pos] != delim) {
                pos += 1;
            }
            fields[col] = line[field_start..pos];
            // Skip delimiter.
            if (pos < line.len) pos += 1;
        }
        col += 1;
    }
    // Fill remaining columns with empty strings.
    while (col < num_fields) : (col += 1) fields[col] = "";
    return fields;
}
