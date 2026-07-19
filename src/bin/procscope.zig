//! procscope: monitor CPU, RSS, and energy usage for a macOS process.

const std = @import("std");
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const util = @import("util.zig");
const c = @import("c_procscope");
const fmt = std.fmt;
const testing = std.testing;

const Options = struct {
    interval: u32 = 1,
    count: u32 = 0,
    human: bool = false,
    version: bool = false,
    help: bool = false,

    pub const __shorts__ = .{
        .interval = .i,
        .count = .n,
        .human = .H,
        .version = .v,
        .help = .h,
    };

    pub const __messages__ = .{
        .interval = "Sampling interval in seconds.",
        .count = "Number of samples to print. 0 means keep running.",
        .human = "Format memory sizes with adaptive units.",
        .version = "Print version.",
        .help = "Print help information.",
    };
};

const TaskSample = struct {
    total_user_ns: u64,
    total_system_ns: u64,
    total_cpu_ns: u64,
    virtual_size_bytes: u64,
    resident_size_bytes: u64,
    faults: u64,
    pageins: u64,
    context_switches: u64,
    thread_count: u32,
    running_thread_count: u32,
};

const ProcessSample = struct {
    task: TaskSample,
    energy_nj: u64,
};

const ProcessIdentity = struct {
    executable_path: []const u8,
    command_line: ?[]const u8,
};

const watch_column_widths = struct {
    const cpu = 11;
    const user = 11;
    const system = 11;
    const rss = 14;
    const virt = 14;
    const threads = 9;
    const faults = 11;
    const pageins = 10;
    const csw = 11;
};

pub fn main(init: std.process.Init) !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try structargs.parse(allocator, init.io, init.minimal.args, Options, .{
        .argument_prompt = "pid",
        .version_string = util.get_build_info(),
    });
    defer opt.deinit();

    if (opt.positional_arguments.len == 0) {
        std.log.err("pid is not given", .{});
        std.process.exit(1);
    }

    const pid = parsePid(opt.positional_arguments[0]) catch {
        std.log.err("invalid pid: {s}", .{opt.positional_arguments[0]});
        std.process.exit(1);
    };

    validateOptions(opt.options) catch {
        std.log.err("interval must be greater than 0", .{});
        std.process.exit(1);
    };

    const stdout = std.Io.File.stdout();
    var output_buf: [1024]u8 = undefined;
    var writer = stdout.writer(init.io, &output_buf);

    const identity = try getProcessIdentity(allocator, pid);
    defer {
        allocator.free(identity.executable_path);
        if (identity.command_line) |command_line| {
            allocator.free(command_line);
        }
    }
    try watchProcess(
        init.io,
        &writer.interface,
        pid,
        identity,
        opt.options,
    );
    try writer.interface.flush();
}

fn validateOptions(options: Options) !void {
    if (options.interval == 0) {
        return error.InvalidInterval;
    }
}

fn watchProcess(
    io: std.Io,
    writer: *std.Io.Writer,
    pid: c.pid_t,
    identity: ProcessIdentity,
    options: Options,
) !void {
    try printProcessIdentity(writer, pid, identity);
    try printWatchHeader(writer, options);
    try writer.flush();

    var sample_count: u32 = 0;
    while (true) {
        if (options.count != 0 and sample_count >= options.count) {
            break;
        }

        const sample = try sampleProcess(pid);
        try printWatchMetrics(writer, sample, options);
        try writer.flush();
        sample_count += 1;

        if (options.count != 0 and sample_count >= options.count) {
            break;
        }

        try std.Io.sleep(
            io,
            .{ .nanoseconds = @as(i96, options.interval) * std.time.ns_per_s },
            .awake,
        );
    }
}

fn parsePid(text: []const u8) !c.pid_t {
    const pid = try fmt.parseInt(u32, text, 10);
    if (pid == 0) {
        return error.InvalidPid;
    }
    return @intCast(pid);
}

fn getProcessIdentity(allocator: std.mem.Allocator, pid: c.pid_t) !ProcessIdentity {
    const executable_path = try getExecutablePath(allocator, pid);
    errdefer allocator.free(executable_path);

    const command_line = try getCommandLine(allocator, pid);
    return .{
        .executable_path = executable_path,
        .command_line = command_line,
    };
}

