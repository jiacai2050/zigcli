const std = @import("std");
const simargs = @import("simargs");

pub const std_options = .{
    .log_level = .info,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var opt = try simargs.parse(allocator, struct {
        // Those fields declare arguments options
        // only `output` is required, others are all optional
        verbose: ?bool,
        @"user-agent": enum { Chrome, Firefox, Safari } = .Firefox,
        timeout: ?u16 = 30, // default value
        output: []const u8,
        help: bool = false,

        __commands__: union(enum) {
            sub1: struct {
                a: u64,
            },
            sub2: struct { name: []const u8 },

            pub const __messages__ = .{
                .sub1 = "Subcommand 1",
                .sub2 = "Subcommand 2",
            };
        },

        // This declares option's short name
        pub const __shorts__ = .{
            .verbose = .v,
            .output = .o,
            .@"user-agent" = .A,
            .help = .h,
        };

        // This declares option's help message
        pub const __messages__ = .{
            .verbose = "Make the operation more talkative",
            .output = "Write to file instead of stdout",
            .timeout = "Max time this request can cost",
        };
    }, "[file]", null);
    defer opt.deinit();

    const sep = "-" ** 30;
    std.debug.print("{s}Program{s}\n{s}\n\n", .{ sep, sep, opt.program });
    std.debug.print("{s}Arguments{s}\n", .{ sep, sep });
    inline for (std.meta.fields(@TypeOf(opt.args))) |fld| {
        const format = "{s:>10}: " ++ switch (fld.type) {
            []const u8 => "{s}",
            ?[]const u8 => "{?s}",
            else => "{any}",
        } ++ "\n";
        std.debug.print(format, .{ fld.name, @field(opt.args, fld.name) });
    }

    std.debug.print("\n{s}Positionals{s}\n", .{ sep, sep });
    for (opt.positional_args, 0..) |arg, idx| {
        std.debug.print("{d}: {s}\n", .{ idx + 1, arg });
    }

    // Provide a print_help util method
    std.debug.print("\n{s}print_help{s}\n", .{ sep, sep });
    const stdout = std.io.getStdOut();
    try opt.printHelp(stdout.writer());
}
