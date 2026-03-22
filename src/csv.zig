//! csv parses delimited text into rows and fields.

const std = @import("std");
const mem = std.mem;

pub const ParseOptions = struct {
    delimiter: u8 = ',',
    skip_empty_lines: bool = false,
};

pub const Document = struct {
    rows: [][]const []const u8,
    num_cols: usize,

    pub fn deinit(self: *Document, allocator: mem.Allocator) void {
        for (self.rows) |row| {
            for (row) |field| {
                allocator.free(field);
            }
            allocator.free(row);
        }
        allocator.free(self.rows);
        self.* = undefined;
    }
};

const ParseError = error{
    InvalidQuotedField,
    InvalidRecordTerminator,
    InconsistentFieldCount,
    UnclosedQuotedField,
};

// The parser walks each byte through these four phases of a CSV field.
// `field_start` expects the first byte of a field, `unquoted_field` consumes plain text,
// `quoted_field` consumes bytes inside `"..."`, and `after_quote` accepts only a delimiter,
// a record terminator, or EOF after a closing quote.
const ParseState = enum {
    field_start,
    unquoted_field,
    quoted_field,
    after_quote,
};

const ParseMode = enum {
    line,
    document,
};

pub fn parseLine(
    allocator: mem.Allocator,
    line: []const u8,
    delimiter: u8,
) ![]const []const u8 {
    var row: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (row.items) |field| {
            allocator.free(field);
        }
        row.deinit(allocator);
    }

    var field_buffer: std.ArrayList(u8) = .empty;
    defer field_buffer.deinit(allocator);

    try parseInput(
        allocator,
        line,
        .{
            .delimiter = delimiter,
        },
        .line,
        &field_buffer,
        &row,
        null,
        null,
    );
    return try row.toOwnedSlice(allocator);
}

pub fn parseDocument(
    allocator: mem.Allocator,
    input: []const u8,
    options: ParseOptions,
) !Document {
    var rows: std.ArrayList([]const []const u8) = .empty;
    errdefer {
        for (rows.items) |row| {
            for (row) |field| {
                allocator.free(field);
            }
            allocator.free(row);
        }
        rows.deinit(allocator);
    }

    var num_cols: usize = 0;
    var row: std.ArrayList([]const u8) = .empty;
    defer {
        for (row.items) |field| {
            allocator.free(field);
        }
        row.deinit(allocator);
    }

    var field_buffer: std.ArrayList(u8) = .empty;
    defer field_buffer.deinit(allocator);

    try parseInput(
        allocator,
        input,
        options,
        .document,
        &field_buffer,
        &row,
        &rows,
        &num_cols,
    );

    return .{
        .rows = try rows.toOwnedSlice(allocator),
        .num_cols = num_cols,
    };
}

