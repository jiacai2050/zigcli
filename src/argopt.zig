//! Parse arg options using struct

const std = @import("std");

const CliOption = struct {
    help: bool = false,
    version: bool = false,
    exclude: ?[]const u8 = null,

    const __shorts__ = .{
        .help = .h,
        .version = .v,
    };

    const _messages_ = .{
        .help = "show help",
    };

    const required = .{
        .version,
        .exclude,
    };
};

const ParseError = error{ NoProgram, NoLongOption };
const OptionError = ParseError || std.mem.Allocator.Error;

const OptionParser = struct {
    program: []const u8 = undefined,
    parsedOptions: OptionFields,
    allocator: std.mem.Allocator,

    const Self = @This();

    const OptionType = enum(u32) {
        const REQUIRED_VERSION_SHIFT = 16;

        Int,
        Bool,
        Float,
        String,
        RequiredInt = @This().REQUIRED_VERSION_SHIFT,
        RequiredBool,
        RequiredFloat,
        RequiredString,

        fn from_zig_type(comptime T: type, comptime is_option: bool) OptionType {
            const base_type: @This() = switch (@typeInfo(T)) {
                .Int, .Bool, .Float => .Int,
                .Array => .String,
                .Optional => |opt_info| return from_zig_type(opt_info.child, true),
                .Pointer => |ptr_info|
                // only support []const u8
                if (ptr_info.size == .Slice and ptr_info.child == u8 and ptr_info.is_const)
                    .String
                else {
                    @compileError("not supported option type:" ++ @typeName(T));
                },
                else => {
                    @compileError("not supported option type:" ++ @typeName(T));
                },
            };
            return @intToEnum(@This(), @enumToInt(base_type) + if (is_option) @This().REQUIRED_VERSION_SHIFT else 0);
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

    // `T` is a struct, which define options
    pub fn init(allocator: std.mem.Allocator, comptime T: type) anyerror!Self {
        const option_type_info = @typeInfo(T);
        if (option_type_info != .Struct) {
            @compileError("option should be defined using struct, found " ++ @typeName(T));
        }

        var opts = OptionFields.init(allocator);
        inline for (option_type_info.Struct.fields) |fld| {
            const long_name = fld.name;
            const opt_type = OptionType.from_zig_type(fld.field_type, false);
            try opts.put(long_name, OptionField{
                .long_name = long_name,
                .opt_type = opt_type,
                .default_value = fld.default_value,
            });
        }

        // parse short names
        if (@hasDecl(T, "__shorts__")) {
            const short_type_info = @typeInfo(@TypeOf(T.__shorts__));
            if (short_type_info != .Struct) {
                @compileError("short option should be defined using struct, found " ++ @typeName(T));
            }

            inline for (short_type_info.Struct.fields) |fld| {
                const long_name = fld.name;
                var option = opts.getPtr(long_name) orelse {
                    std.log.err("no such long option, value: {s}", .{long_name});
                    return error.NoLongOtion;
                };

                const short_name = @field(T.__shorts__, long_name);
                if (@typeInfo(@TypeOf(short_name)) != .EnumLiteral) {
                    @compileError("short option value must be literal enum, found " ++ @typeName(T));
                }
                option.short_name = @tagName(short_name)[0];
            }
        }

        return .{
            .program = "test",
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parser = try OptionParser.init(allocator, CliOption);

    std.log.warn("parser is {any}", .{parser});
    // _ = parser;
    // const opt = CliOption{};
    // const shorts = @TypeOf(CliOption.shorthands);
    // inline for (std.meta.fields(shorts)) |field| {
    //     std.log.warn("field name, type:{any},value:{s}", .{ field.field_type, @tagName(@field(CliOption.shorthands, field.name)) });
    // }
    // std.log.warn("hands={any}={any}", .{ (@TypeOf(CliOption.shorthands)), @TypeOf(CliOption.shorthands.version) });

    // _ = opt;
}