fn getExecutablePath(allocator: std.mem.Allocator, pid: c.pid_t) ![]const u8 {
    var path_buf: [c.PROC_PIDPATHINFO_MAXSIZE]u8 = undefined;
    const path_len = c.proc_pidpath(
        pid,
        @ptrCast(&path_buf),
        c.PROC_PIDPATHINFO_MAXSIZE,
    );
    if (path_len <= 0) {
        return allocator.dupe(u8, "<unavailable>");
    }
    const len: usize = @intCast(path_len);
    return allocator.dupe(u8, std.mem.sliceTo(path_buf[0..len], 0));
}

// Reconstruct argv for a PID from the KERN_PROCARGS2 sysctl buffer on macOS.
fn getCommandLine(allocator: std.mem.Allocator, pid: c.pid_t) !?[]const u8 {
    // Query KERN_PROCARGS2 for this PID to retrieve argc plus the raw argv/env buffer.
    var mib = [_]c_int{
        c.CTL_KERN,
        c.KERN_PROCARGS2,
        pid,
    };
    var args_size: usize = 0;
    if (c.sysctl(&mib, mib.len, null, &args_size, null, 0) != 0) {
        return null;
    }
    if (args_size == 0) {
        return null;
    }

    const args_buf = try allocator.alloc(u8, args_size);
    defer allocator.free(args_buf);

    if (c.sysctl(&mib, mib.len, args_buf.ptr, &args_size, null, 0) != 0) {
        return null;
    }
    if (args_size <= @sizeOf(c_int)) {
        return null;
    }

    const argc = std.mem.bytesToValue(c_int, args_buf[0..@sizeOf(c_int)]);
    if (argc <= 0) {
        return null;
    }

    return try formatCommandLine(allocator, args_buf[0..args_size], @intCast(argc));
}

// KERN_PROCARGS2 layout is: argc, exec_path, NUL padding, argv strings, then env strings.
fn formatCommandLine(
    allocator: std.mem.Allocator,
    procargs: []const u8,
    argc: usize,
) !?[]const u8 {
    if (procargs.len <= @sizeOf(c_int)) {
        return null;
    }

    var index: usize = @sizeOf(c_int);
    while (index < procargs.len and procargs[index] != 0) {
        index += 1;
    }
    if (index == procargs.len) {
        return null;
    }
    // Skip the trailing NULs after exec_path to reach the first argv entry.
    while (index < procargs.len and procargs[index] == 0) {
        index += 1;
    }
    if (index == procargs.len) {
        return null;
    }

    var args = try std.ArrayList([]const u8).initCapacity(allocator, argc);
    defer args.deinit(allocator);

    while (index < procargs.len and args.items.len < argc) {
        const arg = std.mem.sliceTo(procargs[index..], 0);
        if (arg.len == 0) {
            index += 1;
            continue;
        }
        try args.append(allocator, arg);
        index += arg.len + 1;
    }
    if (args.items.len == 0) {
        return null;
    }

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    for (args.items, 0..) |arg, i| {
        if (i > 0) {
            try writer.writer.writeByte(' ');
        }
        try writeShellEscapedArg(&writer.writer, arg);
    }
    return try writer.toOwnedSlice();
}

fn writeShellEscapedArg(writer: *std.Io.Writer, arg: []const u8) !void {
    if (arg.len == 0) {
        try writer.writeAll("''");
        return;
    }
    if (isShellSafe(arg)) {
        try writer.writeAll(arg);
        return;
    }

    try writer.writeByte('\'');
    for (arg) |byte| {
        if (byte == '\'') {
            try writer.writeAll("'\\''");
        } else {
            try writer.writeByte(byte);
        }
    }
    try writer.writeByte('\'');
}

fn isShellSafe(arg: []const u8) bool {
    for (arg) |byte| {
        switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '@', '%', '+', '=', ':', ',', '.', '/', '-' => {},
            else => return false,
        }
    }
    return true;
}

fn sampleProcess(pid: c.pid_t) !ProcessSample {
    const task = try sampleTask(pid);
    const energy_nj = try sampleEnergy(pid);

    return .{
        .task = task,
        .energy_nj = energy_nj,
    };
}