fn parseInput(
    allocator: mem.Allocator,
    input: []const u8,
    options: ParseOptions,
    mode: ParseMode,
    field_buffer: *std.ArrayList(u8),
    row: *std.ArrayList([]const u8),
    rows: ?*std.ArrayList([]const []const u8),
    num_cols: ?*usize,
) !void {
    field_buffer.clearRetainingCapacity();
    row.clearRetainingCapacity();

    // `at_record_start` distinguishes a true empty line from a finished record that happened to
    // end at the previous byte. This prevents a trailing newline from creating a phantom row.
    var state: ParseState = .field_start;
    var at_record_start = true;
    var index: usize = 0;
    while (index < input.len) {
        const byte = input[index];
        // The state machine is byte-oriented so RFC 4180 edge cases stay local to the state that
        // owns them, rather than being spread across unrelated boolean branches.
        switch (state) {
            .field_start => {
                if (byte == '"') {
                    state = .quoted_field;
                    at_record_start = false;
                    index += 1;
                    continue;
                }

                if (byte == options.delimiter) {
                    try appendField(allocator, field_buffer, row);
                    at_record_start = false;
                    index += 1;
                    continue;
                }

                if (byte == '\r') {
                    if (mode == .line) {
                        return ParseError.InvalidRecordTerminator;
                    }

                    if (index + 1 < input.len and input[index + 1] == '\n') {
                        if (!options.skip_empty_lines or !at_record_start) {
                            try appendField(allocator, field_buffer, row);
                            try appendDocumentRow(allocator, rows, num_cols, row);
                        }

                        at_record_start = true;
                        index += 2;
                        continue;
                    }

                    return ParseError.InvalidRecordTerminator;
                }

                if (byte == '\n') {
                    if (mode == .line) {
                        return ParseError.InvalidRecordTerminator;
                    }

                    if (!options.skip_empty_lines or !at_record_start) {
                        try appendField(allocator, field_buffer, row);
                        try appendDocumentRow(allocator, rows, num_cols, row);
                    }

                    at_record_start = true;
                    index += 1;
                    continue;
                }

                try field_buffer.append(allocator, byte);
                state = .unquoted_field;
                at_record_start = false;
                index += 1;
                continue;
            },
            .unquoted_field => {
                if (byte == options.delimiter) {
                    try appendField(allocator, field_buffer, row);
                    state = .field_start;
                    index += 1;
                    continue;
                }

                if (byte == '"') {
                    return ParseError.InvalidQuotedField;
                }

                if (byte == '\r') {
                    if (mode == .line) {
                        return ParseError.InvalidRecordTerminator;
                    }

                    if (index + 1 < input.len and input[index + 1] == '\n') {
                        try appendField(allocator, field_buffer, row);
                        try appendDocumentRow(allocator, rows, num_cols, row);
                        state = .field_start;
                        at_record_start = true;
                        index += 2;
                        continue;
                    }

                    return ParseError.InvalidRecordTerminator;
                }

                if (byte == '\n') {
                    if (mode == .line) {
                        return ParseError.InvalidRecordTerminator;
                    }

                    try appendField(allocator, field_buffer, row);
                    try appendDocumentRow(allocator, rows, num_cols, row);
                    state = .field_start;
                    at_record_start = true;
                    index += 1;
                    continue;
                }

                try field_buffer.append(allocator, byte);
                index += 1;
                continue;
            },
            .quoted_field => {
                if (byte == '"') {
                    if (index + 1 < input.len and input[index + 1] == '"') {
                        try field_buffer.append(allocator, '"');
                        index += 2;
                        continue;
                    }

                    state = .after_quote;
                    index += 1;
                    continue;
                }

                try field_buffer.append(allocator, byte);
                index += 1;
                continue;
            },
            .after_quote => {
                if (byte == options.delimiter) {
                    try appendField(allocator, field_buffer, row);
                    state = .field_start;
                    index += 1;
                    continue;
                }

                if (byte == '\r') {
                    if (mode == .line) {
                        return ParseError.InvalidRecordTerminator;
                    }

                    if (index + 1 < input.len and input[index + 1] == '\n') {
                        try appendField(allocator, field_buffer, row);
                        try appendDocumentRow(allocator, rows, num_cols, row);
                        state = .field_start;
                        at_record_start = true;
                        index += 2;
                        continue;
                    }

                    return ParseError.InvalidRecordTerminator;
                }

                if (byte == '\n') {
                    if (mode == .line) {
                        return ParseError.InvalidRecordTerminator;
                    }

                    try appendField(allocator, field_buffer, row);
                    try appendDocumentRow(allocator, rows, num_cols, row);
                    state = .field_start;
                    at_record_start = true;
                    index += 1;
                    continue;
                }

                return ParseError.InvalidQuotedField;
            },
        }
    }

    switch (state) {
        .quoted_field => {
            return ParseError.UnclosedQuotedField;
        },
        .field_start => {
            if (!at_record_start) {
                try appendField(allocator, field_buffer, row);
                if (mode == .document) {
                    try appendDocumentRow(allocator, rows, num_cols, row);
                }
            }
        },
        .unquoted_field, .after_quote => {
            try appendField(allocator, field_buffer, row);
            if (mode == .document) {
                try appendDocumentRow(allocator, rows, num_cols, row);
            }
        },
    }
}

fn appendDocumentRow(
    allocator: mem.Allocator,
    rows: ?*std.ArrayList([]const []const u8),
    num_cols: ?*usize,
    row: *std.ArrayList([]const u8),
) !void {
    if (rows == null or num_cols == null) {
        unreachable;
    }

    try appendRow(
        allocator,
        rows.?,
        row,
        num_cols.?,
    );
}

