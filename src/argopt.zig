//! Parse arg options using struct

const std = @import("std");

const CliOption = struct {
    help: bool = false,
    version: bool = false,
    exclude: ?[]const u8 = null,

    const shorthands = .{
        .help = .h,
        .version = .v,
    };

    const messages = .{
        .help = "show help",
    };

    const required = .{
        .version,
        .exclude,
    };
};

const ParseError = error{
    NoProgram,
};
const OptionParser = struct {
    program: []const u8 = undefined,
    parsedOptions: OptionFields,
    allocator: std.mem.Allocator,

    const OptionType = enum(u32) {
        Int,
        Bool,
        Float,
        String,
        RequiredInt = REQUIRED_VERSION_SHIFT,
        RequiredBool,
        RequiredFloat,
        RequiredString,

        const REQUIRED_VERSION_SHIFT = 16;

        fn from_zig_type(T: type, is_option: bool) !OptionType {
            const base_type = switch (@typeInfo(T)) {
                .Int, .Bool, .Float => .Int,
                .Array => .String,
                .Optional => |opt_info| return from_zig_type(opt_info.child, true),
                else => {
                    std.log.err("not support type:{s}", .{@typeName(T)});
                    return error.InvalidType;
                },
            };
            return @intToEnum(@This(), base_type + if (is_option) REQUIRED_VERSION_SHIFT else 0);
        }
    };
    const OptionField = struct {
        long_name: []const u8,
        short_name: ?u8 = null,
        message: ?[]const u8 = null,
        opt_type: OptionType,
        default_value: ?*const anyopaque,
    };
    const OptionFields = std.StringHashMap(OptionField);

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, comptime T: type) !Self {
        const option_type_info = @typeInfo(T);
        if (option_type_info != .Struct) {
            @compileError("option should be struct, found " ++ @typeName(T));
        }

        var opts = OptionFields.init(allocator);
        inline for (option_type_info.Struct.fields) |fld| {
            const long_name = fld.name;
            try opts.put(long_name, .{
                .long_name = long_name,
                .opt_type = opt_type,
                .default_value = fld.default_value,
            });
        }
        return .{
            .allocator = allocator,
            .parsedOptions = OptionFields.init(allocator),
        };
    }

    fn parse(self: *Self) ParseError!void {
        var args_iter = try std.process.argsWithAllocator(self.allocator);
        self.program = args_iter.next() orelse return .NoProgram;
        while (args_iter.next()) |arg| {
            _ = arg;
            return unreachable();
        }
        return unreachable();
    }
};

pub const log_level: std.log.Level = .info;
test "parse cli" {
    const allocator = std.testing.allocator;
    const parser = try OptionParser.init(allocator, CliOption);

    _ = parser;
    // const opt = CliOption{};
    // const shorts = @TypeOf(CliOption.shorthands);
    // inline for (std.meta.fields(shorts)) |field| {
    //     std.log.warn("field name, type:{any},value:{s}", .{ field.field_type, @tagName(@field(CliOption.shorthands, field.name)) });
    // }
    // std.log.warn("hands={any}={any}", .{ (@TypeOf(CliOption.shorthands)), @TypeOf(CliOption.shorthands.version) });

    // _ = opt;
}
