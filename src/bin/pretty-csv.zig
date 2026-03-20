//! pretty-csv: Pretty-print CSV files as aligned tables.

const std = @import("std");
const simargs = @import("simargs");
const pt = @import("pretty-table");
const util = @import("util.zig");
const mem = std.mem;
const posix = std.posix;

const max_columns = 256;

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

    const rows = all_rows.items;
    const display_cols = if (col_filter) |f| f.len else num_cols;

    // Determine per-column max-width from total table width.
    const max_col_width: u16 = if (opt.options.@"max-width" > 0)
        tableWidthToColWidth(
            opt.options.@"max-width",
            display_cols,
            opt.options.padding,
        )
    else
        autoMaxWidth(display_cols, opt.options.padding);

    const stdout = std.fs.File.stdout();
    var output_buf: [8192]u8 = undefined;
    var stdout_writer = stdout.writer(&output_buf);
    const writer = &stdout_writer.interface;

    if (opt.options.transpose) {
        try renderTranspose(
            writer,
            rows,
            display_cols,
            col_filter,
            opt.options.style,
            opt.options.padding,
            opt.options.@"no-header",
            max_col_width,
        );
    } else {
        try renderTable(
            writer,
            rows,
            display_cols,
            col_filter,
            opt.options.style,
            opt.options.padding,
            opt.options.@"no-header",
            max_col_width,
        );
    }
    try writer.flush();
}

// -- Terminal width detection -----------------------------------

/// Detect terminal column count via ioctl on stderr (still a TTY when
/// stdout is piped). Returns 0 if not a TTY.
fn getTerminalWidth() u16 {
    const fd = std.fs.File.stderr().handle;
    var wsz: posix.winsize = undefined;
    const rc = posix.system.ioctl(
        fd,
        posix.T.IOCGWINSZ,
        @intFromPtr(&wsz),
    );
    if (posix.errno(rc) == .SUCCESS and wsz.col > 0) {
        return wsz.col;
    }
    return 0;
}

/// Compute per-column max-width so the table fits the terminal.
/// Returns 0 (unlimited) if not a TTY or columns are few enough.
fn autoMaxWidth(display_cols: usize, padding: u8) u16 {
    const term_width = getTerminalWidth();
    if (term_width == 0 or display_cols == 0) return 0;
    return tableWidthToColWidth(term_width, display_cols, padding);
}

/// Convert a total table width to per-column content width.
fn tableWidthToColWidth(
    total: u16,
    display_cols: usize,
    padding: u8,
) u16 {
    // Overhead per column: 1 border char + 2 * padding.
    // Plus 1 for the rightmost border.
    const overhead =
        display_cols * (2 * @as(usize, padding) + 1) + 1;
    if (total <= overhead) return 1;
    const available = @as(usize, total) - overhead;
    const per_col = available / display_cols;
    // No truncation needed if each column gets 80+ chars.
    if (per_col >= 80) return 0;
    return @intCast(@max(per_col, 3));
}

// -- Column filter ----------------------------------------------

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
        const n = std.fmt.parseInt(
            usize,
            trimmed,
            10,
        ) catch continue;
        if (n >= 1 and n <= num_cols) {
            try indices.append(allocator, n - 1);
        }
    }
    if (indices.items.len == 0) return null;
    return try allocator.dupe(usize, indices.items);
}

/// Get the field at a display column, respecting the filter.
fn getField(
    fields: []const []const u8,
    display_col: usize,
    col_filter: ?[]const usize,
) []const u8 {
    const src_col = if (col_filter) |f| blk: {
        break :blk if (display_col < f.len) f[display_col] else return "";
    } else display_col;
    if (src_col < fields.len) return fields[src_col];
    return "";
}

// -- Truncation --------------------------------------------------

