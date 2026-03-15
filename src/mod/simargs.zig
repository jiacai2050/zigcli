//! A simple, opinionated, struct-based argument parser in Zig

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.io.Writer;
const testing = std.testing;
const is_test = @import("builtin").is_test;

const ParseError = error{
    NoProgram,
    NoOption,
    MissingRequiredOption,
    MissingOptionValue,
    InvalidEnumValue,
    MissingSubCommand,
};

const command_field_name_default = "__commands__";

const OptionError = ParseError ||
    std.mem.Allocator.Error ||
    std.fmt.ParseIntError ||
    std.fmt.ParseFloatError ||
    std.process.ArgIterator.InitError;

/// Parses arguments according to the given structure.
/// - `T` is the configuration of the arguments.
pub fn parse(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime argument_prompt: ?[]const u8,
    comptime version_string: ?[]const u8,
) OptionError!StructArguments(T, version_string, argument_prompt) {
    const raw_arguments = try std.process.argsAlloc(allocator);
    var parser = OptionParser(T).init(allocator);
    return parser.parse(argument_prompt, version_string, raw_arguments);
}

const OptionField = struct {
    long_name: []const u8,
    option_type: OptionType,
    short_name: ?u8 = null,
    message: ?[]const u8 = null,
    // Whether this option is set by the user or has a default value.
    is_set: bool = false,
};

fn getOptionLength(comptime T: type) usize {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Option configuration should be defined using struct, found " ++ @typeName(T));
    }

    const fields = std.meta.fields(T);
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, command_field_name_default)) {
            return fields.len - 1;
        }
    }

    return fields.len;
}

fn buildOptionFields(comptime T: type) [getOptionLength(T)]OptionField {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Option configuration should be defined using struct, found " ++ @typeName(T));
    }

    var option_fields: [getOptionLength(T)]OptionField = undefined;
    const fields = std.meta.fields(T);
    var current_index: usize = 0;
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, command_field_name_default)) {
            continue;
        }

        const long_name = field.name;
        const option_type = OptionType.from_zig_type(field.type);
        option_fields[current_index] = .{
            .long_name = long_name,
            .option_type = option_type,
            // Option with default value is set automatically.
            .is_set = field.default_value_ptr != null,
        };
        current_index += 1;
    }

    // Parse short names.
    if (@hasDecl(T, "__shorts__")) {
        const shorts_type = @TypeOf(T.__shorts__);
        if (@typeInfo(shorts_type) != .@"struct") {
            @compileError("__shorts__ should be defined using struct, found " ++ @typeName(shorts_type));
        }

        const shorts_fields = std.meta.fields(shorts_type);
        inline for (shorts_fields) |field| {
            const long_name = field.name;
            inline for (&option_fields) |*option_field| {
                if (std.mem.eql(u8, option_field.long_name, long_name)) {
                    const short_name_literal = @field(T.__shorts__, long_name);
                    if (@typeInfo(@TypeOf(short_name_literal)) != .enum_literal) {
                        @compileError("Short option value must be literal enum, found " ++ @typeName(@TypeOf(short_name_literal)));
                    }
                    option_field.short_name = @tagName(short_name_literal)[0];

                    break;
                }
            } else {
                @compileError("No such option exists for short name mapping, long_name: " ++ long_name);
            }
        }
    }

    // Parse messages.
    if (@hasDecl(T, "__messages__")) {
        const messages_type = @TypeOf(T.__messages__);
        if (@typeInfo(messages_type) != .@"struct") {
            @compileError("__messages__ should be defined using struct, found " ++ @typeName(messages_type));
        }

        const messages_fields = std.meta.fields(messages_type);
        inline for (messages_fields) |field| {
            const long_name = field.name;
            inline for (&option_fields) |*option_field| {
                if (std.mem.eql(u8, option_field.long_name, long_name)) {
                    option_field.message = @field(T.__messages__, long_name);
                    break;
                }
            } else {
                @compileError("No such option exists for message mapping, long_name: " ++ long_name);
            }
        }
    }

    return option_fields;
}

