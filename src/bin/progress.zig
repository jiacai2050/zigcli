//! Progress - Coreutils Progress Viewer
//! Port of https://github.com/Xfennec/progress
//! Shows progress of running coreutils-like operations by monitoring processes.
//! Supported platforms: Linux (via /proc), macOS (via libproc).

const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const builtin = @import("builtin");
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;
const time = std.time;
const testing = std.testing;

/// Default commands to monitor, matching the original progress tool.
const DEFAULT_COMMANDS = [_][]const u8{
    "cp",
    "mv",
    "dd",
    "tar",
    "cat",
    "rsync",
    "grep",
    "fgrep",
    "egrep",
    "cut",
    "sort",
    "md5sum",
    "sha1sum",
    "sha224sum",
    "sha256sum",
    "sha384sum",
    "sha512sum",
    "adb",
    "gzip",
    "gunzip",
    "bzip2",
    "bunzip2",
    "xz",
    "unxz",
    "lzma",
    "unlzma",
    "7z",
    "7za",
    "zcat",
    "bzcat",
    "lzcat",
};

const Options = struct {
    monitor: bool = false,
    pid: ?[]const u8 = null,
    command: ?[]const u8 = null,
    @"wait-delay": u64 = 0,
    @"throughput-wait-time": u64 = 1,
    @"no-color": bool = false,
    verbose: bool = false,
    quiet: bool = false,
    wait: bool = false,
    version: bool = false,
    help: bool = false,

    pub const __shorts__ = .{
        .monitor = .m,
        .pid = .p,
        .command = .c,
        .@"wait-delay" = .W,
        .@"throughput-wait-time" = .t,
        .@"no-color" = .n,
        .verbose = .v,
        .quiet = .q,
        .wait = .w,
        .version = .V,
        .help = .h,
    };

    pub const __messages__ = .{
        .monitor = "Loop while monitored processes are running.",
        .pid = "Comma-separated list of PIDs to monitor.",
        .command = "Comma-separated list of commands to monitor.",
        .@"wait-delay" = "Time to wait (seconds) for processes to start.",
        .@"throughput-wait-time" = "Time (seconds) for throughput calculation.",
        .@"no-color" = "Disable color output.",
        .verbose = "Show extra info (fd number).",
        .quiet = "Quiet mode, output only percentages.",
        .wait = "Wait for processes to start.",
        .version = "Print version.",
        .help = "Print help information.",
    };
};

/// Represents progress for one open file in a monitored process.
const FileInfo = struct {
    pid: u32,
    fd: u32,
    /// Process command name (owned by caller's allocator).
    comm: []const u8,
    /// Resolved file path (owned by caller's allocator).
    path: []const u8,
    position: u64,
    size: u64,

    fn percentage(self: FileInfo) f64 {
        if (self.size == 0) return 0.0;
        return @as(f64, @floatFromInt(self.position)) /
            @as(f64, @floatFromInt(self.size)) * 100.0;
    }
};

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try simargs.parse(allocator, Options, .{
        .argument_prompt = "",
        .version_string = util.get_build_info(),
    });
    defer opt.deinit();

    const options = opt.options;

    // Build PID filter list.
    var pid_list: std.ArrayList(u32) = .empty;
    defer pid_list.deinit(allocator);
    if (options.pid) |pid_str| {
        var it = mem.splitScalar(u8, pid_str, ',');
        while (it.next()) |s| {
            const trimmed = mem.trim(u8, s, " ");
            if (trimmed.len == 0) continue;
            const pid = fmt.parseInt(u32, trimmed, 10) catch {
                std.log.warn("Invalid PID ignored: {s}", .{trimmed});
                continue;
            };
            try pid_list.append(allocator, pid);
        }
    }

    // Build command filter list.
    var cmd_list: std.ArrayList([]const u8) = .empty;
    defer cmd_list.deinit(allocator);
    if (options.command) |cmd_str| {
        var it = mem.splitScalar(u8, cmd_str, ',');
        while (it.next()) |s| {
            const trimmed = mem.trim(u8, s, " ");
            if (trimmed.len == 0) continue;
            try cmd_list.append(allocator, trimmed);
        }
    } else if (pid_list.items.len == 0) {
        // Default: monitor common coreutils commands.
        try cmd_list.appendSlice(allocator, &DEFAULT_COMMANDS);
    }

    const pid_filter: ?[]const u32 = if (pid_list.items.len > 0) pid_list.items else null;

    const stdout = std.fs.File.stdout();
    var stdout_buf: [8192]u8 = undefined;
    var writer = stdout.writer(&stdout_buf);

    if (options.monitor) {
        // Loop until no more matching processes are running.
        while (true) {
            const found = try runOnce(
                allocator,
                &writer.interface,
                pid_filter,
                cmd_list.items,
                options,
            );
            try writer.interface.flush();
            if (!found) break;
        }
    } else {
        // Wait mode: poll until processes start, then run once.
        if (options.wait or options.@"wait-delay" > 0) {
            const wait_secs: u64 = if (options.@"wait-delay" > 0) options.@"wait-delay" else 30;
            var elapsed: u64 = 0;
            while (elapsed < wait_secs) {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const snap = try scanProc(arena.allocator(), pid_filter, cmd_list.items);
                if (snap.items.len > 0) break;
                std.Thread.sleep(time.ns_per_s);
                elapsed += 1;
            }
        }
        _ = try runOnce(
            allocator,
            &writer.interface,
            pid_filter,
            cmd_list.items,
            options,
        );
        try writer.interface.flush();
    }
}