/// Return text truncated to max chars. 0 means no limit.
fn truncate(text: []const u8, max: u16) []const u8 {
    if (max == 0 or text.len <= max) return text;
    // Reserve 1 char for the ellipsis.
    const limit: usize = if (max > 1) max - 1 else 0;
    return text[0..limit];
}

fn needsEllipsis(text: []const u8, max: u16) bool {
    return max > 0 and text.len > max;
}

// -- Table rendering ---------------------------------------------

fn renderTable(
    writer: *std.Io.Writer,
    rows: []const []const []const u8,
    display_cols: usize,
    col_filter: ?[]const usize,
    mode: pt.Separator.Mode,
    padding: u8,
    no_header: bool,
    max_cell_width: u16,
) !void {
    std.debug.assert(display_cols <= max_columns);
    const pad: usize = padding;

    // Calculate column widths.
    var col_widths_buf: [max_columns]usize = undefined;
    const col_widths = col_widths_buf[0..display_cols];
    @memset(col_widths, 0);
    for (rows) |row| {
        for (0..display_cols) |col| {
            const raw = getField(row, col, col_filter);
            const text = truncate(raw, max_cell_width);
            const visual_len = text.len +
                @as(usize, if (needsEllipsis(raw, max_cell_width))
                    1
                else
                    0);
            col_widths[col] = @max(
                col_widths[col],
                visual_len + 2 * pad,
            );
        }
    }

    try writeHLine(writer, mode, .First, col_widths);
    if (!no_header and rows.len > 0) {
        try writeDataRow(
            writer,
            mode,
            rows[0],
            col_widths,
            pad,
            display_cols,
            col_filter,
            max_cell_width,
        );
        try writeHLine(writer, mode, .Sep, col_widths);
    }
    const data_start: usize = if (no_header) 0 else 1;
    for (rows[data_start..]) |row| {
        try writeDataRow(
            writer,
            mode,
            row,
            col_widths,
            pad,
            display_cols,
            col_filter,
            max_cell_width,
        );
    }
    try writeHLine(writer, mode, .Last, col_widths);
}

fn writeHLine(
    writer: *std.Io.Writer,
    mode: pt.Separator.Mode,
    pos: pt.Separator.Position,
    col_widths: []const usize,
) !void {
    for (col_widths, 0..) |width, col| {
        const col_pos: pt.Separator.Position =
            if (col == 0) .First else .Sep;
        try writer.writeAll(pt.Separator.get(mode, pos, col_pos));
        for (0..width) |_| {
            try writer.writeAll(pt.Separator.get(mode, pos, .Text));
        }
    }
    try writer.writeAll(pt.Separator.get(mode, pos, .Last));
    try writer.writeAll("\n");
}

fn writeDataRow(
    writer: *std.Io.Writer,
    mode: pt.Separator.Mode,
    fields: []const []const u8,
    col_widths: []const usize,
    pad: usize,
    display_cols: usize,
    col_filter: ?[]const usize,
    max_cell_width: u16,
) !void {
    for (0..display_cols) |col| {
        const col_pos: pt.Separator.Position =
            if (col == 0) .First else .Sep;
        try writer.writeAll(
            pt.Separator.get(mode, .Text, col_pos),
        );
        const raw = getField(fields, col, col_filter);
        const text = truncate(raw, max_cell_width);
        const ellipsis = needsEllipsis(raw, max_cell_width);
        const visual_len = text.len +
            @as(usize, if (ellipsis) 1 else 0);
        const right_pad = col_widths[col] -| (pad + visual_len);
        for (0..pad) |_| try writer.writeByte(' ');
        try writer.writeAll(text);
        // "…" is U+2026, 3 bytes in UTF-8.
        if (ellipsis) try writer.writeAll("\xe2\x80\xa6");
        for (0..right_pad) |_| try writer.writeByte(' ');
    }
    try writer.writeAll(pt.Separator.get(mode, .Text, .Last));
    try writer.writeAll("\n");
}

// -- Transpose rendering ----------------------------------------