test "build option fields" {
    const fields = comptime buildOptionFields(struct {
        verbose: bool,
        help: ?bool,
        timeout: u16,
        @"user-agent": ?[]const u8,

        pub const __shorts__ = .{
            .verbose = .v,
        };

        pub const __messages__ = .{
            .verbose = "show verbose log",
        };
    });

    try std.testing.expectEqualDeep([4]OptionField{
        .{ .long_name = "verbose", .short_name = 'v', .message = "show verbose log", .option_type = .RequiredBool },
        .{ .long_name = "help", .option_type = .Bool },
        .{ .long_name = "timeout", .option_type = .RequiredInt },
        .{ .long_name = "user-agent", .option_type = .String },
    }, fields);
}

fn NonOptionType(comptime opt_type: type) type {
    return switch (@typeInfo(opt_type)) {
        .optional => |optional_info| NonOptionType(optional_info.child),
        else => opt_type,
    };
}

const MessageHelper = struct {
    allocator: std.mem.Allocator,
    program_name: []const u8,
    argument_prompt: ?[]const u8,
    version_string: ?[]const u8,

    fn init(
        allocator: std.mem.Allocator,
        program_name: []const u8,
        version_string: ?[]const u8,
        argument_prompt: ?[]const u8,
    ) MessageHelper {
        return .{
            .allocator = allocator,
            .program_name = program_name,
            .version_string = version_string,
            .argument_prompt = argument_prompt,
        };
    }

    fn printDefault(comptime field: std.builtin.Type.StructField, writer: anytype) !void {
        if (field.default_value_ptr == null) {
            if (@typeInfo(field.type) != .optional) {
                try writer.writeAll("(required)");
            }
            return;
        }

        const default_value = @as(*align(1) const field.type, @ptrCast(field.default_value_ptr.?)).*;
        switch (@typeInfo(field.type)) {
            .bool => if (!default_value) return,
            .optional => |optional_info| if (@typeInfo(optional_info.child) == .bool) {
                if (!(default_value orelse false)) return;
            },
            else => {},
        }

        const format_string = "(default: " ++ switch (field.type) {
            []const u8 => "{s}",
            ?[]const u8 => "{?s}",
            else => if (@typeInfo(NonOptionType(field.type)) == .@"enum")
                "{s}"
            else
                "{any}",
        } ++ ")";

        try writer.print(format_string, .{switch (@typeInfo(field.type)) {
            .@"enum" => @tagName(default_value),
            .optional => |optional_info| if (@typeInfo(optional_info.child) == .@"enum")
                @tagName(default_value.?)
            else
                default_value,
            else => default_value,
        }});
    }

    pub fn printHelp(
        self: MessageHelper,
        comptime T: type,
        sub_command_name: ?[]const u8,
        writer: anytype,
    ) !void {
        const option_fields = comptime buildOptionFields(T);
        const sub_command_messages = if (@hasField(T, command_field_name_default)) blk: {
            const fields = std.meta.fields(T);
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, command_field_name_default)) {
                    break :blk subCommandsHelpMsg(
                        field.type,
                        std.meta.fields(field.type).len,
                    );
                }
            }
        } else null;

        const header_template =
            \\ USAGE:
            \\     {s} [OPTIONS] {s}
            \\
            \\ OPTIONS:
            \\
        ;

        var arena_allocator = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        const program_usage_string = if (sub_command_name) |command_name|
            try std.fmt.allocPrint(arena, "{s} {s}", .{ self.program_name, command_name })
        else
            self.program_name;

        const command_usage_string = if (sub_command_messages) |messages| blk: {
            const command_message_offset = 10;
            var list: std.ArrayList([]const u8) = .empty;
            try list.append(arena, "[COMMANDS]\n\n COMMANDS:");
            for (messages) |message_wrapper| {
                if (message_wrapper.name.len <= command_message_offset) {
                    try list.append(arena, try std.fmt.allocPrint(arena, "  {s:<10} {s}", .{ message_wrapper.name, message_wrapper.message }));
                } else {
                    const spaces = " " ** command_message_offset;
                    try list.append(arena, try std.fmt.allocPrint(arena, "  {s}\n  {s} {s}", .{ message_wrapper.name, spaces, message_wrapper.message }));
                }
            }
            break :blk try std.mem.join(arena, "\n", list.items);
        } else if (self.argument_prompt) |prompt| blk: {
            if (sub_command_name == null) {
                break :blk try std.fmt.allocPrint(arena, "[--] {s}", .{prompt});
            } else {
                break :blk "";
            }
        } else "";

        const header_string = try std.fmt.allocPrint(arena, header_template, .{
            program_usage_string,
            command_usage_string,
        });

        try writer.writeAll(header_string);

        const message_offset = 35;
        for (option_fields) |option_field| {
            var current_option_list: std.ArrayList([]const u8) = .empty;
            defer current_option_list.deinit(arena);

            try current_option_list.append(arena, "  ");
            if (option_field.short_name) |short_name| {
                try current_option_list.append(arena, "-");
                try current_option_list.append(arena, try arena.dupe(u8, &[_]u8{short_name}));
                try current_option_list.append(arena, ", ");
            } else {
                try current_option_list.append(arena, "    ");
            }
            try current_option_list.append(arena, "--");
            try current_option_list.append(arena, option_field.long_name);
            try current_option_list.append(arena, option_field.option_type.as_string());

            var blank_count: usize = message_offset;
            for (current_option_list.items) |segment| {
                blank_count = if (blank_count > segment.len) blank_count - segment.len else 0;
            }

            if (blank_count == 0) {
                try current_option_list.append(arena, "\n");
                try current_option_list.append(arena, " " ** message_offset);
            } else while (blank_count > 0) {
                try current_option_list.append(arena, " ");
                blank_count -= 1;
            }

            if (option_field.message) |message_text| {
                try current_option_list.append(arena, message_text);
            }
            const first_part_string = try std.mem.join(arena, "", current_option_list.items);
            try writer.writeAll(first_part_string);

            const struct_fields = std.meta.fields(T);
            inline for (struct_fields) |field| {
                if (std.mem.eql(u8, field.name, option_field.long_name)) {
                    const real_type = NonOptionType(field.type);
                    if (@typeInfo(real_type) == .@"enum") {
                        const enum_options_string = try std.mem.join(arena, "|", std.meta.fieldNames(real_type));
                        try writer.writeAll(" (valid: ");
                        try writer.writeAll(enum_options_string);
                        try writer.writeAll(")");
                    }

                    try MessageHelper.printDefault(
                        field,
                        writer,
                    );
                }
            }

            try writer.writeAll("\n");
        }
    }

    pub fn printVersion(self: MessageHelper) !void {
        const stdout = std.fs.File.stdout();
        var buffer: [1024]u8 = undefined;
        var writer = stdout.writer(&buffer);
        const version_string = self.version_string orelse "Unknown";
        try writer.interface.print("{s}\n", .{version_string});
        try writer.interface.flush();
    }
};