/// Run one progress reporting cycle: take two snapshots and display results.
/// Returns true if any matching processes were found.
fn runOnce(
    allocator: mem.Allocator,
    writer: *std.Io.Writer,
    pid_filter: ?[]const u32,
    cmd_filter: []const []const u8,
    options: Options,
) !bool {
    var arena1 = std.heap.ArenaAllocator.init(allocator);
    defer arena1.deinit();
    const snap1 = try scanProc(arena1.allocator(), pid_filter, cmd_filter);
    if (snap1.items.len == 0) return false;

    std.Thread.sleep(options.@"throughput-wait-time" * time.ns_per_s);

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const snap2 = try scanProc(arena2.allocator(), pid_filter, cmd_filter);

    const elapsed_secs: f64 = @as(f64, @floatFromInt(options.@"throughput-wait-time"));
    for (snap2.items) |info| {
        // Look up matching entry in snap1 to calculate throughput.
        var throughput_bps: ?f64 = null;
        for (snap1.items) |prev| {
            if (prev.pid == info.pid and prev.fd == info.fd) {
                const delta = info.position -| prev.position;
                throughput_bps = @as(f64, @floatFromInt(delta)) / elapsed_secs;
                break;
            }
        }
        try displayProgress(writer, info, throughput_bps, options);
    }

    return snap2.items.len > 0;
}

/// Scan running processes and return FileInfo entries for all matching open files.
/// Dispatches to the platform-specific implementation.
fn scanProc(
    allocator: mem.Allocator,
    pid_filter: ?[]const u32,
    cmd_filter: []const []const u8,
) !std.ArrayList(FileInfo) {
    if (builtin.os.tag == .linux) {
        return scanProcLinux(allocator, pid_filter, cmd_filter);
    } else if (builtin.os.tag == .macos) {
        return scanProcMacos(allocator, pid_filter, cmd_filter);
    } else {
        @compileError("progress is only supported on Linux and macOS");
    }
}

/// Scan /proc and return FileInfo entries for all matching processes.
fn scanProcLinux(
    allocator: mem.Allocator,
    pid_filter: ?[]const u32,
    cmd_filter: []const []const u8,
) !std.ArrayList(FileInfo) {
    var results: std.ArrayList(FileInfo) = .empty;

    var proc_dir = fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return results;
    defer proc_dir.close();

    var proc_iter = proc_dir.iterate();
    while (proc_iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const pid = fmt.parseInt(u32, entry.name, 10) catch continue;

        // Check PID filter.
        if (pid_filter) |pids| {
            var pid_found = false;
            for (pids) |p| {
                if (p == pid) {
                    pid_found = true;
                    break;
                }
            }
            if (!pid_found) continue;
        }

        // Read command name.
        var comm_buf: [256]u8 = undefined;
        const comm = readComm(pid, &comm_buf) orelse continue;

        // Apply command filter (only when no PID filter is active).
        if (pid_filter == null and cmd_filter.len > 0) {
            var cmd_found = false;
            for (cmd_filter) |cmd| {
                if (mem.eql(u8, comm, cmd)) {
                    cmd_found = true;
                    break;
                }
            }
            if (!cmd_found) continue;
        }

        // Scan this process's open file descriptors.
        try addFilesForPid(allocator, &results, pid, comm);
    }

    return results;
}

/// Read the command name of a process from /proc/<pid>/comm.
fn readComm(pid: u32, buf: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
    const file = fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const len = file.readAll(buf) catch return null;
    if (len == 0) return null;
    return mem.trim(u8, buf[0..len], " \n\r");
}

