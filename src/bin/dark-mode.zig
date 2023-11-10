//! Dark mode status, built for macOS.
//!
const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");

// https://saagarjha.com/blog/2018/12/01/scheduling-dark-mode/
extern "c" fn SLSSetAppearanceThemeLegacy(bool) void;
extern "c" fn SLSGetAppearanceThemeLegacy() bool;

const Command = enum {
    Status,
    On,
    Off,
    Toggle,

    const FromString = std.ComptimeStringMap(@This(), .{
        .{ "status", .Status },
        .{ "on", .On },
        .{ "off", .Off },
        .{ "toggle", .Toggle },
    });
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = try simargs.parse(allocator, struct {
        version: bool = false,
        help: bool = false,

        pub const __shorts__ = .{
            .version = .v,
            .help = .h,
        };

        pub const __messages__ = .{
            .help = "Print help information",
            .version = "Print version",
        };
    },
        \\<command>
        \\
        \\ Available commands:
        \\   status                   View dark mode status
        \\   on                       Turn dark mode on
        \\   off                      Turn dark mode off
        \\   toggle                   Toggle dark mode
    , util.get_build_info());
    defer opt.deinit();

    var args_iter = util.SliceIter([]const u8).init(opt.positional_args.items);
    const cmd: Command = if (args_iter.next()) |v|
        Command.FromString.get(v) orelse return error.UnknownCommand
    else
        .Status;

    switch (cmd) {
        .Status => {
            const is_dark = SLSGetAppearanceThemeLegacy();
            if (is_dark) {
                std.debug.print("on", .{});
            } else {
                std.debug.print("off", .{});
            }
        },
        .On => {
            SLSSetAppearanceThemeLegacy(true);
        },
        .Off => {
            SLSSetAppearanceThemeLegacy(false);
        },
        .Toggle => {
            const is_dark = SLSGetAppearanceThemeLegacy();
            SLSSetAppearanceThemeLegacy(!is_dark);
        },
    }
}
