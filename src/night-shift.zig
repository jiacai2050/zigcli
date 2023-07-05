//! Control Night shift in cli, build for macOS.
//!
const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const c = @cImport({
    @cInclude("objc/objc.h");
    @cInclude("objc/message.h");
});

const Time = extern struct {
    hour: c_int,
    minute: c_int,

    fn fromString(hhmm: []const u8) !@This() {
        var iter = std.mem.splitSequence(u8, hhmm, ":");
        const hour = iter.next() orelse return error.MissingHour;
        const minute = iter.next() orelse return error.MissingMinute;

        return .{
            .hour = std.fmt.parseInt(c_int, hour, 10) catch return error.InvalidHour,
            .minute = std.fmt.parseInt(c_int, minute, 10) catch return error.InvalidMinute,
        };
    }
};

const CustomSchedule = extern struct {
    from_time: Time,
    to_time: Time,
};

const Schedule = union(enum) {
    // false means schedule is off
    SunSetToSunRise: bool,
    Custom: CustomSchedule,

    fn toMode(self: @This()) c_int {
        return switch (self) {
            .SunSetToSunRise => |v| if (v) 1 else 0,
            .Custom => 2,
        };
    }
};

// Refer https://github.com/smudge/nightlight/blob/03595a642f0876388db11b9f5a3bd8261ab178d5/src/macos/status.rs#L21
const Status = extern struct {
    active: bool,
    enabled: bool,
    sun_schedule_permitted: bool,
    mode: c_int,
    custom_schedule: CustomSchedule,
    disable_flags: c_ulonglong,
    available: bool,

    const Self = @This();

    fn formatSchedule(self: Self, buf: []u8) ![]const u8 {
        return switch (self.mode) {
            0 => "Off",
            1 => "SunsetToSunrise",
            2 => try std.fmt.bufPrint(buf, "Custom({d}:{d}-{d}:{d})", .{
                self.custom_schedule.from_time.hour,
                self.custom_schedule.from_time.minute,
                self.custom_schedule.to_time.hour,
                self.custom_schedule.to_time.minute,
            }),
            else => "Unknown",
        };
    }

    fn display(self: Self, wtr: anytype) !void {
        if (!self.enabled) {
            try wtr.writeAll("Enabled: off");
            return;
        }

        var buf = std.mem.zeroes([32]u8);
        try wtr.print(
            \\Enabled: on
            \\Schedule: {s}
        , .{try self.formatSchedule(&buf)});
    }
};

const Client = struct {
    inner: c.id,
    allocator: std.mem.Allocator,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) Self {
        // https://developer.limneos.net/?ios=14.4&framework=CoreBrightness.framework&header=CBBlueLightClient.h
        const clazz = c.objc_getClass("CBBlueLightClient");
        const call: *fn (c.id, c.SEL) callconv(.C) c.id = @constCast(@ptrCast(&c.objc_msgSend));

        return Self{
            .inner = call(
                call(@alignCast(@ptrCast(clazz.?)), c.sel_registerName("alloc")),
                c.sel_registerName("init"),
            ),
            .allocator = allocator,
        };
    }

    fn getStatus(self: Self) !*Status {
        var status = try self.allocator.create(Status);
        const call: *fn (c.id, c.SEL, *Status) callconv(.C) bool =
            @constCast(@ptrCast(&c.objc_msgSend));
        const ret = call(self.inner, c.sel_registerName("getBlueLightStatus:"), status);
        if (!ret) {
            return error.getBlueLightStatus;
        }

        return status;
    }

    fn setSchedule(self: Self, schedule: Schedule) !void {
        {
            const call: *fn (c.id, c.SEL, c_int) callconv(.C) bool = @constCast(@ptrCast(&c.objc_msgSend));
            const ret = call(self.inner, c.sel_registerName("setMode:"), schedule.toMode());
            if (!ret) {
                return error.setMode;
            }
        }

        switch (schedule) {
            .SunSetToSunRise => {},
            .Custom => |custom| {
                var ptr = try self.allocator.create(CustomSchedule);
                ptr.* = custom;
                const call: *fn (c.id, c.SEL, [*c]CustomSchedule) callconv(.C) bool = @constCast(@ptrCast(&c.objc_msgSend));
                const ret = call(self.inner, c.sel_registerName("setSchedule:"), ptr);
                if (!ret) {
                    return error.setSchedule;
                }
            },
        }
    }

    fn setEnabled(self: Self, enabled: bool) !void {
        const call: *fn (c.id, c.SEL, bool) callconv(.C) bool = @constCast(@ptrCast(&c.objc_msgSend));
        const ret = call(self.inner, c.sel_registerName("setEnabled:"), enabled);
        if (!ret) {
            return error.getStrength;
        }
    }

    fn turnOn(self: Self) !void {
        return self.setEnabled(true);
    }

    fn turnOff(self: Self) !void {
        return self.setEnabled(false);
    }

    fn getStrength(self: Self) !f32 {
        var strength: f32 = 0;
        const call: *fn (c.id, c.SEL, *f32) callconv(.C) bool = @constCast(@ptrCast(&c.objc_msgSend));
        const ret = call(self.inner, c.sel_registerName("getStrength:"), &strength);
        if (!ret) {
            return error.getStrength;
        }

        return strength;
    }

    fn setStrength(self: Self, strength: f32) !void {
        const call: *fn (c.id, c.SEL, f32, bool) callconv(.C) bool = @constCast(@ptrCast(&c.objc_msgSend));
        const ret = call(self.inner, c.sel_registerName("setStrength:commit:"), strength, true);
        if (!ret) {
            return error.setStrength;
        }
    }

    fn destroyStatus(self: Self, status: *Status) void {
        self.allocator.destroy(status);
    }
};