fn StructArguments(
    comptime T: type,
    comptime version_string: ?[]const u8,
    comptime argument_prompt: ?[]const u8,
) type {
    return struct {
        program_name: []const u8,
        // Parsed options (the user-defined struct)
        options: T,
        positional_arguments: [][:0]u8,

        // Unparsed original input arguments
        raw_arguments: [][:0]u8,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn deinit(self: Self) void {
            if (!is_test) {
                std.process.argsFree(self.allocator, self.raw_arguments);
            }
        }

        pub fn printHelp(self: Self, writer: anytype) !void {
            try MessageHelper.init(
                self.allocator,
                self.program_name,
                version_string,
                argument_prompt,
            ).printHelp(T, null, writer);
        }
    };
}

const OptionType = enum(u32) {
    const REQUIRED_VERSION_SHIFT = 16;
    const Self = @This();

    RequiredInt,
    RequiredBool,
    RequiredFloat,
    RequiredString,
    RequiredEnum,

    Int = Self.REQUIRED_VERSION_SHIFT,
    Bool,
    Float,
    String,
    Enum,

    fn from_zig_type(
        comptime T: type,
    ) OptionType {
        return Self.convert(T, false);
    }

    fn convert(comptime T: type, comptime is_optional: bool) OptionType {
        const base_kind: Self = switch (@typeInfo(T)) {
            .int => .RequiredInt,
            .bool => .RequiredBool,
            .float => .RequiredFloat,
            .optional => |optional_info| return Self.convert(optional_info.child, true),
            .pointer => |pointer_info|
                // Only support []const u8.
                if (pointer_info.size == .slice and pointer_info.child == u8 and pointer_info.is_const)
                    .RequiredString
                else {
                    @compileError("Not supported option type:" ++ @typeName(T));
                },
            .@"enum" => .RequiredEnum,
            else => {
                @compileError("Not supported option type:" ++ @typeName(T));
            },
        };
        const kind_value = @intFromEnum(base_kind) + if (is_optional) @as(u32, REQUIRED_VERSION_SHIFT) else 0;
        return @enumFromInt(kind_value);
    }

    fn is_required(self: Self) bool {
        return @intFromEnum(self) < REQUIRED_VERSION_SHIFT;
    }

    fn as_string(self: Self) []const u8 {
        return switch (self) {
            .Int, .RequiredInt => " INTEGER",
            .Bool, .RequiredBool => "",
            .Float, .RequiredFloat => " FLOAT",
            .String, .RequiredString => " STRING",
            .Enum, .RequiredEnum => " STRING",
        };
    }
};