fn appendField(
    allocator: mem.Allocator,
    field_buffer: *std.ArrayList(u8),
    row: *std.ArrayList([]const u8),
) !void {
    const field = try allocator.dupe(u8, field_buffer.items);
    errdefer allocator.free(field);

    try row.append(allocator, field);
    field_buffer.clearRetainingCapacity();
}

fn appendRow(
    allocator: mem.Allocator,
    rows: *std.ArrayList([]const []const u8),
    row: *std.ArrayList([]const u8),
    num_cols: *usize,
) !void {
    if (num_cols.* != 0 and row.items.len != num_cols.*) {
        return ParseError.InconsistentFieldCount;
    }

    const row_slice = try allocator.dupe([]const u8, row.items);
    errdefer allocator.free(row_slice);

    try rows.append(allocator, row_slice);
    if (num_cols.* == 0) {
        num_cols.* = row_slice.len;
    }
    row.clearRetainingCapacity();
}

test "parseLine keeps delimiters inside quoted fields" {
    const allocator = std.testing.allocator;
    const fields = try parseLine(allocator, "a,\"b,c\",d", ',');
    defer {
        for (fields) |field| {
            allocator.free(field);
        }
        allocator.free(fields);
    }

    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("a", fields[0]);
    try std.testing.expectEqualStrings("b,c", fields[1]);
    try std.testing.expectEqualStrings("d", fields[2]);
}

test "parseDocument skips empty lines" {
    const allocator = std.testing.allocator;
    var document = try parseDocument(allocator, "a,b\r\n\r\n1,2\r\n", .{
        .skip_empty_lines = true,
    });
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), document.rows.len);
    try std.testing.expectEqual(@as(usize, 2), document.num_cols);
    try std.testing.expectEqualStrings("a", document.rows[0][0]);
    try std.testing.expectEqualStrings("2", document.rows[1][1]);
}

test "parseDocument rejects a bare carriage return" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        ParseError.InvalidRecordTerminator,
        parseDocument(allocator, "a,b\rc,d\r\n", .{}),
    );
}

test "parseDocument keeps empty RFC 4180 records by default" {
    const allocator = std.testing.allocator;
    var document = try parseDocument(allocator, "a\r\n\r\nb\r\n", .{});
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), document.rows.len);
    try std.testing.expectEqual(@as(usize, 1), document.rows[1].len);
    try std.testing.expectEqualStrings("", document.rows[1][0]);
}

test "parseLine unescapes doubled quotes" {
    const allocator = std.testing.allocator;
    const fields = try parseLine(allocator, "\"a\"\"b\",c", ',');
    defer {
        for (fields) |field| {
            allocator.free(field);
        }
        allocator.free(fields);
    }

    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("a\"b", fields[0]);
    try std.testing.expectEqualStrings("c", fields[1]);
}

test "parseDocument keeps embedded newlines inside quoted fields" {
    const allocator = std.testing.allocator;
    var document = try parseDocument(
        allocator,
        "name,notes\nalice,\"line 1\nline 2\"\n",
        .{},
    );
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), document.rows.len);
    try std.testing.expectEqual(@as(usize, 2), document.num_cols);
    try std.testing.expectEqualStrings("alice", document.rows[1][0]);
    try std.testing.expectEqualStrings("line 1\nline 2", document.rows[1][1]);
}

test "parseDocument rejects an unclosed quoted field" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        ParseError.UnclosedQuotedField,
        parseDocument(allocator, "name,notes\nalice,\"line 1\nline 2", .{}),
    );
}

test "parseDocument rejects trailing characters after a quoted field" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        ParseError.InvalidQuotedField,
        parseDocument(allocator, "name,notes\r\nalice,\"line 1\"oops\r\n", .{}),
    );
}

test "parseDocument rejects inconsistent field counts" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        ParseError.InconsistentFieldCount,
        parseDocument(allocator, "name,age\r\nalice,30\r\nbob\r\n", .{}),
    );
}

test "parseDocument accepts RFC 4180 CRLF records" {
    const allocator = std.testing.allocator;
    var document = try parseDocument(
        allocator,
        "name,notes\r\nalice,\"line 1\r\nline 2\"\r\n",
        .{},
    );
    defer document.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), document.rows.len);
    try std.testing.expectEqualStrings("line 1\r\nline 2", document.rows[1][1]);
}