/// Scan /proc/<pid>/fd/ and record FileInfo for each interesting open file.
fn addFilesForPid(
    allocator: mem.Allocator,
    results: *std.ArrayList(FileInfo),
    pid: u32,
    comm: []const u8,
) !void {
    var path_buf: [128]u8 = undefined;
    const fd_dir_path = fmt.bufPrint(&path_buf, "/proc/{d}/fd", .{pid}) catch return;
    var fd_dir = fs.openDirAbsolute(fd_dir_path, .{ .iterate = true }) catch return;
    defer fd_dir.close();

    var fd_iter = fd_dir.iterate();
    while (fd_iter.next() catch null) |fd_entry| {
        if (fd_entry.kind != .sym_link) continue;
        const fd_num = fmt.parseInt(u32, fd_entry.name, 10) catch continue;
        try recordFd(allocator, results, pid, fd_num, comm);
    }
}

/// Attempt to record progress for a single file descriptor.
/// Silently returns (without error) if the fd is not an interesting regular file.
/// Only propagates allocator errors.
fn recordFd(
    allocator: mem.Allocator,
    results: *std.ArrayList(FileInfo),
    pid: u32,
    fd: u32,
    comm: []const u8,
) !void {
    // Resolve the fd symlink to get the real file path.
    var link_buf: [64]u8 = undefined;
    const link_path = fmt.bufPrint(&link_buf, "/proc/{d}/fd/{d}", .{ pid, fd }) catch return;
    var target_buf: [fs.max_path_bytes]u8 = undefined;
    const file_path = std.posix.readlink(link_path, &target_buf) catch return;

    // Skip non-filesystem paths (sockets, pipes, anonymous mappings, etc.).
    if (!mem.startsWith(u8, file_path, "/")) return;
    if (mem.startsWith(u8, file_path, "/proc/")) return;
    if (mem.startsWith(u8, file_path, "/sys/")) return;
    if (mem.startsWith(u8, file_path, "/dev/")) return;

    // Open and stat the file to check type and size.
    const real_file = fs.openFileAbsolute(file_path, .{}) catch return;
    defer real_file.close();
    const file_stat = real_file.stat() catch return;
    if (file_stat.kind != .file) return;
    if (file_stat.size == 0) return;

    // Read the current file position from /proc/<pid>/fdinfo/<fd>.
    var fdinfo_path_buf: [96]u8 = undefined;
    const fdinfo_path = fmt.bufPrint(&fdinfo_path_buf, "/proc/{d}/fdinfo/{d}", .{ pid, fd }) catch return;
    const fdinfo_file = fs.openFileAbsolute(fdinfo_path, .{}) catch return;
    defer fdinfo_file.close();
    var fdinfo_buf: [512]u8 = undefined;
    const fdinfo_len = fdinfo_file.readAll(&fdinfo_buf) catch return;

    const position = parseFdinfoPos(fdinfo_buf[0..fdinfo_len]) orelse return;
    // Skip files with no progress or position beyond file size.
    if (position == 0 or position > file_stat.size) return;

    // Allocate strings and record the entry.
    const comm_dup = try allocator.dupe(u8, comm);
    errdefer allocator.free(comm_dup);
    const path_dup = try allocator.dupe(u8, file_path);
    errdefer allocator.free(path_dup);

    try results.append(allocator, .{
        .pid = pid,
        .fd = fd,
        .comm = comm_dup,
        .path = path_dup,
        .position = position,
        .size = file_stat.size,
    });
}

/// Parse the file position from /proc/<pid>/fdinfo/<fd> content.
fn parseFdinfoPos(text: []const u8) ?u64 {
    var lines = mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (mem.startsWith(u8, line, "pos:")) {
            const pos_str = mem.trim(u8, line[4..], " \t");
            return fmt.parseInt(u64, pos_str, 10) catch null;
        }
    }
    return null;
}