test "parse OptionType" {
    const testcases = [_]std.meta.Tuple(&.{ type, OptionType }){
        .{ i32, OptionType.RequiredInt },
        .{ ?u8, OptionType.Int },
        .{ f32, OptionType.RequiredFloat },
        .{ ?f64, OptionType.Float },
        .{ []const u8, OptionType.RequiredString },
        .{ ?[]const u8, OptionType.String },
        .{ enum { A, B }, OptionType.RequiredEnum },
        .{ ?enum { A, B }, OptionType.Enum },
    };

    inline for (testcases) |testcase| {
        try std.testing.expectEqual(testcase.@"1", comptime OptionType.from_zig_type(testcase.@"0"));
    }
}

const MessageSubCommand = struct {
    name: []const u8,
    message: []const u8,
};

fn subCommandsHelpMsg(comptime T: type, comptime length: usize) ?[length]MessageSubCommand {
    const union_type_info = @typeInfo(T);
    if (union_type_info != .@"union") {
        @compileError("Sub commands should be defined using Union(enum), found " ++ @typeName(T));
    }

    if (@hasDecl(T, "__messages__")) {
        const messages_type = @TypeOf(T.__messages__);
        if (comptime @typeInfo(messages_type) != .@"struct") {
            @compileError("__messages__ should be defined using struct");
        }

        var message_wrappers: [std.meta.fields(messages_type).len]MessageSubCommand = undefined;
        const messages_fields = std.meta.fields(messages_type);
        const union_fields = std.meta.fields(T);

        inline for (messages_fields, 0..) |message_field, index| {
            inline for (union_fields) |union_field| {
                if (comptime std.mem.eql(u8, message_field.name, union_field.name)) {
                    message_wrappers[index] = MessageSubCommand{
                        .name = message_field.name,
                        .message = @field(T.__messages__, message_field.name),
                    };
                    break;
                }
            } else {
                @compileError("No such sub_cmd exists, name: " ++ message_field.name);
            }
        }

        return message_wrappers;
    }

    return null;
}

fn SubCommandsType(comptime T: type) type {
    const union_type_info = @typeInfo(T);
    if (union_type_info != .@"union") {
        @compileError("Sub commands should be defined using Union(enum), found " ++ @typeName(T));
    }

    const union_fields = std.meta.fields(T);
    var struct_fields: [union_fields.len]std.builtin.Type.StructField = undefined;
    inline for (union_fields, 0..) |union_field, index| {
        if (comptime @typeInfo(union_field.type) != .@"struct") {
            @compileError("Sub command should be defined using struct, found " ++ @typeName(@typeInfo(union_field.type)));
        }

        const ParserType = CommandParser(union_field.type);
        const default_value = ParserType{};
        struct_fields[index] = .{
            .name = union_field.name,
            .type = ParserType,
            .default_value_ptr = @ptrCast(&default_value),
            .is_comptime = false,
            .alignment = @alignOf(ParserType),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn CommandParser(comptime T: type) type {
    return struct {
        option_fields: [getOptionLength(T)]OptionField = buildOptionFields(T),
        option_commands: if (@hasField(T, command_field_name_default)) blk: {
            const fields = std.meta.fields(T);
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, command_field_name_default)) {
                    break :blk SubCommandsType(field.type);
                }
            } else {
                unreachable;
            }
        } else void = if (@hasField(T, command_field_name_default)) .{} else {},
    };
}

