const std = @import("std");
const c = @cImport({
    @cInclude("objc/objc.h");
    @cInclude("objc/objc-class.h");
});

const Time = extern struct {
    hour: c_int,
    minute: c_int,
};
const Schedule = extern struct {
    from_time: Time,
    to_time: Time,
};

const Status = extern struct {
    active: bool,
    enabled: bool,
    sun_schedule_permitted: bool,
    mode: c_int,
    schedule: Schedule,
    disable_flags: c_ulonglong,
    available: bool,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const clazz = c.objc_getClass("CBBlueLightClient");
    const call0: *fn (c.id, c.SEL) callconv(.C) c.id = @constCast(@ptrCast(&c.objc_msgSend));

    const client = call0(
        call0(@alignCast(@ptrCast(clazz.?)), c.sel_registerName("alloc")),
        // call0((clazz), c.sel_registerName("alloc")),
        c.sel_registerName("init"),
    );

    var status = try allocator.create(Status);
    const call1: *fn (c.id, c.SEL, *Status) callconv(.C) bool =
        @constCast(@ptrCast(&c.objc_msgSend));
    const ret = call1(client, c.sel_registerName("getBlueLightStatus:"), status);

    // printf("ret:%d, enabled: %d", ret, status->enabled);
    std.debug.print("{any}-{any}-{any}\n", .{ clazz, client, ret });
    std.debug.print("status:{any}\n", .{status});
}
