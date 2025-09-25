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
    delimiter: []const u8 = " ",
    strict: bool = false,
    user_only: bool = false,
    version: bool = false,
    help: bool = false,

    pub const __shorts__ = .{
        .single = .s,
        .delimiter = .d,
        .strict = .S,
        .user_only = .u,
        .version = .v,
        .help = .h,
    };
    pub const __messages__ = .{
        .single = "Only return the first matching pid.",
        .delimiter = "Delimiter used if more than one PID is shown.",
        .strict = "Case sensitive when matching program name.",
        .user_only = "Only show process belonging to current user.",
        .version = "Print version.",
        .help = "Print help message.",
    };
};

pub fn searchPids(allocator: std.mem.Allocator, opt: Options, program: []const u8) !std.ArrayList(c.pid_t) {
    var mib = [_]c_int{
        c.CTL_KERN,
        c.KERN_PROC,
        c.KERN_PROC_ALL,
    };
    var procSize: usize = 0;
    // sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
    var rc = c.sysctl(&mib, mib.len, null, &procSize, null, 0);
    if (rc != 0) {
        std.log.err("get proc size, err:{any}", .{std.posix.errno(rc)});
        return error.sysctl;
    }

    const procList = try allocator.alloc(c.struct_kinfo_proc, procSize / @sizeOf(c.struct_kinfo_proc));
    // https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/sysctl.3.html
    rc = c.sysctl(&mib, mib.len, @ptrCast(procList), &procSize, null, 0);
    if (rc != 0) {
        std.log.err("get proc list failed, err:{any}", .{std.posix.errno(rc)});
        return error.sysctl;
    }

    // procSize may change between two calls of sysctl, so we cannot iterate
    // procList directly with for(procList) |proc|.
    var pids: std.ArrayList(c.pid_t) = .empty;
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

        const name = std.mem.sliceTo(&proc.kp_proc.p_comm, 0);
        if (opt.strict) {
            if (std.mem.eql(u8, name, program)) {
                try pids.append(allocator, proc.kp_proc.p_pid);
            }
        } else {
            if (std.ascii.eqlIgnoreCase(name, program)) {
                try pids.append(allocator, proc.kp_proc.p_pid);
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

    if (opt.positional_args.len == 0) {
        std.log.err("program is not given", .{});
        std.posix.exit(1);
    }

    const program = opt.positional_args[0];
    const pids = try searchPids(allocator, opt.args, program);
    if (pids.items.len == 0) {
        std.posix.exit(1);
    }

    var stdout = std.fs.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer = stdout.writer(&buf);
    for (pids.items, 0..) |pid, i| {
        if (i > 0) {
            try writer.interface.writeAll(opt.args.delimiter);
        }
        try writer.interface.print("{d}", .{pid});
    }
    try writer.interface.flush();
}
