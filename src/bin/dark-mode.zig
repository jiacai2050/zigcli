//! Dark mode status, built for macOS.
//!
const std = @import("std");
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const util = @import("util.zig");

// https://saagarjha.com/blog/2018/12/01/scheduling-dark-mode/
extern "c" fn SLSSetAppearanceThemeLegacy(bool) void;
extern "c" fn SLSGetAppearanceThemeLegacy() bool;

pub fn main(init: std.process.Init) !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try structargs.parse(allocator, init.io, init.minimal.args, struct {
        version: bool = false,
        help: bool = false,

        __commands__: union(enum) {
            on: struct {},
            off: struct {},
            toggle: struct {},
            status: struct {},

            pub const __messages__ = .{
                .on = "Turn dark mode on",
                .off = "Turn dark mode off",
                .toggle = "Toggle dark mode",
                .status = "View dark mode status (default)",
            };
        } = .{ .status = .{} },

        pub const __shorts__ = .{
            .version = .v,
            .help = .h,
        };
        pub const __messages__ = .{
            .help = "Print help information",
            .version = "Print version",
        };
    }, .{ .version_string = util.get_build_info() });
    defer opt.deinit();

    switch (opt.options.__commands__) {
        .status => {
            const is_dark = SLSGetAppearanceThemeLegacy();
            if (is_dark) {
                std.debug.print("on", .{});
            } else {
                std.debug.print("off", .{});
            }
        },
        .on => {
            SLSSetAppearanceThemeLegacy(true);
        },
        .off => {
            SLSSetAppearanceThemeLegacy(false);
        },
        .toggle => {
            const is_dark = SLSGetAppearanceThemeLegacy();
            SLSSetAppearanceThemeLegacy(!is_dark);
        },
    }
}