fn renderTranspose(
    writer: *std.Io.Writer,
    rows: []const []const []const u8,
    display_cols: usize,
    col_filter: ?[]const usize,
    mode: pt.Separator.Mode,
    padding: u8,
    no_header: bool,
    max_cell_width: u16,
) !void {
    const pad: usize = padding;
    const header = if (!no_header and rows.len > 0)
        rows[0]
    else
        null;
    const data_start: usize = if (no_header) 0 else 1;

    for (rows[data_start..], 0..) |row, record_idx| {
        // Key width = max header name or column index length.
        var key_width: usize = 0;
        for (0..display_cols) |col| {
            const key = if (header) |h|
                getField(h, col, col_filter)
            else
                "";
            const key_len = if (key.len > 0)
                key.len
            else
                numDigits(col + 1);
            key_width = @max(key_width, key_len);
        }

        // Value width = max truncated value length.
        var val_width: usize = 0;
        for (0..display_cols) |col| {
            const raw = getField(row, col, col_filter);
            const text = truncate(raw, max_cell_width);
            const visual_len = text.len +
                @as(usize, if (needsEllipsis(raw, max_cell_width))
                    1
                else
                    0);
            val_width = @max(val_width, visual_len);
        }

        const col_widths = [2]usize{
            key_width + 2 * pad,
            val_width + 2 * pad,
        };

        // Blank line between records.
        if (record_idx > 0) try writer.writeAll("\n");
        try writeHLine(writer, mode, .First, &col_widths);

        for (0..display_cols) |col| {
            try writer.writeAll(
                pt.Separator.get(mode, .Text, .First),
            );

            // Key column.
            const key = if (header) |h|
                getField(h, col, col_filter)
            else
                "";
            for (0..pad) |_| try writer.writeByte(' ');
            if (key.len > 0) {
                try writer.writeAll(key);
                for (0..key_width -| key.len) |_| {
                    try writer.writeByte(' ');
                }
            } else {
                var idx_buf: [20]u8 = undefined;
                const idx_str = std.fmt.bufPrint(
                    &idx_buf,
                    "{d}",
                    .{col + 1},
                ) catch "";
                try writer.writeAll(idx_str);
                for (0..key_width -| idx_str.len) |_| {
                    try writer.writeByte(' ');
                }
            }
            for (0..pad) |_| try writer.writeByte(' ');

            try writer.writeAll(
                pt.Separator.get(mode, .Text, .Sep),
            );

            // Value column.
            const raw = getField(row, col, col_filter);
            const text = truncate(raw, max_cell_width);
            const ellipsis = needsEllipsis(raw, max_cell_width);
            const visual_len = text.len +
                @as(usize, if (ellipsis) 1 else 0);
            for (0..pad) |_| try writer.writeByte(' ');
            try writer.writeAll(text);
            if (ellipsis) try writer.writeAll("\xe2\x80\xa6");
            for (0..val_width -| visual_len + pad) |_| {
                try writer.writeByte(' ');
            }

            try writer.writeAll(
                pt.Separator.get(mode, .Text, .Last),
            );
            try writer.writeAll("\n");
        }
        try writeHLine(writer, mode, .Last, &col_widths);
    }
}

fn numDigits(n: usize) usize {
    if (n == 0) return 1;
    var val = n;
    var digits: usize = 0;
    while (val > 0) : (val /= 10) digits += 1;
    return digits;
}

// -- CSV parsing -------------------------------------------------

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

    while (pos < line.len and col < num_fields) {
        if (line[pos] == '"') {
            // Quoted field: skip opening quote.
            pos += 1;
            const field_start = pos;
            while (pos < line.len) {
                if (line[pos] == '"') {
                    // Escaped quote ("") — skip both.
                    if (pos + 1 < line.len and line[pos + 1] == '"') {
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
            if (pos < line.len and line[pos] == '"') pos += 1;
            if (pos < line.len and line[pos] == delim) pos += 1;
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
