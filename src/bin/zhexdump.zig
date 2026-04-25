//! zhexdump: color-coded hex dump of files or stdin.

const std = @import("std");
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const term = zigcli.term;
const util = @import("util.zig");

const Options = struct {
    length: ?usize = null,
    skip: ?usize = null,
    @"no-color": bool = false,
    help: bool = false,
    version: bool = false,

    pub const __shorts__ = .{
        .length = .n,
        .skip = .s,
        .@"no-color" = .C,
        .help = .h,
        .version = .v,
    };

    pub const __messages__ = .{
        .length = "Only read N bytes.",
        .skip = "Skip N bytes from the start.",
        .@"no-color" = "Disable color output.",
        .help = "Print help information.",
        .version = "Print version.",
    };
};

fn byteColor(byte: u8) term.Style.Color {
    return switch (byte) {
        0x00 => .bright_black,
        0xFF => .bright_white,
        0x09, 0x0A, 0x0D, 0x20 => .yellow,
        0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => .red,
        0x21...0x4F => .green,
        0x50...0x7E => .bright_green,
        0x80...0xBF => .blue,
        0xC0...0xEF => .bright_blue,
        0xF0...0xFE => .magenta,
    };
}

pub fn main(init: std.process.Init) anyerror!void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try structargs.parse(
        allocator,
        init.io,
        init.minimal.args,
        Options,
        .{
            .argument_prompt = "[file]",
            .version_string = util.get_build_info(),
        },
    );
    defer opt.deinit();
}

const testing = std.testing;

test "byteColor null byte" {
    try testing.expectEqual(term.Style.Color.bright_black, byteColor(0x00));
}

test "byteColor FF byte" {
    try testing.expectEqual(term.Style.Color.bright_white, byteColor(0xFF));
}

test "byteColor whitespace" {
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0x0A)); // newline
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0x20)); // space
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0x09)); // tab
    try testing.expectEqual(term.Style.Color.yellow, byteColor(0x0D)); // CR
}

test "byteColor control chars" {
    try testing.expectEqual(term.Style.Color.red, byteColor(0x01));
    try testing.expectEqual(term.Style.Color.red, byteColor(0x7F)); // DEL
}

test "byteColor printable ASCII low" {
    try testing.expectEqual(term.Style.Color.green, byteColor(0x21)); // '!'
    try testing.expectEqual(term.Style.Color.green, byteColor(0x41)); // 'A'
    try testing.expectEqual(term.Style.Color.green, byteColor(0x4F)); // 'O'
}

test "byteColor printable ASCII high" {
    try testing.expectEqual(term.Style.Color.bright_green, byteColor(0x50)); // 'P'
    try testing.expectEqual(term.Style.Color.bright_green, byteColor(0x7E)); // '~'
}

test "byteColor high bytes" {
    try testing.expectEqual(term.Style.Color.blue, byteColor(0x80));
    try testing.expectEqual(term.Style.Color.blue, byteColor(0xBF));
    try testing.expectEqual(term.Style.Color.bright_blue, byteColor(0xC0));
    try testing.expectEqual(term.Style.Color.bright_blue, byteColor(0xEF));
    try testing.expectEqual(term.Style.Color.magenta, byteColor(0xF0));
    try testing.expectEqual(term.Style.Color.magenta, byteColor(0xFE));
}
