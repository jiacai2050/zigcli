const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const debugPrint = util.debugPrint;
const net = std.net;
const mem = std.mem;

pub const std_options = .{
    .log_level = .debug,
};

const isLinux = util.isLinux();
const isWindows = util.isWindows();

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const opt = try simargs.parse(allocator, struct {
        bind_host: []const u8 = "0.0.0.0",
        local_port: u16 = 8081,
        remote_host: []const u8,
        remote_port: u16,
        buf_size: usize = 1024 * 16,
        server_threads: u32 = 24,
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
            .server_threads = "Server worker threads num",
        };
    }, null, util.get_build_info());

    if (opt.args.verbose) {
        util.enableVerbose.call();
    }

    const bind_addr = try parseIp(opt.args.bind_host, opt.args.local_port);
    const remote_addr = try parseIp(opt.args.remote_host, opt.args.remote_port);
    var server = try bind_addr.listen(.{
        .kernel_backlog = 128,
        .reuse_address = true,
    });
    std.log.info("Tcp proxy listen on {any}", .{bind_addr});

    var pool = try allocator.create(std.Thread.Pool);
    defer pool.deinit();

    try pool.init(.{
        .allocator = allocator,
        .n_jobs = opt.args.server_threads,
    });
    while (true) {
        const client = try server.accept();
        debugPrint("Got new connection, addr:{any}", .{client.address});

        const proxy = Proxy.init(allocator, client, remote_addr, opt.args.buf_size) catch |e| {
            std.log.err("Init proxy failed, remote:{any}, err:{any}", .{ remote_addr, e });
            client.stream.close();
            continue;
        };
        proxy.nonblockingWork(pool) catch |e| {
            std.log.err("Proxy do work failed, remote:{any}, err:{any}", .{ remote_addr, e });
        };
    }
}

const Pipes = struct {
    src_to_remote: [2]std.posix.fd_t,
    remote_to_src: [2]std.posix.fd_t,
};

const DoubleBuf = struct {
    src_to_remote: []u8,
    remote_to_src: []u8,
};
const CopyContext = if (isLinux) Pipes else DoubleBuf;

const Proxy = struct {
    source: net.Server.Connection,
    remote_conn: net.Stream,
    remote_addr: net.Address,
    allocator: mem.Allocator,

    context: CopyContext,

    pub fn init(allocator: mem.Allocator, source: net.Server.Connection, remote: net.Address, buf_size: usize) !Proxy {
        // this may block
        const remote_conn = try net.tcpConnectToAddress(remote);
        const context = if (isLinux) Pipes{
            .src_to_remote = try std.posix.pipe(),
            .remote_to_src = try std.posix.pipe(),
        } else blk: {
            const buf = try allocator.alloc(u8, buf_size * 2);
            break :blk DoubleBuf{
                .src_to_remote = buf[0..buf_size],
                .remote_to_src = buf[buf_size..],
            };
        };
        return .{
            .allocator = allocator,
            .source = source,
            .remote_conn = remote_conn,
            .remote_addr = remote,
            .context = context,
        };
    }

    fn copyStreamLinux(
        fds: [2]std.posix.fd_t,
        src: net.Stream,
        src_addr: net.Address,
        dst: net.Stream,
        dst_addr: net.Address,
    ) void {
        const c = @cImport({
            // https://man7.org/linux/man-pages/man2/splice.2.html
            @cDefine("_GNU_SOURCE", {});
            @cInclude("fcntl.h");
        });
        while (true) {
            const rc = c.splice(src.handle, null, fds[1], null, util.MAX_I32, c.SPLICE_F_NONBLOCK | c.SPLICE_F_MOVE);
            const read = util.checkCErr(rc) catch {
                std.log.err("Read stream into pipe failed, addr:{any}, err:{any}", .{ src_addr, std.posix.errno(rc) });
                return;
            };
            if (read == 0) {
                return;
            }

            const rc2 = c.splice(fds[0], null, dst.handle, null, util.MAX_I32, c.SPLICE_F_MOVE);
            _ = util.checkCErr(rc2) catch {
                std.log.err("Write stream from pipe failed, addr:{any}, err:{any}", .{ dst_addr, std.posix.errno(rc2) });
                return;
            };
        }
    }

    fn copyStream(
        buf: []u8,
        src: net.Stream,
        src_addr: net.Address,
        dst: net.Stream,
        dst_addr: net.Address,
    ) void {
        while (true) {
            const read = src.read(buf) catch |e| {
                if (e != error.NotOpenForReading) {
                    std.log.err("Read stream failed, addr:{any}, err:{any}", .{ src_addr, e });
                }
                return;
            };
            if (read == 0) {
                return;
            }

            _ = dst.writeAll(buf[0..read]) catch |e| {
                std.log.err("Write stream failed, addr:{any}, err:{any}", .{ dst_addr, e });
                return;
            };
        }
    }

    pub fn nonblockingWork(
        self: Proxy,
        pool: *std.Thread.Pool,
    ) !void {
        const copyFn = if (isLinux)
            Proxy.copyStreamLinux
        else
            Proxy.copyStream;
        {
            errdefer self.deinit();
            // task1. copy source to remote
            try pool.spawn(struct {
                fn run(
                    proxy: Proxy,
                ) void {
                    copyFn(
                        proxy.context.src_to_remote,
                        proxy.source.stream,
                        proxy.source.address,
                        proxy.remote_conn,
                        proxy.remote_addr,
                    );
                    // When source disconnected, `source.read` will return 0, this means copyStream will return,
                    // and task1 is finished. When we close remote conn here, task2 below will also exit.
                    // If task2 exit earlier than task1, copyStream in task1 will also return, so we don't leak resources.
                    proxy.deinit();
                }
            }.run, .{self});
        }

        // task2. copy remote to source
        try pool.spawn(struct {
            fn run(
                proxy: Proxy,
            ) void {
                copyFn(
                    proxy.context.remote_to_src,
                    proxy.remote_conn,
                    proxy.remote_addr,
                    proxy.source.stream,
                    proxy.source.address,
                );
            }
        }.run, .{self});
    }

    fn deinit(self: Proxy) void {
        debugPrint("Close proxy, src:{any}, remote:{any}.", .{ self.source.address, self.remote_addr });

        self.source.stream.close();
        self.remote_conn.close();
        if (isLinux) {
            std.posix.close(self.context.src_to_remote[0]);
            std.posix.close(self.context.src_to_remote[1]);
            std.posix.close(self.context.remote_to_src[0]);
            std.posix.close(self.context.remote_to_src[1]);
        } else {
            self.allocator.free(self.context.src_to_remote);
        }
    }
};

// resolveIp can't be used in windows, so add this hack!
// 0.13.0\x64\lib\std\net.zig:756:5: error: std.net.if_nametoindex unimplemented for this OS
fn parseIp(name: []const u8, port: u16) !net.Address {
    return if (isWindows)
        net.Address.parseIp4(name, port) catch
            try net.Address.parseIp6(name, port)
    else
        try net.Address.resolveIp(name, port);
}