fn sampleTask(pid: c.pid_t) !TaskSample {
    var task_info = std.mem.zeroes(c.struct_proc_taskinfo);
    const got = c.proc_pidinfo(
        pid,
        c.PROC_PIDTASKINFO,
        0,
        @ptrCast(&task_info),
        @as(c_int, @intCast(@sizeOf(c.struct_proc_taskinfo))),
    );
    if (got != @sizeOf(c.struct_proc_taskinfo)) {
        return error.SampleTaskFailed;
    }

    return .{
        .total_user_ns = task_info.pti_total_user,
        .total_system_ns = task_info.pti_total_system,
        .total_cpu_ns = task_info.pti_total_user + task_info.pti_total_system,
        .virtual_size_bytes = task_info.pti_virtual_size,
        .resident_size_bytes = task_info.pti_resident_size,
        .faults = try nonNegativeI32ToU64(task_info.pti_faults),
        .pageins = try nonNegativeI32ToU64(task_info.pti_pageins),
        .context_switches = try nonNegativeI32ToU64(task_info.pti_csw),
        .thread_count = try nonNegativeI32ToU32(task_info.pti_threadnum),
        .running_thread_count = try nonNegativeI32ToU32(task_info.pti_numrunning),
    };
}

fn sampleEnergy(pid: c.pid_t) !u64 {
    var usage_info = std.mem.zeroes(c.struct_rusage_info_v6);
    const ret = c.proc_pid_rusage(
        pid,
        c.RUSAGE_INFO_V6,
        @ptrCast(&usage_info),
    );
    if (ret != 0) {
        return error.SampleEnergyFailed;
    }
    return usage_info.ri_energy_nj;
}

fn cpuSeconds(total_cpu_ns: u64) f64 {
    return @as(f64, @floatFromInt(total_cpu_ns)) / @as(f64, std.time.ns_per_s);
}

fn energyMillijoules(energy_nj: u64) f64 {
    return @as(f64, @floatFromInt(energy_nj)) / 1_000_000.0;
}

fn formatBytes(buf: []u8, bytes: u64) ![]const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value = @as(f64, @floatFromInt(bytes));
    var unit_index: usize = 0;
    while (value >= 1024.0 and unit_index < units.len - 1) {
        value /= 1024.0;
        unit_index += 1;
    }
    if (unit_index == 0) {
        return fmt.bufPrint(buf, "{d}{s}", .{ bytes, units[unit_index] });
    }
    return fmt.bufPrint(buf, "{d:.1}{s}", .{ value, units[unit_index] });
}

fn nonNegativeI32ToU64(value: i32) !u64 {
    if (value < 0) {
        return error.InvalidTaskInfo;
    }
    return @intCast(value);
}

fn nonNegativeI32ToU32(value: i32) !u32 {
    if (value < 0) {
        return error.InvalidTaskInfo;
    }
    return @intCast(value);
}

fn printProcessIdentity(
    writer: *std.Io.Writer,
    pid: c.pid_t,
    identity: ProcessIdentity,
) !void {
    try writer.print("Process ID: {d}\n", .{pid});
    if (identity.command_line) |command_line| {
        try writer.print("Command Line: {s}\n", .{command_line});
    } else {
        try writer.print("Executable Path: {s}\n", .{identity.executable_path});
    }
}

fn printWatchMetrics(writer: *std.Io.Writer, sample: ProcessSample, options: Options) !void {
    var rss_buf: [32]u8 = undefined;
    var virt_buf: [32]u8 = undefined;
    var threads_buf: [32]u8 = undefined;
    var faults_buf: [32]u8 = undefined;
    var pageins_buf: [32]u8 = undefined;
    var csw_buf: [32]u8 = undefined;
    var cpu_total_buf: [32]u8 = undefined;
    var cpu_user_buf: [32]u8 = undefined;
    var cpu_system_buf: [32]u8 = undefined;
    var energy_buf: [32]u8 = undefined;

    const rss_text = if (options.human)
        try formatBytes(&rss_buf, sample.task.resident_size_bytes)
    else
        try fmt.bufPrint(&rss_buf, "{d}", .{sample.task.resident_size_bytes});
    const virt_text = if (options.human)
        try formatBytes(&virt_buf, sample.task.virtual_size_bytes)
    else
        try fmt.bufPrint(&virt_buf, "{d}", .{sample.task.virtual_size_bytes});
    const threads_text = try fmt.bufPrint(
        &threads_buf,
        "{d}/{d}",
        .{ sample.task.running_thread_count, sample.task.thread_count },
    );
    const faults_text = try fmt.bufPrint(&faults_buf, "{d}", .{sample.task.faults});
    const pageins_text = try fmt.bufPrint(&pageins_buf, "{d}", .{sample.task.pageins});
    const csw_text = try fmt.bufPrint(&csw_buf, "{d}", .{sample.task.context_switches});
    const cpu_total_text = try fmt.bufPrint(&cpu_total_buf, "{d:.3}", .{cpuSeconds(sample.task.total_cpu_ns)});
    const cpu_user_text = try fmt.bufPrint(&cpu_user_buf, "{d:.3}", .{cpuSeconds(sample.task.total_user_ns)});
    const cpu_system_text = try fmt.bufPrint(&cpu_system_buf, "{d:.3}", .{cpuSeconds(sample.task.total_system_ns)});
    const energy_text = try fmt.bufPrint(&energy_buf, "{d:.3}", .{energyMillijoules(sample.energy_nj)});

    try writeWatchColumn(writer, cpu_total_text, watch_column_widths.cpu);
    try writeWatchColumn(writer, cpu_user_text, watch_column_widths.user);
    try writeWatchColumn(writer, cpu_system_text, watch_column_widths.system);
    try writeWatchColumn(writer, rss_text, watch_column_widths.rss);
    try writeWatchColumn(writer, virt_text, watch_column_widths.virt);
    try writeWatchColumn(writer, threads_text, watch_column_widths.threads);
    try writeWatchColumn(writer, faults_text, watch_column_widths.faults);
    try writeWatchColumn(writer, pageins_text, watch_column_widths.pageins);
    try writeWatchColumn(writer, csw_text, watch_column_widths.csw);
    try writer.print("{s}\n", .{energy_text});
}

