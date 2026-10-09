// @cInclude("libproc.h"); contains mach/message.h, which contains bitfield structs,
// which are not supported by Zig. So we include the functions we need manually.

pub extern fn proc_listpids(
    @"type": u32,
    typeinfo: u32,
    buffer: ?*anyopaque,
    buffersize: c_int,
) c_int;
pub extern fn proc_name(pid: c_int, buffer: ?*anyopaque, buffersize: u32) c_int;
pub extern fn proc_pidinfo(
    pid: c_int,
    flavor: c_int,
    arg: u64,
    buffer: ?*anyopaque,
    buffersize: c_int,
) c_int;
pub extern fn proc_pidfdinfo(
    pid: c_int,
    fd: c_int,
    flavor: c_int,
    buffer: ?*anyopaque,
    buffersize: c_int,
) c_int;

pub const rusage_info_t = ?*anyopaque;
pub extern fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: [*c]rusage_info_t) c_int;
pub extern fn proc_pidpath(pid: c_int, buffer: ?*anyopaque, buffersize: u32) c_int;