/// Scan processes using macOS libproc and return FileInfo entries for all matching open files.
fn scanProcMacos(
    allocator: mem.Allocator,
    pid_filter: ?[]const u32,
    cmd_filter: []const []const u8,
) !std.ArrayList(FileInfo) {
    const c = @cImport({
        @cInclude("libproc.h");
        @cInclude("sys/proc_info.h");
        @cInclude("sys/stat.h");
    });

    var results: std.ArrayList(FileInfo) = .empty;

    // Determine the number of bytes needed for the full PID list.
    const pids_size = c.proc_listpids(c.PROC_ALL_PIDS, 0, null, 0);
    if (pids_size <= 0) return results;

    const pid_buf = try allocator.alloc(c.pid_t, @as(usize, @intCast(pids_size)) / @sizeOf(c.pid_t));
    defer allocator.free(pid_buf);

    const actual_pids_size = c.proc_listpids(c.PROC_ALL_PIDS, 0, @ptrCast(pid_buf.ptr), pids_size);
    if (actual_pids_size <= 0) return results;
    const pid_count = @as(usize, @intCast(actual_pids_size)) / @sizeOf(c.pid_t);

    for (pid_buf[0..pid_count]) |pid| {
        if (pid == 0) continue;
        const pid_u32: u32 = @intCast(pid);

        // Check PID filter.
        if (pid_filter) |pids| {
            var pid_found = false;
            for (pids) |p| {
                if (p == pid_u32) {
                    pid_found = true;
                    break;
                }
            }
            if (!pid_found) continue;
        }

        // Read the command name via libproc.
        var name_buf = std.mem.zeroes([256]u8);
        _ = c.proc_name(pid, @ptrCast(&name_buf), name_buf.len);
        const comm = mem.sliceTo(&name_buf, 0);
        if (comm.len == 0) continue;

        // Apply command filter (only when no PID filter is active).
        if (pid_filter == null and cmd_filter.len > 0) {
            var cmd_found = false;
            for (cmd_filter) |cmd| {
                if (mem.eql(u8, comm, cmd)) {
                    cmd_found = true;
                    break;
                }
            }
            if (!cmd_found) continue;
        }

        // Get the file-descriptor list for this process.
        const fds_size = c.proc_pidinfo(pid, c.PROC_PIDLISTFDS, 0, null, 0);
        if (fds_size <= 0) continue;

        const fd_buf = try allocator.alloc(
            c.struct_proc_fdinfo,
            @as(usize, @intCast(fds_size)) / @sizeOf(c.struct_proc_fdinfo),
        );
        defer allocator.free(fd_buf);

        const actual_fds_size = c.proc_pidinfo(pid, c.PROC_PIDLISTFDS, 0, @ptrCast(fd_buf.ptr), fds_size);
        if (actual_fds_size <= 0) continue;
        const fd_count = @as(usize, @intCast(actual_fds_size)) / @sizeOf(c.struct_proc_fdinfo);

        for (fd_buf[0..fd_count]) |fd_entry| {
            // Only interested in vnode (regular-file) descriptors.
            if (fd_entry.proc_fdtype != c.PROX_FDTYPE_VNODE) continue;

            // Get vnode path info, including the current file seek offset.
            var vnode_info: c.struct_vnode_fdinfowithpath = undefined;
            const vnode_ret = c.proc_pidfdinfo(
                pid,
                fd_entry.proc_fd,
                c.PROC_PIDFDVNODEPATHINFO,
                @ptrCast(&vnode_info),
                @as(c_int, @intCast(@sizeOf(c.struct_vnode_fdinfowithpath))),
            );
            if (vnode_ret <= 0) continue;

            // Extract the null-terminated file path.
            const path_cstr: [*c]const u8 = @ptrCast(&vnode_info.pvip.vip_path);
            const file_path = mem.sliceTo(path_cstr, 0);
            if (file_path.len == 0) continue;
            if (mem.startsWith(u8, file_path, "/dev/")) continue;

            // Stat the file to verify it is a regular file and get its size.
            var stat_buf: c.struct_stat = undefined;
            if (c.stat(path_cstr, &stat_buf) != 0) continue;
            if ((stat_buf.st_mode & c.S_IFMT) != c.S_IFREG) continue;
            if (stat_buf.st_size <= 0) continue;

            // fi_offset is off_t (i64); skip non-positive offsets.
            const file_offset = vnode_info.pfi.fi_offset;
            if (file_offset <= 0) continue;
            const position: u64 = @intCast(file_offset);
            const size: u64 = @intCast(stat_buf.st_size);
            if (position > size) continue;

            const comm_dup = try allocator.dupe(u8, comm);
            errdefer allocator.free(comm_dup);
            const path_dup = try allocator.dupe(u8, file_path);
            errdefer allocator.free(path_dup);

            try results.append(allocator, .{
                .pid = pid_u32,
                .fd = @intCast(fd_entry.proc_fd),
                .comm = comm_dup,
                .path = path_dup,
                .position = position,
                .size = size,
            });
        }
    }

    return results;
}

