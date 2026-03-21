//! Cowsay in Zig
//! https://en.wikipedia.org/wiki/Cowsay

const std = @import("std");
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const util = @import("util.zig");
const Writer = std.Io.Writer;
const mem = std.mem;
const testing = std.testing;

// The default ASCII cow art.
const cow_art: []const u8 =
    \\        \   ^__^
    \\         \  (oo)\_______
    \\            (__)\       )\/\
    \\                ||----w |
    \\                ||     ||
    \\
;

// The Tux (Linux penguin) ASCII art.
const tux_art: []const u8 =
    \\   \
    \\    \
    \\        .--.
    \\       |o_o |
    \\       |:_/ |
    \\      //   \ \
    \\     (|     | )
    \\    /'\_   _/`\
    \\    \___)=(___/
    \\
;

const CowFace = enum {
    cow,
    tux,
};

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try structargs.parse(allocator, struct {
        face: CowFace = .cow,
        help: bool = false,
        version: bool = false,

        pub const __shorts__ = .{
            .face = .f,
            .help = .h,
            .version = .v,
        };

        pub const __messages__ = .{
            .face = "Which cow face to use (cow, tux). Default: cow.",
            .help = "Print help information.",
            .version = "Print version.",
        };
    }, .{
        .argument_prompt = "[message]",
        .version_string = util.get_build_info(),
    });
    defer opt.deinit();

    // Join all positional arguments with spaces to form the message.
    var message_parts_buf: [4096]u8 = undefined;
    const message: []const u8 = if (opt.positional_arguments.len == 0)
        ""
    else blk: {
        var fbs = std.io.fixedBufferStream(&message_parts_buf);
        const fbs_writer = fbs.writer();
        for (opt.positional_arguments, 0..) |arg, i| {
            if (i > 0) try fbs_writer.writeByte(' ');
            try fbs_writer.writeAll(arg);
        }
        break :blk fbs.getWritten();
    };

    const stdout = std.fs.File.stdout();
    var output_buf: [8192]u8 = undefined;
    var writer = stdout.writer(&output_buf);

    try writeSpeechBubble(&writer.interface, message);

    const art = switch (opt.options.face) {
        .cow => cow_art,
        .tux => tux_art,
    };
    try writer.interface.writeAll(art);
    try writer.interface.flush();
}

/// Renders a speech bubble around the given message to the writer.
/// Single-line messages use `< text >` borders.
/// Multi-line messages use `/`, `|`, `\` borders on the sides.
fn writeSpeechBubble(writer: *Writer, message: []const u8) !void {
    // Collect lines and find the maximum line width.
    var lines_buf: [64][]const u8 = undefined;
    var line_count: usize = 0;
    var max_width: usize = 0;

    var iter = mem.splitScalar(u8, message, '\n');
    while (iter.next()) |line| {
        if (line_count >= lines_buf.len) break;
        lines_buf[line_count] = line;
        line_count += 1;
        if (line.len > max_width) {
            max_width = line.len;
        }
    }

    const lines = lines_buf[0..line_count];
    // The border width includes one space of padding on each side.
    const border_width = max_width + 2;

    // Write the top border: a space then `border_width` underscores.
    try writer.writeAll(" ");
    for (0..border_width) |_| try writer.writeAll("_");
    try writer.writeAll("\n");

    // Write message lines with box-drawing characters.
    if (lines.len == 1) {
        // Single line: use angle brackets.
        try writer.writeAll("< ");
        try writer.writeAll(lines[0]);
        try writer.writeAll(" >\n");
    } else {
        for (lines, 0..) |line, i| {
            const left = if (i == 0) "/ " else if (i == lines.len - 1) "\\ " else "| ";
            const right = if (i == 0) " \\" else if (i == lines.len - 1) " /" else " |";
            try writer.writeAll(left);
            try writer.writeAll(line);
            // Pad shorter lines to the maximum width so all borders align.
            for (0..max_width - line.len) |_| try writer.writeAll(" ");
            try writer.writeAll(right);
            try writer.writeAll("\n");
        }
    }

    // Write the bottom border: a space then `border_width` dashes.
    try writer.writeAll(" ");
    for (0..border_width) |_| try writer.writeAll("-");
    try writer.writeAll("\n");
}

test "speech bubble single line" {
    // A single-line message should use '< text >' delimiters.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeSpeechBubble(&aw.writer, "hi");

    try testing.expectEqualStrings(
        \\ ____
        \\< hi >
        \\ ----
        \\
    , aw.written());
}

test "speech bubble multi line" {
    // A multi-line message should use '/', '|', '\' delimiters.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeSpeechBubble(&aw.writer, "hello\nworld");

    try testing.expectEqualStrings(
        \\ _______
        \\/ hello \
        \\\ world /
        \\ -------
        \\
    , aw.written());
}

test "speech bubble three lines" {
    // Middle lines should use '|' delimiters; first is '/', last is '\'.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeSpeechBubble(&aw.writer, "one\ntwo\nthree");

    try testing.expectEqualStrings(
        \\ _______
        \\/ one   \
        \\| two   |
        \\\ three /
        \\ -------
        \\
    , aw.written());
}
