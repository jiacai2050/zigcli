const std = @import("std");
const zigcli = @import("zigcli");
const structargs = zigcli.structargs;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var opt = try structargs.parse(allocator, struct {
        verbose: ?bool,
        @"user-agent": enum { Chrome, Firefox, Safari } = .Firefox,
        timeout: ?u16 = 30,
        output: ?[]const u8 = null,
        file: ?[]const u8 = null,
        image: ?[]const u8 = null,
        env: ?[]const u8 = null,
        help: bool = false,
        version: bool = false,
        completion: ?structargs.Shell = null,

        __commands__: union(enum) {
            sub1: struct {
                a: u64,
                help: bool = false,
            },
            sub2: struct { name: []const u8 },

            pub const __messages__ = .{
                .sub1 = "Subcommand 1",
                .sub2 = "Subcommand 2",
            };
        },

        pub const __shorts__ = .{
            .verbose = .v,
            .output = .o,
            .file = .f,
            .image = .i,
            .env = .e,
            .@"user-agent" = .A,
            .help = .h,
        };

        pub const __messages__ = .{
            .verbose = "Make the operation more talkative",
            .output = "Write to file instead of stdout",
            .file = "Input file path",
            .image = "Input image path (filters .png, .jpg, .svg)",
            .env = "Target environment (uses Allocator completer)",
            .timeout = "Max time this request can cost",
            .completion = "Generate shell completion script",
        };

        pub const __completers__ = .{
            .file = completeFile,
            .image = completeImages,
            .env = completeEnvs,
            .output = &[_][]const u8{ "out.txt", "log.txt", "result.json" },
            .@"user-agent" = struct {
                fn run() []const []const u8 {
                    return &.{ "Chrome", "Firefox", "Safari", "Edge", "Opera" };
                }
            }.run,
        };
    }, .{
        .argument_prompt = "[file]",
        .version_string = "0.1.0",
    });
    defer opt.deinit();

    const sep = "-" ** 30;
    std.debug.print("{s}Program{s}\n{s}\n\n", .{ sep, sep, opt.program_name });
    std.debug.print("{s}Arguments{s}\n", .{ sep, sep });
    inline for (std.meta.fields(@TypeOf(opt.options))) |field| {
        const format = "{s:>10}: " ++ switch (field.type) {
            []const u8 => "{s}",
            ?[]const u8 => "{?s}",
            else => "{any}",
        } ++ "\n";
        std.debug.print(format, .{ field.name, @field(opt.options, field.name) });
    }

    std.debug.print("\n{s}Positionals{s}\n", .{ sep, sep });
    for (opt.positional_arguments, 0..) |argument, index| {
        std.debug.print("{d}: {s}\n", .{ index + 1, argument });
    }

    // Provide a print_help util method
    std.debug.print("\n{s}print_help{s}\n", .{ sep, sep });
    const stdout = std.fs.File.stdout();
    var buffer: [1024]u8 = undefined;
    var writer = stdout.writer(&buffer);
    try opt.printHelp(&writer.interface);
    try writer.interface.flush();
}

fn completeEnvs(allocator: std.mem.Allocator) ![]const structargs.CompletionItem {
    var list: std.ArrayList(structargs.CompletionItem) = .empty;
    try list.append(allocator, .{ .value = "development", .description = "Local dev environment" });
    try list.append(allocator, .{ .value = "staging", .description = "Testing environment" });
    try list.append(allocator, .{ .value = "production", .description = "Live system" });
    return list.toOwnedSlice(allocator);
}

fn completeImages(ctx: structargs.CompletionContext) !void {
    var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.name);
        const is_image = std.mem.eql(u8, ext, ".png") or
            std.mem.eql(u8, ext, ".jpg") or
            std.mem.eql(u8, ext, ".jpeg") or
            std.mem.eql(u8, ext, ".svg");

        if (is_image) {
            try ctx.add(entry.name, "image file");
        }
    }
}

fn completeFile(ctx: structargs.CompletionContext) !void {
    var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const type_str = switch (entry.kind) {
            .directory => "directory",
            .file => "file",
            else => "other",
        };
        try ctx.add(entry.name, type_str);
    }
}