/// `T` is a struct, which defines options.
fn OptionParser(
    comptime T: type,
) type {
    return struct {
        allocator: std.mem.Allocator,

        const Self = @This();

        fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
            };
        }

        const ParseState = enum {
            start,
            waitValue,
            arguments,
        };

        fn parseCommand(
            comptime Args: type,
            input_arguments: [][:0]u8,
            argument_index: *usize,
            message_helper: MessageHelper,
            sub_command_name: ?[]const u8,
        ) !Args {
            var options: Args = undefined;
            var command_parser = CommandParser(Args){};
            var sub_command_is_set = false;

            const struct_fields = std.meta.fields(Args);
            inline for (struct_fields) |field| {
                if (comptime std.mem.eql(u8, field.name, command_field_name_default)) {
                    if (field.default_value_ptr) |value_ptr| {
                        sub_command_is_set = true;
                        @field(options, field.name) = @as(*align(1) const field.type, @ptrCast(value_ptr)).*;
                    }
                    continue;
                }

                if (field.default_value_ptr) |value_ptr| {
                    @field(options, field.name) = @as(*align(1) const field.type, @ptrCast(value_ptr)).*;
                } else {
                    const option_type = OptionType.from_zig_type(field.type);
                    if (!option_type.is_required()) {
                        if (@typeInfo(field.type) == .optional) {
                            @field(options, field.name) = null;
                        }
                    }
                }
            }

            var state = ParseState.start;
            var current_option: ?*OptionField = null;

            outer: while (argument_index.* < input_arguments.len) {
                const argument = input_arguments[argument_index.*];
                argument_index.* += 1;

                switch (state) {
                    .start => {
                        if (std.mem.eql(u8, argument, "--")) {
                            state = .arguments;
                            continue;
                        }
                        if (!std.mem.startsWith(u8, argument, "-")) {
                            state = .arguments;
                            argument_index.* -= 1;
                            continue;
                        }

                        if (std.mem.startsWith(u8, argument[1..], "-")) {
                            const long_name = argument[2..];
                            for (&command_parser.option_fields) |*option_field| {
                                if (std.mem.eql(u8, option_field.long_name, long_name)) {
                                    current_option = option_field;
                                    break;
                                }
                            }
                        } else {
                            const short_name_input = argument[1..];
                            if (short_name_input.len != 1) {
                                if (!is_test) {
                                    std.log.err("No such short option '{s}'", .{argument});
                                }
                                return error.NoOption;
                            }
                            const short_name_char = short_name_input[0];
                            for (&command_parser.option_fields) |*option_field| {
                                if (option_field.short_name) |short_name| {
                                    if (short_name == short_name_char) {
                                        current_option = option_field;
                                        break;
                                    }
                                }
                            }
                        }

                        const option = current_option orelse {
                            if (!is_test) {
                                std.log.err("Unknown option '{s}'", .{argument});
                            }
                            return error.NoOption;
                        };

                        if (option.option_type == .Bool or option.option_type == .RequiredBool) {
                            _ = try setOptionValue(Args, &options, option.long_name, "true");
                            option.is_set = true;
                            state = .start;
                            current_option = null;

                            if (!is_test) {
                                if (std.mem.eql(u8, option.long_name, "help")) {
                                    var stdout_buffer: [1024]u8 = undefined;
                                    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
                                    const stdout = &stdout_writer.interface;
                                    message_helper.printHelp(Args, sub_command_name, stdout) catch @panic("OOM");
                                    std.process.exit(0);
                                } else if (std.mem.eql(u8, option.long_name, "version")) {
                                    message_helper.printVersion() catch @panic("OOM");
                                    std.process.exit(0);
                                }
                            }
                        } else {
                            state = .waitValue;
                        }
                    },
                    .arguments => {
                        if (@TypeOf(command_parser.option_commands) != void) {
                            const sub_parser_type = @TypeOf(command_parser.option_commands);
                            const sub_parser_fields = std.meta.fields(sub_parser_type);
                            inline for (sub_parser_fields) |field| {
                                if (std.mem.eql(u8, field.name, argument)) {
                                    const UnionType = @TypeOf(@field(options, command_field_name_default));
                                    const union_fields = std.meta.fields(UnionType);
                                    inline for (union_fields) |union_field| {
                                        if (comptime std.mem.eql(u8, union_field.name, field.name)) {
                                            const value = try Self.parseCommand(
                                                union_field.type,
                                                input_arguments,
                                                argument_index,
                                                message_helper,
                                                field.name,
                                            );
                                            @field(options, command_field_name_default) = @unionInit(UnionType, field.name, value);
                                            sub_command_is_set = true;
                                            break :outer;
                                        }
                                    }
                                }
                            }
                        }
                        argument_index.* -= 1;
                        break :outer;
                    },
                    .waitValue => {
                        const option = current_option.?;
                        _ = try setOptionValue(Args, &options, option.long_name, argument);
                        option.is_set = true;
                        state = .start;
                        current_option = null;
                    },
                }
            }

            switch (state) {
                .start, .arguments => {},
                .waitValue => return error.MissingOptionValue,
            }

            if (@TypeOf(command_parser.option_commands) != void and !sub_command_is_set) {
                return error.MissingSubCommand;
            }

            for (command_parser.option_fields) |option_field| {
                if (option_field.option_type.is_required()) {
                    if (!option_field.is_set) {
                        if (!is_test) {
                            std.log.err("Missing required option '{s}'", .{option_field.long_name});
                        }
                        return error.MissingRequiredOption;
                    }
                }
            }

            return options;
        }

        fn parse(
            self: *Self,
            comptime argument_prompt: ?[]const u8,
            comptime version_string: ?[]const u8,
            input_arguments: [][:0]u8,
        ) OptionError!StructArguments(T, version_string, argument_prompt) {
            if (input_arguments.len == 0) {
                return error.NoProgram;
            }

            const arguments_to_parse = input_arguments[1..];
            var argument_index: usize = 0;
            const message_helper = MessageHelper.init(
                self.allocator,
                input_arguments[0],
                version_string,
                argument_prompt,
            );
            const parsed_options = try Self.parseCommand(
                T,
                arguments_to_parse,
                &argument_index,
                message_helper,
                null,
            );
            var result = StructArguments(T, version_string, argument_prompt){
                .program_name = input_arguments[0],
                .allocator = self.allocator,
                .options = parsed_options,
                .positional_arguments = arguments_to_parse[argument_index..],
                .raw_arguments = input_arguments,
            };
            errdefer result.deinit();

            return result;
        }
    };
}

