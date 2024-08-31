const std = @import("std");
const simargs = @import("simargs");
const util = @import("util.zig");
const process = std.process;
const fs = std.fs;
const net = std.net;
const mem = std.mem;

var verbose: bool = false;

fn debugPrint(
    comptime format: []const u8,
    args: anytype,
) void {
    if (verbose) {
        std.debug.print(format, args);
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = try simargs.parse(allocator, struct {
        bind_host: []const u8,
        local_port: u16,
        remote_host: []const u8,
        remote_port: u16,
        buf_size: usize = 1024,
        thread_pool_size: u32 = 24,
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
    }, null, util.get_build_info());

    verbose = opt.args.verbose;

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
        .n_jobs = opt.args.thread_pool_size,
    });
    while (true) {
        const client = try server.accept();
        debugPrint("Got new connection, addr:{any}\n", .{client.address});

        const proxy = Proxy.init(allocator, client, remote_addr) catch |e| {
            std.log.err("Init proxy failed, remote:{any}, err:{any}", .{ remote_addr, e });
            client.stream.close();
            continue;
        };
        proxy.nonblockingCommunicate(pool, opt.args.buf_size) catch |e| {
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

    pub fn init(allocator: mem.Allocator, conn: net.Server.Connection, remote: net.Address) !Proxy {
        const remote_conn = try net.tcpConnectToAddress(remote);
        return .{
            .allocator = allocator,
            .conn = conn,
            .remote_conn = remote_conn,
            .remote_addr = remote,
        };
    }

    fn copyStreamNoError(
        allocator: mem.Allocator,
        src: net.Stream,
        dst: net.Stream,
        buf_size: usize,
    ) void {
        Proxy.copyStream(allocator, src, dst, buf_size) catch |e|
            switch (e) {
            error.NotOpenForReading => {},
            else => {
                std.log.err("copy stream error: {any}\n", .{e});
            },
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
                defer {
                    wg.wait();
                    proxy.deinit();
                }

                // When conn.stream is closed, we close this proxy.
                pool_inner.spawnWg(&wg, Proxy.copyStreamNoError, .{
                    proxy.allocator,
                    proxy.conn.stream,
                    proxy.remote_conn,
                    buf_size_inner,
                });
                pool_inner.spawn(Proxy.copyStreamNoError, .{
                    proxy.allocator,
                    proxy.remote_conn,
                    proxy.conn.stream,
                    buf_size_inner,
                }) catch unreachable;
            }
        }.run, .{ self, pool, buf_size });
    }

    fn deinit(self: Proxy) void {
        debugPrint("Close proxy, src:{any}\n", .{self.conn.address});
        self.conn.stream.close();
        self.remote_conn.close();
    }
};