const Command = enum {
    Status,
    On,
    Off,
    Toggle,
    Temp,
    Schedule,

    const FromString = std.ComptimeStringMap(@This(), .{
        .{ "status", .Status },
        .{ "on", .On },
        .{ "off", .Off },
        .{ "toggle", .Toggle },
        .{ "temp", .Temp },
        .{ "schedule", .Schedule },
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
        \\ Available commands by category:
        \\ Manual on/off control:
        \\   status                   View current Night Shift status
        \\   on                       Turn Night Shift on
        \\   off                      Turn Night Shift off
        \\   toggle                   Toggle Night Shift
        \\
        \\ Color temperature:
        \\   temp                     View temperature preference
        \\   temp  <0-100>            Set temperature preference
        \\
        \\ Schedule:
        \\   schedule                 View current schedule
        \\   schedule sun             Start schedule from sunset to sunrise
        \\   schedule off             Stop the current schedule
        \\   schedule <from> <to>     Start a custom schedule(HH:mm, 24-hour format)
    , util.get_build_info());
    defer opt.deinit();

    var args_iter = util.SliceIter([]const u8).init(opt.positional_args.items);
    const cmd: Command = if (args_iter.next()) |v|
        Command.FromString.get(v) orelse return error.UnknownCommand
    else
        .Status;

    const client = Client.init(allocator);
    var wtr = std.io.getStdOut().writer();

    switch (cmd) {
        .Status => {
            var status = try client.getStatus();
            defer client.destroyStatus(status);
            try status.display(wtr);
            if (status.enabled) {
                try wtr.print(
                    \\
                    \\Temperature: {d:.0}
                , .{try client.getStrength() * 100});
            }
        },
        .Temp => {
            if (args_iter.next()) |v| {
                const strength = try std.fmt.parseFloat(f32, v);
                try client.setStrength(strength / 100.0);
            } else {
                const strength = try client.getStrength();
                try wtr.print("{d:.0}\n", .{strength * 100});
            }
        },
        .Toggle => {
            var status = try client.getStatus();
            if (status.enabled) {
                try client.turnOff();
            } else {
                try client.turnOn();
            }
        },
        .On => {
            try client.turnOn();
        },
        .Off => {
            try client.turnOff();
        },
        .Schedule => {
            const sub_cmd = args_iter.next() orelse {
                var status = try client.getStatus();
                defer client.destroyStatus(status);
                var buf = std.mem.zeroes([32]u8);
                try wtr.writeAll(try status.formatSchedule(&buf));
                return;
            };

            if (std.mem.eql(u8, "off", sub_cmd)) {
                try client.setSchedule(.{ .SunSetToSunRise = false });
            } else if (std.mem.eql(u8, "sun", sub_cmd)) {
                try client.setSchedule(.{ .SunSetToSunRise = true });
            } else {
                const from = sub_cmd;
                const to = args_iter.next() orelse return error.MissingTo;
                const schedule = .{ .Custom = .{
                    .from_time = try Time.fromString(from),
                    .to_time = try Time.fromString(to),
                } };
                try client.setSchedule(schedule);
            }
        },
    }
}