fn getSignedness(comptime option_type: type) std.builtin.Signedness {
    return switch (@typeInfo(option_type)) {
        .int => |int_info| int_info.signedness,
        .optional => |optional_info| getSignedness(optional_info.child),
        else => .unsigned,
    };
}

// return true when set successfully
fn setOptionValue(comptime Args: type, options: *Args, long_name: []const u8, raw_value: []const u8) !bool {
    const fields = std.meta.fields(Args);
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, command_field_name_default)) {
            continue;
        }

        if (std.mem.eql(u8, field.name, long_name)) {
            const kind = OptionType.from_zig_type(field.type);
            const BaseType = NonOptionType(field.type);
            switch (kind) {
                .Int, .RequiredInt => {
                    if (comptime @typeInfo(BaseType) == .int) {
                        @field(options, field.name) = switch (getSignedness(field.type)) {
                            .signed => try std.fmt.parseInt(BaseType, raw_value, 0),
                            .unsigned => try std.fmt.parseUnsigned(BaseType, raw_value, 0),
                        };
                    }
                },
                .Float, .RequiredFloat => {
                    if (comptime @typeInfo(BaseType) == .float) {
                        @field(options, field.name) = try std.fmt.parseFloat(BaseType, raw_value);
                    }
                },
                .String, .RequiredString => {
                    if (comptime BaseType == []const u8) {
                        @field(options, field.name) = raw_value;
                    }
                },
                .Bool, .RequiredBool => {
                    if (comptime BaseType == bool) {
                        @field(options, field.name) = std.mem.eql(u8, raw_value, "true") or std.mem.eql(u8, raw_value, "1");
                    }
                },
                .Enum, .RequiredEnum => {
                    if (comptime @typeInfo(BaseType) == .@"enum") {
                        if (std.meta.stringToEnum(BaseType, raw_value)) |value| {
                            @field(options, field.name) = value;
                        } else {
                            return error.InvalidEnumValue;
                        }
                    }
                },
            }

            return true;
        }
    }

    return false;
}

