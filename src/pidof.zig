//! Pidof for macOS

const std = @import("std");
const simargs = @import("simargs");
const c = @cImport({
    @cInclude("sys/sysctl.h");
});

pub const Options = struct {
    separator: []const u8 = " ",
    help: bool = false,

    pub const __shorts__ = .{
        .separator = .s,
        .help = .h,
    };
    pub const __messages__ = .{
        .separator = "Use separator as a separator put between pids.",
        .help = "Print help message.",
    };
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = try simargs.parse(allocator, Options, "[program]");
    defer opt.deinit();

    if (opt.positional_args.items.len == 0) {
        std.debug.print("program is not given\n", .{});
        std.os.exit(1);
    }

    const program = opt.positional_args.items[0];
    var mib = [_]c_int{
        c.CTL_KERN,
        c.KERN_PROC,
        c.KERN_PROC_ALL,
    };
    var procSize: usize = 0;
    var rc = c.sysctl(&mib, mib.len, null, &procSize, null, 0);
    if (rc != 0) {
        std.debug.print("get proc size, err:{any}\n", .{std.c.getErrno(rc)});
        return error.sysctl;
    }
    var procList = try allocator.alloc(c.struct_kinfo_proc, procSize / @sizeOf(c.struct_kinfo_proc));
    rc = c.sysctl(&mib, mib.len, @ptrCast(*anyopaque, procList), &procSize, null, 0);
    if (rc != 0) {
        std.debug.print("get proc list failed, err:{any}\n", .{std.c.getErrno(rc)});
        return error.sysctl;
    }

    // procSize may change between two call of sysctl, so we cannot iterate
    // procList directly with for(procList) |proc|.
    var pids = std.ArrayList(c.pid_t).init(allocator);
    for (0..procSize / @sizeOf(c.struct_kinfo_proc)) |i| {
        const proc = procList[i];
        // p_comm is [17]u8
        const name = std.mem.sliceTo(&proc.kp_proc.p_comm, 0);
        if (program.len >= name.len) {
            if (std.mem.eql(u8, name, program[0..name.len])) {
                try pids.append(proc.kp_proc.p_pid);
            }
        }
    }
    if (pids.items.len == 0) {
        // std.debug.print("{s} not found\n", .{program});
        std.os.exit(1);
    }

    var stdout = std.io.getStdOut().writer();
    for (pids.items, 0..) |pid, i| {
        if (i > 0) {
            try stdout.writeAll(opt.args.separator);
        }
        try stdout.print("{d}", .{pid});
    }
}
