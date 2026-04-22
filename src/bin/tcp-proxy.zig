//! TCP proxy: accepts connections on a local address and relays bytes
//! between the client and a remote endpoint.

const std = @import("std");
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;
const util = @import("util.zig");
const debugPrint = util.debugPrint;
const net = std.Io.net;
const mem = std.mem;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const io = init.io;

    const opt = try structargs.parse(allocator, io, init.minimal.args, struct {
        bind_host: []const u8 = "0.0.0.0",
        local_port: u16 = 8081,
        remote_host: []const u8,
        remote_port: u16,
        buf_size: usize = 1024 * 16,
        help: bool = false,
        version: bool = false,
        verbose: bool = false,

        pub const __shorts__ = .{
            .bind_host = .b,
            .local_port = .p,
            .remote_host = .H,
            .remote_port = .P,
            .help = .h,
            .version = .v,
        };

        pub const __messages__ = .{
            .bind_host = "Local bind host",
            .local_port = "Local bind port",
            .remote_host = "Remote host",
            .remote_port = "Remote port",
            .buf_size = "Buffer size for tcp read/write",
        };
    }, .{ .version_string = util.get_build_info() });
    defer opt.deinit();

    if (opt.options.verbose) {
        util.enableVerbose.call();
    }

    const bind_addr = try net.IpAddress.resolve(io, opt.options.bind_host, opt.options.local_port);
    const remote_addr = try net.IpAddress.resolve(io, opt.options.remote_host, opt.options.remote_port);
    var server = try bind_addr.listen(io, .{
        .kernel_backlog = 128,
        .reuse_address = true,
    });
    defer server.close(io);
    std.log.info("Tcp proxy listen on {f}", .{bind_addr});

    var group: std.Io.Group = .init;
    defer group.await(io) catch {};

    while (true) {
        const client = server.accept(io) catch |e| {
            std.log.err("Accept failed, err:{any}", .{e});
            continue;
        };
        debugPrint("Got new connection", .{});

        const remote = net.IpAddress.connect(&remote_addr, io, .{ .mode = .stream }) catch |e| {
            std.log.err("Connect remote failed, remote:{f}, err:{any}", .{ remote_addr, e });
            client.close(io);
            continue;
        };

        const proxy = Proxy.init(allocator, client, remote, opt.options.buf_size) catch |e| {
            std.log.err("Init proxy failed, err:{any}", .{e});
            client.close(io);
            remote.close(io);
            continue;
        };

        group.async(io, Proxy.run, .{ proxy, io });
    }
}

const is_linux = @import("builtin").os.tag == .linux;

// splice(2) flags
const SPLICE_F_MOVE: u32 = 1;
const SPLICE_F_NONBLOCK: u32 = 2;

fn spliceFd(fd_in: std.posix.fd_t, fd_out: std.posix.fd_t, len: usize, flags: u32) isize {
    const rc = std.os.linux.syscall6(
        .splice,
        @as(usize, @bitCast(@as(isize, fd_in))),
        0,
        @as(usize, @bitCast(@as(isize, fd_out))),
        0,
        len,
        flags,
    );
    const signed: isize = @bitCast(rc);
    return signed;
}

const Proxy = struct {
    source: net.Stream,
    remote: net.Stream,
    allocator: mem.Allocator,
    buf: if (is_linux) void else []u8,

    fn init(allocator: mem.Allocator, source: net.Stream, remote: net.Stream, buf_size: usize) !Proxy {
        return .{
            .allocator = allocator,
            .source = source,
            .remote = remote,
            .buf = if (is_linux) {} else try allocator.alloc(u8, buf_size * 2),
        };
    }

    fn run(self: Proxy, io: std.Io) void {
        var group: std.Io.Group = .init;
        if (is_linux) {
            group.async(io, copyStreamSplice, .{ self.source.socket.handle, self.remote.socket.handle });
            group.async(io, copyStreamSplice, .{ self.remote.socket.handle, self.source.socket.handle });
        } else {
            const half = self.buf.len / 2;
            group.async(io, copyStream, .{ io, self.source, self.remote, self.buf[0..half] });
            group.async(io, copyStream, .{ io, self.remote, self.source, self.buf[half..] });
        }

        group.await(io) catch {};
        self.deinit(io);
    }

    // Linux zero-copy path: kernel pipe + splice(2).
    fn copyStreamSplice(src: std.posix.fd_t, dst: std.posix.fd_t) void {
        var pipe_fds: [2]i32 = undefined;
        const pipe_rc = std.os.linux.pipe2(&pipe_fds, .{ .CLOEXEC = true });
        if (pipe_rc != 0) return;
        defer {
            _ = std.os.linux.close(pipe_fds[0]);
            _ = std.os.linux.close(pipe_fds[1]);
        }
        while (true) {
            const n = spliceFd(src, pipe_fds[1], std.math.maxInt(u31), SPLICE_F_MOVE | SPLICE_F_NONBLOCK);
            if (n <= 0) return;
            const m = spliceFd(pipe_fds[0], dst, @intCast(n), SPLICE_F_MOVE);
            if (m <= 0) return;
        }
    }

    fn copyStream(io: std.Io, src: net.Stream, dst: net.Stream, buf: []u8) void {
        var src_reader = src.reader(io, buf);
        var dst_writer = dst.writer(io, &.{});
        _ = src_reader.interface.streamRemaining(&dst_writer.interface) catch {};
    }

    fn deinit(self: Proxy, io: std.Io) void {
        self.source.close(io);
        self.remote.close(io);
        if (!is_linux) self.allocator.free(self.buf);
    }
};