const TestArguments = struct {
    help: bool,
    rate: ?f32 = 2,
    timeout: u16,
    @"user-agent": ?[]const u8 = "Brave",

    pub const __shorts__ = .{
        .help = .h,
        .rate = .r,
    };

    pub const __messages__ = .{ .help = "print this help message" };
};

test "parse/valid option values" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--help"),
        try gpa.dupeZ(u8, "--rate"),
        try gpa.dupeZ(u8, "1.2"),
        try gpa.dupeZ(u8, "--timeout"),
        try gpa.dupeZ(u8, "30"),
        try gpa.dupeZ(u8, "--user-agent"),
        try gpa.dupeZ(u8, "firefox"),
        // Positional arguments.
        try gpa.dupeZ(u8, "hello"),
        try gpa.dupeZ(u8, "world"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };

    var parser = OptionParser(TestArguments).init(gpa);
    const result = try parser.parse("...", null, &input_arguments);
    defer result.deinit();

    try std.testing.expectEqualDeep(TestArguments{
        .help = true,
        .rate = 1.2,
        .timeout = 30,
        .@"user-agent" = "firefox",
    }, result.options);

    const expected_positional = input_arguments[input_arguments.len - 2 ..];
    try std.testing.expectEqualDeep(result.positional_arguments, expected_positional);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.printHelp(writer_list.writer(gpa));
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\  -h, --help                       print this help message(required)
        \\  -r, --rate FLOAT                 (default: 2)
        \\      --timeout INTEGER            (required)
        \\      --user-agent STRING          (default: Brave)
        \\
    , writer_list.items);
}

test "parse/bool value" {
    const gpa = std.testing.allocator;
    {
        var input_arguments = [_][:0]u8{
            try gpa.dupeZ(u8, "awesome-cli"),
            try gpa.dupeZ(u8, "--help"),
        };
        defer for (input_arguments) |argument| {
            gpa.free(argument);
        };
        var parser = OptionParser(struct { help: bool }).init(gpa);
        const result = try parser.parse(null, null, &input_arguments);
        defer result.deinit();

        try std.testing.expect(result.options.help);
        try std.testing.expectEqual(result.positional_arguments.len, 0);
    }
    {
        var input_arguments = [_][:0]u8{
            try gpa.dupeZ(u8, "awesome-cli"),
            try gpa.dupeZ(u8, "--help"),
            try gpa.dupeZ(u8, "true"),
        };
        defer for (input_arguments) |argument| {
            gpa.free(argument);
        };
        var parser = OptionParser(struct { help: bool }).init(gpa);
        const result = try parser.parse(null, null, &input_arguments);
        defer result.deinit();

        try std.testing.expect(result.options.help);
        const expected_positional = input_arguments[input_arguments.len - 1 ..];
        try std.testing.expectEqualDeep(
            result.positional_arguments,
            expected_positional,
        );
    }
}

test "parse/missing required arguments" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "abc"),
        try gpa.dupeZ(u8, "def"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.MissingRequiredOption, parser.parse(null, null, &input_arguments));
}

test "parse/invalid u16 values" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--timeout"),
        try gpa.dupeZ(u8, "not-a-number"),
        try gpa.dupeZ(u8, "--help"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(null, null, &input_arguments));
}

