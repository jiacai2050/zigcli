//! term provides terminal styling and capability helpers.

const builtin = @import("builtin");
const std = @import("std");

/// ANSI text styling that can be composed from weight, emphasis, and colors.
pub const Style = struct {
    /// ANSI terminal colors.
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

        /// Writes the ANSI escape code for this foreground color.
        /// Use as `try writer.print("{f}", .{color})`.
        pub fn format(self: Color, writer: *std.Io.Writer) !void {
            try writer.writeAll(self.toEscapeCode());
        }

        /// Formats `fmt` with `args`, wraps the output with this foreground color, and resets afterwards.
        pub fn writeString(self: Color, writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
            try self.format(writer);
            try writer.print(fmt, args);
            try writer.writeAll(Color.reset);
        }
    };

    bold: bool = false,
    italic: bool = false,
    fg: ?Color = null,
    bg: ?Color = null,

    /// Reports whether this style would emit any ANSI escape codes.
    pub fn isPlain(self: Style) bool {
        if (self.bold) {
            return false;
        }
        if (self.italic) {
            return false;
        }
        if (self.fg != null) {
            return false;
        }
        if (self.bg != null) {
            return false;
        }
        return true;
    }

    /// Writes the ANSI escape codes for this style (bold, italic, fg, bg).
    /// Use as `try writer.print("{f}", .{style})`.
    pub fn format(self: Style, writer: *std.Io.Writer) !void {
        if (self.bold) try writer.writeAll("\x1b[1m");
        if (self.italic) try writer.writeAll("\x1b[3m");
        if (self.fg) |fg_color| try writer.writeAll(fg_color.toEscapeCode());
        if (self.bg) |bg_color| try writer.writeAll(bg_color.toBgEscapeCode());
    }

    /// Formats `fmt` with `args`, wraps the output with this style, and resets afterwards.
    pub fn writeString(self: Style, writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.format(writer);
        try writer.print(fmt, args);
        if (!self.isPlain()) try writer.writeAll(Color.reset);
    }
};

/// Reports whether `file` is attached to an interactive terminal.
/// Implemented directly to avoid requiring an `Io` instance: `GetConsoleMode`
/// on Windows, `TIOCGWINSZ` elsewhere.
pub fn isTty(file: std.Io.File) bool {
    if (builtin.os.tag == .windows) {
        var mode: u32 = undefined;
        return GetConsoleMode(file.handle, &mode) != 0;
    }
    if (!@hasDecl(std.posix, "T")) {
        return false;
    }
    var winsize: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(
        file.handle,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&winsize),
    );
    return std.posix.errno(rc) == .SUCCESS;
}

extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: *anyopaque,
    lpMode: *u32,
) callconv(.winapi) i32;

/// Returns the detected terminal width for `file`, or `null` when unavailable.
pub fn terminalWidth(file: std.Io.File) ?u16 {
    if (builtin.os.tag == .windows) {
        return null;
    }

    if (!@hasDecl(std.posix, "T")) {
        return null;
    }

    var winsize: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(
        file.handle,
        std.posix.T.IOCGWINSZ,
        @intFromPtr(&winsize),
    );
    if (std.posix.errno(rc) == .SUCCESS) {
        if (winsize.col > 0) {
            return winsize.col;
        } else {
            return null;
        }
    } else {
        return null;
    }
}

/// Returns the detected terminal width for stdout, or `null` when unavailable.
pub fn stdoutWidth() ?u16 {
    return terminalWidth(std.Io.File.stdout());
}

test "term color escape codes" {
    try std.testing.expectEqualStrings("\x1b[31m", Style.Color.red.toEscapeCode());
    try std.testing.expectEqualStrings("\x1b[106m", Style.Color.bright_cyan.toBgEscapeCode());
    try std.testing.expectEqualStrings("\x1b[0m", Style.Color.reset);
}

test "term color write string" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    try Style.Color.green.writeString(&allocating.writer, "{s}", .{"ok"});

    try std.testing.expectEqualStrings("\x1b[32mok\x1b[0m", allocating.written());
}

test "term style write string" {
    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    const style: Style = .{
        .bold = true,
        .italic = true,
        .fg = .green,
        .bg = .black,
    };
    try style.writeString(&allocating.writer, "{s}", .{"ok"});

    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[3m\x1b[32m\x1b[40mok\x1b[0m",
        allocating.written(),
    );
}