/// Format a byte count as a human-readable string (e.g. "1.5 MiB").
fn humanSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value: f64 = @floatFromInt(bytes);
    var idx: usize = 0;
    while (value >= 1024.0 and idx < units.len - 1) {
        value /= 1024.0;
        idx += 1;
    }
    return fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[idx] }) catch "?";
}

/// Format a duration in seconds as "M:SS" or "H:MM:SS".
fn formatEta(buf: []u8, seconds: f64) []const u8 {
    const total = @as(u64, @intFromFloat(@max(0, seconds)));
    const hours = total / 3600;
    const mins = (total % 3600) / 60;
    const secs = total % 60;
    if (hours > 0) {
        return fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, mins, secs }) catch "?";
    }
    return fmt.bufPrint(buf, "{d}:{d:0>2}", .{ mins, secs }) catch "?";
}

/// Display progress for one FileInfo entry.
fn displayProgress(
    writer: *std.Io.Writer,
    info: FileInfo,
    throughput_bps: ?f64,
    options: Options,
) !void {
    if (options.quiet) {
        try writer.print("{d:.1}%\n", .{info.percentage()});
        return;
    }

    const use_color = !options.@"no-color";

    // Header line: [pid] command /path/to/file
    if (use_color) try writer.writeAll("\x1b[1m");
    if (options.verbose) {
        try writer.print("[{d}] {s} {s} (fd={d})\n", .{ info.pid, info.comm, info.path, info.fd });
    } else {
        try writer.print("[{d}] {s} {s}\n", .{ info.pid, info.comm, info.path });
    }
    if (use_color) try writer.writeAll("\x1b[0m");

    // Progress detail line.
    var pos_buf: [32]u8 = undefined;
    var size_buf: [32]u8 = undefined;
    const pos_str = humanSize(&pos_buf, info.position);
    const size_str = humanSize(&size_buf, info.size);

    if (throughput_bps) |bps| {
        if (bps > 0 and std.math.isFinite(bps)) {
            var speed_buf: [32]u8 = undefined;
            const speed_str = humanSize(&speed_buf, @intFromFloat(bps));
            const remaining: u64 = info.size -| info.position;
            const eta_secs = @as(f64, @floatFromInt(remaining)) / bps;
            var eta_buf: [32]u8 = undefined;
            const eta_str = formatEta(&eta_buf, eta_secs);
            try writer.print(
                "\t{d:.1}% ({s} / {s}) [{s}/s] ETA {s}\n",
                .{ info.percentage(), pos_str, size_str, speed_str, eta_str },
            );
        } else {
            try writer.print(
                "\t{d:.1}% ({s} / {s}) [stalled]\n",
                .{ info.percentage(), pos_str, size_str },
            );
        }
    } else {
        try writer.print(
            "\t{d:.1}% ({s} / {s})\n",
            .{ info.percentage(), pos_str, size_str },
        );
    }
}

test "parseFdinfoPos basic" {
    const fdinfo = "pos:\t1024\nflags:\t0100002\nmnt_id:\t25\n";
    try testing.expectEqual(@as(?u64, 1024), parseFdinfoPos(fdinfo));
}

test "parseFdinfoPos with spaces" {
    const fdinfo2 = "pos:    2048\nflags: 0\n";
    try testing.expectEqual(@as(?u64, 2048), parseFdinfoPos(fdinfo2));
}

test "parseFdinfoPos missing field" {
    const fdinfo3 = "flags: 0\nmnt_id: 1\n";
    try testing.expectEqual(@as(?u64, null), parseFdinfoPos(fdinfo3));
}

test "humanSize bytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("512.0 B", humanSize(&buf, 512));
}

test "humanSize KiB" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0 KiB", humanSize(&buf, 1024));
}

test "humanSize MiB" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.0 MiB", humanSize(&buf, 1024 * 1024));
}

test "formatEta seconds" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0:00", formatEta(&buf, 0));
    try testing.expectEqualStrings("0:30", formatEta(&buf, 30));
    try testing.expectEqualStrings("1:00", formatEta(&buf, 60));
}

test "formatEta hours" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1:30:00", formatEta(&buf, 5400));
}

test "FileInfo percentage" {
    const info = FileInfo{
        .pid = 1,
        .fd = 3,
        .comm = "cp",
        .path = "/tmp/file",
        .position = 512,
        .size = 1024,
    };
    try testing.expectApproxEqAbs(50.0, info.percentage(), 0.001);
}
