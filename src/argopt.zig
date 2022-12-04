//! Parse arg options using struct

const std = @import("std");

const CliOption = struct {
    help: ?i64,
    version: ?bool,
    action: ?[]const u8,
    age: ?f64,
    // exclude: ?[]const u8 = null,

    // const __shorts__ = .{
    //     .help = .h,
    //     .version = .v,
    // };

    // const __messages__ = .{
    //     .help = "show help",
    // };

    // const __required__ = .{
    //     .version,
    //     .exclude,
    // };
};

const ParseError = error{ NoProgram, NoLongOption, ExpectedOption, NoShortOption };
const OptionError = ParseError || std.mem.Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError;

pub fn parseArgOption(
    allocator: std.mem.Allocator,
    comptime T: type,
) !OptionResultType(TWithDefaultValue(T)) {
    const new_T = TWithDefaultValue(T);
    var parser = try OptionParser(new_T).init(allocator);
    return parser.parse();
}

fn OptionResultType(comptime T: type) type {
    return struct {
        program: []const u8,
        allocator: std.mem.Allocator,
        args: T,
        positional_args: std.ArrayList([]const u8),

        fn deinit(self: @This()) void {
            self.allocator.free(self.program);
            self.positional_args.deinit();
        }
    };
}

fn TWithDefaultValue(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info != .Struct) {
        @compileError("option should be defined using struct, found " ++ @typeName(T));
    }

    const struct_info = type_info.Struct;
    var new_fields: [struct_info.fields.len]std.builtin.Type.StructField = undefined;
    inline for (std.meta.fields(T)) |field, i| {
        new_fields[i].name = field.name;
        new_fields[i].field_type = field.field_type;
        new_fields[i].is_comptime = field.is_comptime;
        new_fields[i].alignment = field.alignment;
        new_fields[i].name = field.name;

        const default_value = switch (OptionType.from_zig_type(field.field_type, false)) {
            .Int, .RequiredInt => @as(field.field_type, 0),
            .Float, .RequiredFloat => @as(field.field_type, 0.0),
            .String, .RequiredString => @as([]const u8, &[_]u8{}),
            .Bool, .RequiredBool => false,
        };
        if (field.default_value) |v| {
            new_fields[i].default_value = v;
        } else {
            new_fields[i].default_value = @ptrCast(*const anyopaque, &default_value);
        }
    }

    return @Type(.{ .Struct = .{
        .layout = struct_info.layout,
        .backing_integer = struct_info.backing_integer,
        .decls = struct_info.decls,
        .is_tuple = struct_info.is_tuple,
        .fields = new_fields[0..],
    } });
}

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
            .Int => .Int,
            .Bool => .Bool,
            .Float => .Float,
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

fn OptionParser(
    comptime T: type,
) type {
    return struct {
        parsedOptions: OptionFields,
        allocator: std.mem.Allocator,

        const Self = @This();

        const OptionValue = union(enum) {
            int: i64,
            float: f64,
            string: [:0]const u8,
            boolean: bool,
        };

        const OptionField = struct {
            long_name: []const u8,
            short_name: ?u8 = null,
            message: ?[]const u8 = null,
            opt_type: OptionType,
            value: ?OptionValue,
        };

        const OptionFields = std.StringHashMap(OptionField);

        // `T` is a struct, which define options
        fn init(allocator: std.mem.Allocator) anyerror!Self {
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
                    // .default_value = fld.default_value,
                    .value = null,
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
                .allocator = allocator,
                .parsedOptions = opts,
            };
        }

        const ParseState = enum {
            start,
            waitValue,
            args,
        };

        fn parse(self: *Self) OptionError!OptionResultType(T) {
            var args_iter = try std.process.argsWithAllocator(self.allocator);
            var result = OptionResultType(T){
                .program = args_iter.next() orelse return error.NoProgram,
                .allocator = self.allocator,
                .args = T{},
                .positional_args = std.ArrayList([]const u8).init(self.allocator),
            };

            var state = ParseState.start;
            var current_opt: ?*OptionField = null;

            while (args_iter.next()) |arg| {
                std.log.debug("current state is: {s}", .{@tagName(state)});

                switch (state) {
                    .start => if (std.mem.startsWith(u8, arg, "-")) {
                        current_opt = if (std.mem.startsWith(u8, arg[1..arg.len], "-"))
                            // long option
                            self.parsedOptions.getPtr(arg[2..arg.len])
                        else blk: {
                            // short
                            const short_name = arg[1..arg.len];
                            if (short_name.len != 1) {
                                std.log.err("No such short option, name:{s}", .{arg});
                                return error.NoShortOption;
                            }
                            var it = self.parsedOptions.valueIterator();
                            while (it.next()) |opt| {
                                if (opt.short_name) |name| {
                                    if (name == short_name[0]) {
                                        break :blk opt;
                                    }
                                }
                            }
                        };

                        const opt = current_opt orelse {
                            std.log.err("No such option, name:{s}", .{arg});
                            return error.NoLongOption;
                        };
                        if (opt.opt_type == .Bool) { // no value required, parse next option
                            state = .waitValue;
                        } else {
                            // value required, parse option value
                            state = .waitValue;
                        }
                    } else {
                        // no option any more, the rest are positional args
                        state = .args;
                        try result.positional_args.append(arg);
                    },
                    .args => try result.positional_args.append(arg),
                    .waitValue => {
                        inline for (std.meta.fields(T)) |field| {
                            if (std.mem.eql(u8, field.name, current_opt.?.long_name)) {
                                try Self.setOptionValue(&result.args, field.name, OptionType.from_zig_type(field.field_type, false), arg);
                                break;
                            }
                        }
                        state = .start;
                    },
                }
            }

            return result;
        }

        fn setOptionValue(opt: *T, comptime opt_name: []const u8, comptime opt_type: OptionType, raw_value: []const u8) !void {
            const value = switch (opt_type) {
                .Int, .RequiredInt => try std.fmt.parseInt(i64, raw_value, 10),
                .Float, .RequiredFloat => try std.fmt.parseFloat(f64, raw_value),
                .String, .RequiredString => raw_value,
                .Bool, .RequiredBool => std.mem.eql(u8, "true", raw_value) or std.mem.eql(u8, "1", raw_value),
            };
            @field(opt, opt_name) = value;
        }
    };
}

pub const log_level: std.log.Level = .debug;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var opt = try parseArgOption(allocator, CliOption);

    std.log.warn("opt is {any}", .{opt});
    // _ = parser;
    // const opt = CliOption{};
    // const shorts = @TypeOf(CliOption.shorthands);
    // inline for (std.meta.fields(shorts)) |field| {
    //     std.log.warn("field name, type:{any},value:{s}", .{ field.field_type, @tagName(@field(CliOption.shorthands, field.name)) });
    // }
    // std.log.warn("hands={any}={any}", .{ (@TypeOf(CliOption.shorthands)), @TypeOf(CliOption.shorthands.version) });

    // _ = opt;
}
