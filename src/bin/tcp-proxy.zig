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

const Pipes = struct {
    src_to_remote: [2]std.posix.fd_t,
    remote_to_src: [2]std.posix.fd_t,
};

const CopyContext = if (is_linux) Pipes else struct {
    src_to_remote: []u8,
    remote_to_src: []u8,
};

const Proxy = struct {
    source: net.Stream,
    remote: net.Stream,
    allocator: mem.Allocator,
    context: CopyContext,

    fn init(allocator: mem.Allocator, source: net.Stream, remote: net.Stream, buf_size: usize) !Proxy {
        const context: CopyContext = if (is_linux) .{
            .src_to_remote = try createPipe(),
            .remote_to_src = try createPipe(),
        } else blk: {
            const buf = try allocator.alloc(u8, buf_size * 2);
            break :blk .{
                .src_to_remote = buf[0..buf_size],
                .remote_to_src = buf[buf_size..],
            };
        };
        return .{
            .allocator = allocator,
            .source = source,
            .remote = remote,
            .context = context,
        };
    }

    fn run(self: Proxy, io: std.Io) void {
        var group: std.Io.Group = .init;
        if (is_linux) {
            group.async(io, copyStreamSplice, .{ self.context.src_to_remote, self.source.socket.handle, self.remote.socket.handle });
            group.async(io, copyStreamSplice, .{ self.context.remote_to_src, self.remote.socket.handle, self.source.socket.handle });
        } else {
            group.async(io, copyStream, .{ io, self.source, self.remote, self.context.src_to_remote });
            group.async(io, copyStream, .{ io, self.remote, self.source, self.context.remote_to_src });
        }
        group.await(io) catch {};
        self.deinit(io);
    }

    // Linux zero-copy path: dedicated pipe pair per direction + splice(2).
    fn copyStreamSplice(fds: [2]std.posix.fd_t, src: std.posix.fd_t, dst: std.posix.fd_t) void {
        while (true) {
            const rc = spliceFd(src, fds[1], std.math.maxInt(u31), SPLICE_F_MOVE | SPLICE_F_NONBLOCK);
            if (rc <= 0) {
                if (rc < 0) std.log.err("Read stream into pipe failed, err:{d}", .{-rc});
                return;
            }
            const rc2 = spliceFd(fds[0], dst, @intCast(rc), SPLICE_F_MOVE);
            if (rc2 <= 0) {
                if (rc2 < 0) std.log.err("Write stream from pipe failed, err:{d}", .{-rc2});
                return;
            }
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
        if (is_linux) {
            closePipe(self.context.src_to_remote);
            closePipe(self.context.remote_to_src);
        } else {
            self.allocator.free(self.context.src_to_remote.ptr[0 .. self.context.src_to_remote.len + self.context.remote_to_src.len]);
        }
    }
};

fn createPipe() ![2]std.posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.pipe2(&fds, .{ .CLOEXEC = true });
    if (rc != 0) return error.SystemResources;
    return fds;
}

fn closePipe(fds: [2]std.posix.fd_t) void {
    _ = std.os.linux.close(fds[0]);
    _ = std.os.linux.close(fds[1]);
}
