//! Dark mode status, built for macOS.
//!
const std = @import("std");
const c = @cImport({
    @cInclude("objc/objc.h");
    @cInclude("objc/message.h");
});

// https://developer.apple.com/documentation/appkit/nsappearancenamedarkaqua
const darkValue = "NSAppearanceNameDarkAqua";

pub fn main() !void {
    const clazz = c.objc_getClass("NSAppearance");

    const appearanceName = blk: {
        const call: *fn (c.id, c.SEL) callconv(.C) c.id = @constCast(@ptrCast(&c.objc_msgSend));
        const appearance = call(@alignCast(@ptrCast(clazz.?)), c.sel_registerName("currentDrawingAppearance"));
        break :blk call(appearance, c.sel_registerName("name"));
    };

    const appearanceValue = blk: {
        const call: *fn (c.id, c.SEL) callconv(.C) [*c]const u8 = @constCast(@ptrCast(&c.objc_msgSend));
        break :blk call(appearanceName, c.sel_registerName("UTF8String"));
    };

    if (std.mem.eql(u8, darkValue, std.mem.span(appearanceValue.?))) {
        std.debug.print("on", .{});
    } else {
        std.debug.print("off", .{});
    }
}
