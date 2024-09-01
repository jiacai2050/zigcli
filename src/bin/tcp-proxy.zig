const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const debugPrint = util.debugPrint;
const net = std.net;
const mem = std.mem;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const opt = try simargs.parse(allocator, struct {
        bind_host: []const u8,
        local_port: u16,
        remote_host: []const u8,
        remote_port: u16,
        buf_size: usize = 1024,
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

    const bind_addr = try net.Address.resolveIp(opt.args.bind_host, opt.args.local_port);
    const remote_addr = try net.Address.resolveIp(opt.args.remote_host, opt.args.remote_port);
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
        debugPrint("Got new connection, addr:{any}\n", .{client.address});

        const proxy = Proxy.init(allocator, client, remote_addr, opt.args.buf_size) catch |e| {
            std.log.err("Init proxy failed, remote:{any}, err:{any}", .{ remote_addr, e });
            client.stream.close();
            continue;
        };
        proxy.nonblockingCommunicate(pool) catch |e| {
            proxy.deinit();
            std.log.err("Communicate, remote:{any}, err:{any}", .{ remote_addr, e });
        };
    }
}

const Proxy = struct {
    conn: net.Server.Connection,
    remote_conn: net.Stream,
    remote_addr: net.Address,
    allocator: mem.Allocator,

    doubled_buf: []u8,
    buf_size: usize,

    pub fn init(allocator: mem.Allocator, conn: net.Server.Connection, remote: net.Address, buf_size: usize) !Proxy {
        const remote_conn = try net.tcpConnectToAddress(remote);
        const buf = try allocator.alloc(u8, buf_size * 2);
        return .{
            .allocator = allocator,
            .conn = conn,
            .remote_conn = remote_conn,
            .remote_addr = remote,
            .doubled_buf = buf,
            .buf_size = buf_size,
        };
    }

    fn copyStream(
        buf: []u8,
        src: net.Stream,
        dst: net.Stream,
    ) void {
        while (true) {
            const read = src.read(buf) catch |e|
                switch (e) {
                error.NotOpenForReading => return,
                else => {
                    std.log.err("Read stream failed, err:{any}", .{e});
                    return;
                },
            };

            if (read == 0) {
                return;
            }

            _ = dst.writeAll(buf[0..read]) catch |e| {
                std.log.err("Write stream failed, err:{any}", .{e});
                return;
            };
        }
    }

    pub fn nonblockingCommunicate(
        self: Proxy,
        pool: *std.Thread.Pool,
    ) !void {
        try pool.spawn(struct {
            fn run(
                proxy: Proxy,
                pool_inner: *std.Thread.Pool,
                src_to_remote_buf: []u8,
                remote_to_src_buf: []u8,
            ) void {
                var wg = std.Thread.WaitGroup{};
                pool_inner.spawnWg(&wg, Proxy.copyStream, .{
                    src_to_remote_buf,
                    proxy.conn.stream,
                    proxy.remote_conn,
                });
                pool_inner.spawn(Proxy.copyStream, .{
                    remote_to_src_buf,
                    proxy.remote_conn,
                    proxy.conn.stream,
                }) catch |e| {
                    proxy.deinit();
                    std.log.err("Spawn task failed, err:{any}", .{e});
                    return;
                };

                // Bi-directional transmissions are established, we wait until conn.stream is closed.
                wg.wait();
                proxy.deinit();
            }
        }.run, .{
            self,
            pool,
            self.doubled_buf[0..self.buf_size],
            self.doubled_buf[self.buf_size..],
        });
    }

    fn deinit(self: Proxy) void {
        debugPrint("Close proxy, src:{any}\n", .{self.conn.address});

        self.conn.stream.close();
        self.remote_conn.close();
    }
};
