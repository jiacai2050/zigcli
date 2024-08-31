const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const process = std.process;
const fs = std.fs;
const net = std.net;
const mem = std.mem;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = try simargs.parse(allocator, struct {
        bind_address: []const u8,
        local_port: u16,
        remote_host: []const u8,
        remote_port: u16,
        buf_size: usize = 1024,
        thread_pool_size: u32 = 24,
        help: bool = false,

        pub const __shorts__ = .{
            .bind_address = .b,
            .local_port = .p,
            .remote_host = .H,
            .remote_port = .P,
            .help = .h,
        };

        pub const __messages__ = .{
            .bind_address = "Local bind address",
            .local_port = "Local bind port",
            .remote_host = "Remote host",
            .remote_port = "Remote port",
            .buf_size = "Buffer size for tcp read/write",
        };
    }, null, util.get_build_info());

    const bind_addr = try net.Address.resolveIp(opt.args.bind_address, opt.args.local_port);
    const remote_addr = try net.Address.resolveIp(opt.args.remote_host, opt.args.remote_port);
    var server = try bind_addr.listen(.{
        .kernel_backlog = 128,
        .reuse_address = true,
    });
    var pool = try allocator.create(std.Thread.Pool);
    defer pool.deinit();

    try pool.init(.{
        .allocator = allocator,
        .n_jobs = opt.args.thread_pool_size,
    });
    while (true) {
        const client = try server.accept();
        const proxy = try Proxy.init(allocator, client, remote_addr);
        try proxy.nonblockingCommunicate(pool, opt.args.buf_size);
    }
}

const Proxy = struct {
    conn: net.Server.Connection,
    remote_conn: net.Stream,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator, conn: net.Server.Connection, remote: net.Address) !Proxy {
        const remote_conn = try net.tcpConnectToAddress(remote);
        return .{
            .allocator = allocator,
            .conn = conn,
            .remote_conn = remote_conn,
        };
    }

    fn copyStreamNoError(
        allocator: mem.Allocator,
        src: net.Stream,
        dst: net.Stream,
        buf_size: usize,
    ) void {
        Proxy.copyStream(allocator, src, dst, buf_size) catch |e| {
            std.debug.print("copy stream error: {any}\n", .{e});
        };
    }

    fn copyStream(
        allocator: mem.Allocator,
        src: net.Stream,
        dst: net.Stream,
        buf_size: usize,
    ) !void {
        var buf = try allocator.alloc(u8, buf_size);
        defer allocator.free(buf);
        var read = try src.read(buf);

        while (read > 0) : (read = try src.read(buf)) {
            _ = try dst.writeAll(buf[0..read]);
        }
    }

    pub fn nonblockingCommunicate(
        self: Proxy,
        pool: *std.Thread.Pool,
        buf_size: usize,
    ) !void {
        try pool.spawn(struct {
            fn run(
                proxy: Proxy,
                pool_inner: *std.Thread.Pool,
                buf_size_inner: usize,
            ) void {
                var wg = std.Thread.WaitGroup{};
                pool_inner.spawnWg(&wg, Proxy.copyStreamNoError, .{
                    proxy.allocator,
                    proxy.conn.stream,
                    proxy.remote_conn,
                    buf_size_inner,
                });
                pool_inner.spawnWg(&wg, Proxy.copyStreamNoError, .{
                    proxy.allocator,
                    proxy.remote_conn,
                    proxy.conn.stream,
                    buf_size_inner,
                });
                wg.wait();
                proxy.deinit();
            }
        }.run, .{ self, pool, buf_size });
    }

    fn deinit(self: Proxy) void {
        self.conn.stream.close();
        self.remote_conn.close();
    }
};
