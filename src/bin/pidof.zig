//! Pidof for macOS
//!
//! https://man7.org/linux/man-pages/man1/pidof.1.html

const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const c = @cImport({
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h");
});

pub const Options = struct {
    single: bool = false,
    separator: []const u8 = " ",
    user_only: bool = false,
    version: bool = false,
    help: bool = false,

    pub const __shorts__ = .{
        .single = .s,
        .separator = .S,
        .user_only = .u,
        .version = .v,
        .help = .h,
    };
    pub const __messages__ = .{
        .single = "Single shot - this instructs the program to only return one pid.",
        .separator = "Use separator as a separator put between pids.",
        .user_only = "Only show process belonging to current user.",
        .version = "Print version.",
        .help = "Print help message.",
    };
};

pub fn findPids(allocator: std.mem.Allocator, opt: Options, program: []const u8) !std.ArrayList(c.pid_t) {
    var mib = [_]c_int{
        c.CTL_KERN,
        c.KERN_PROC,
        c.KERN_PROC_ALL,
    };
    var procSize: usize = 0;
    var rc = c.sysctl(&mib, mib.len, null, &procSize, null, 0);
    if (rc != 0) {
        std.debug.print("get proc size, err:{any}", .{std.c.getErrno(rc)});
        return error.sysctl;
    }

    const procList = try allocator.alloc(c.struct_kinfo_proc, procSize / @sizeOf(c.struct_kinfo_proc));
    // https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/sysctl.3.html
    rc = c.sysctl(&mib, mib.len, @ptrCast(procList), &procSize, null, 0);
    if (rc != 0) {
        std.debug.print("get proc list failed, err:{any}", .{std.c.getErrno(rc)});
        return error.sysctl;
    }

    // procSize may change between two calls of sysctl, so we cannot iterate
    // procList directly with for(procList) |proc|.
    var pids = std.ArrayList(c.pid_t).init(allocator);
    const uid = if (opt.user_only) c.getuid() else null;
    for (0..procSize / @sizeOf(c.struct_kinfo_proc)) |i| {
        if (opt.single and pids.items.len == 1) {
            break;
        }
        const proc = procList[i];
        if (uid) |id| {
            if (id != proc.kp_eproc.e_pcred.p_ruid) {
                continue;
            }
        }

        // p_comm is [17]u8
        const name = std.mem.sliceTo(&proc.kp_proc.p_comm, 0);
        if (program.len >= name.len) {
            if (std.mem.eql(u8, name, program[0..name.len])) {
                try pids.append(proc.kp_proc.p_pid);
            }
        }
    }

    return pids;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = try simargs.parse(allocator, Options, "[program]", util.get_build_info());
    defer opt.deinit();

    if (opt.positional_args.items.len == 0) {
        std.debug.print("program is not given", .{});
        std.os.exit(1);
    }

    const program = opt.positional_args.items[0];

    const pids = try findPids(allocator, opt.args, program);
    if (pids.items.len == 0) {
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