test "parse/invalid f32 values" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--rate"),
        try gpa.dupeZ(u8, "not-a-number"),
        try gpa.dupeZ(u8, "--help"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(null, null, &input_arguments));
}

test "parse/unknown option" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "-h"),
        try gpa.dupeZ(u8, "--timeout"),
        try gpa.dupeZ(u8, "1"),
        try gpa.dupeZ(u8, "--notexists"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.NoOption, parser.parse(null, null, &input_arguments));
}

test "parse/missing option value" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "-h"),
        try gpa.dupeZ(u8, "--timeout"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.MissingOptionValue, parser.parse(null, null, &input_arguments));
}

test "parse/default value" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(struct {
        a1: []const u8 = "A1",
        a2: ?[]const u8 = "A2",
        b1: u8 = 1,
        b2: ?u8 = 11,
        c1: f16 = 1.5,
        c2: ?f16 = 2.5,
        d1: bool = true,
        d2: ?bool = false,

        const __messages__ = .{ .d2 = "padding message" };
    }).init(gpa);
    const result = try parser.parse("...", null, &input_arguments);
    try std.testing.expectEqualStrings("A1", result.options.a1);
    try std.testing.expectEqual(result.positional_arguments.len, 0);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.printHelp(writer_list.writer(gpa));
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\      --a1 STRING                  (default: A1)
        \\      --a2 STRING                  (default: A2)
        \\      --b1 INTEGER                 (default: 1)
        \\      --b2 INTEGER                 (default: 11)
        \\      --c1 FLOAT                   (default: 1.5)
        \\      --c2 FLOAT                   (default: 2.5)
        \\      --d1                         (default: true)
        \\      --d2                         padding message
        \\
    , writer_list.items);
}

test "parse/enum option" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--a3"),
        try gpa.dupeZ(u8, "Y"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(struct {
        a1: ?enum { A, B } = .A,
        a2: enum { C, D } = .D,
        a3: enum { X, Y },
    }).init(gpa);
    const result = try parser.parse("...", null, &input_arguments);
    defer result.deinit();

    try std.testing.expectEqual(result.options.a1, .A);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.printHelp(writer_list.writer(gpa));
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\      --a1 STRING                   (valid: A|B)(default: A)
        \\      --a2 STRING                   (valid: C|D)(default: D)
        \\      --a3 STRING                   (valid: X|Y)(required)
        \\
    , writer_list.items);
}

test "parse/positional arguments" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--"),
        try gpa.dupeZ(u8, "-a"),
        try gpa.dupeZ(u8, "2"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(struct {
        a: u8 = 1,
    }).init(gpa);
    const result = try parser.parse("...", null, &input_arguments);
    defer result.deinit();

    try std.testing.expectEqualDeep(result.options.a, 1);
    const expected_positional = input_arguments[input_arguments.len - 2 ..];
    try std.testing.expectEqualDeep(result.positional_arguments, expected_positional);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.printHelp(writer_list.writer(gpa));
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\      --a INTEGER                  (default: 1)
        \\
    , writer_list.items);
}

test "parse/sub commands" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--a"),
        try gpa.dupeZ(u8, "2"),
        try gpa.dupeZ(u8, "cmd1"),
        try gpa.dupeZ(u8, "--aa"),
        try gpa.dupeZ(u8, "22"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(struct {
        a: u8 = 1,
        __commands__: union(enum) {
            cmd1: struct {
                aa: u8,
            },
            cmd2: struct {
                bb: u8 = 2,
            },

            pub const __messages__ = .{
                .cmd1 = "This is command 1",
                .cmd2 = "This is command 2",
            };
        },
    }).init(gpa);
    const result = try parser.parse("...", null, &input_arguments);
    defer result.deinit();

    try std.testing.expectEqualDeep(result.options.a, 2);
    try std.testing.expectEqual(result.positional_arguments.len, 0);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.printHelp(writer_list.writer(gpa));
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [COMMANDS]
        \\
        \\ COMMANDS:
        \\  cmd1       This is command 1
        \\  cmd2       This is command 2
        \\
        \\ OPTIONS:
        \\      --a INTEGER                  (default: 1)
        \\
    , writer_list.items);
}