fn printWatchHeader(writer: *std.Io.Writer, options: Options) !void {
    try writeWatchColumn(writer, "CPU(s)", watch_column_widths.cpu);
    try writeWatchColumn(writer, "USER(s)", watch_column_widths.user);
    try writeWatchColumn(writer, "SYS(s)", watch_column_widths.system);
    try writeWatchColumn(
        writer,
        if (options.human) "RSS" else "RSS(bytes)",
        watch_column_widths.rss,
    );
    try writeWatchColumn(
        writer,
        if (options.human) "VIRT" else "VIRT(bytes)",
        watch_column_widths.virt,
    );
    try writeWatchColumn(writer, "TH", watch_column_widths.threads);
    try writeWatchColumn(writer, "FAULTS", watch_column_widths.faults);
    try writeWatchColumn(writer, "PAGEINS", watch_column_widths.pageins);
    try writeWatchColumn(writer, "CSW", watch_column_widths.csw);
    try writer.writeAll("ENERGY(mJ)\n");
}

fn writeWatchColumn(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    try writer.writeAll(text);
    if (text.len >= width) {
        try writer.writeByte(' ');
        return;
    }

    var remaining = width - text.len;
    while (remaining > 0) : (remaining -= 1) {
        try writer.writeByte(' ');
    }
}

test "parsePid rejects zero" {
    try testing.expectError(error.InvalidPid, parsePid("0"));
}

test "parsePid accepts positive pid" {
    try testing.expectEqual(@as(c.pid_t, 42), try parsePid("42"));
}

test "validateOptions rejects zero interval" {
    try testing.expectError(error.InvalidInterval, validateOptions(.{
        .interval = 0,
    }));
}

test "formatCommandLine reconstructs argv" {
    const procargs = [_]u8{
        2,   0,   0,   0,
        '/', 'b', 'i', 'n',
        '/', 'e', 'c', 'h',
        'o', 0,   0,   '/',
        'b', 'i', 'n', '/',
        'e', 'c', 'h', 'o',
        0,   'h', 'e', 'l',
        'l', 'o', ' ', 'w',
        'o', 'r', 'l', 'd',
        0,
    };
    const result = (try formatCommandLine(std.testing.allocator, &procargs, 2)).?;
    defer std.testing.allocator.free(result);
    try testing.expectEqualStrings("/bin/echo 'hello world'", result);
}

test "writeShellEscapedArg quotes apostrophes" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try writeShellEscapedArg(&writer.writer, "it's");
    try testing.expectEqualStrings("'it'\\''s'", writer.written());
}

test "cpuSeconds converts nanoseconds to seconds" {
    try testing.expectApproxEqAbs(1.25, cpuSeconds(1_250_000_000), 0.0001);
}

test "energyMillijoules converts nanojoules to millijoules" {
    try testing.expectApproxEqAbs(1.5, energyMillijoules(1_500_000), 0.0001);
}

test "formatBytes keeps bytes below kibibyte" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("512B", try formatBytes(&buf, 512));
}

test "formatBytes scales to mebibytes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.5MiB", try formatBytes(&buf, 1572864));
}
