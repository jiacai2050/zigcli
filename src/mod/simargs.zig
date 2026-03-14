//! A simple, opinionated, struct-based argument parser in Zig

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const is_test = @import("builtin").is_test;

const OptionParseError = error{
    NoProgram,
    NoOption,
    MissingRequiredOption,
    MissingOptionValue,
    InvalidEnumValue,
    MissingSubCommand,
};

const command_field_name_default = "__commands__";

const OptionParseErrorAll = OptionParseError ||
    std.mem.Allocator.Error ||
    std.fmt.ParseIntError ||
    std.fmt.ParseFloatError ||
    std.process.ArgIterator.InitError;

/// Parses arguments according to the given structure.
/// - `T` is the configuration of the arguments.
pub fn argumentsParse(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime argument_prompt: ?[]const u8,
    comptime version_string: ?[]const u8,
) OptionParseErrorAll!ArgumentsResult(T, version_string, argument_prompt) {
    const arguments = try std.process.argsAlloc(allocator);
    var parser = OptionParser(T).init(allocator);
    return parser.parse(argument_prompt, version_string, arguments);
}

const OptionField = struct {
    long_name: []const u8,
    option_kind: OptionKind,
    short_name: ?u8 = null,
    message: ?[]const u8 = null,
    // Whether this option is set by the user or has a default value.
    is_set: bool = false,
};

fn optionCountGet(comptime T: type) usize {
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

fn optionFieldArrayBuild(comptime T: type) [optionCountGet(T)]OptionField {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") {
        @compileError("Option configuration should be defined using struct, found " ++ @typeName(T));
    }

    var option_fields: [optionCountGet(T)]OptionField = undefined;
    const fields = std.meta.fields(T);
    var current_index: usize = 0;
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, command_field_name_default)) {
            continue;
        }

        const long_name = field.name;
        const option_kind = OptionKind.fromZigType(field.type);
        option_fields[current_index] = .{
            .long_name = long_name,
            .option_kind = option_kind,
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

test "option field array build" {
    const fields = comptime optionFieldArrayBuild(struct {
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
        .{ .long_name = "verbose", .short_name = 'v', .message = "show verbose log", .option_kind = .RequiredBool },
        .{ .long_name = "help", .option_kind = .Bool },
        .{ .long_name = "timeout", .option_kind = .RequiredInt },
        .{ .long_name = "user-agent", .option_kind = .String },
    }, fields);
}

fn typeNonOptionalGet(comptime option_type: type) type {
    return switch (@typeInfo(option_type)) {
        .optional => |optional_info| typeNonOptionalGet(optional_info.child),
        else => option_type,
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
            else => if (@typeInfo(typeNonOptionalGet(field.type)) == .@"enum")
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

    pub fn versionPrint(
        self: MessageHelper,
    ) !void {
        const stdout = std.fs.File.stdout();
        var buffer: [1024]u8 = undefined;
        var writer = stdout.writer(&buffer);
        const version_string = self.version_string orelse "Unknown";
        try writer.interface.print("{s}\n", .{version_string});
        try writer.interface.flush();
    }

    pub fn helpPrint(
        self: MessageHelper,
        comptime T: type,
        sub_command_name: ?[]const u8,
        writer: anytype,
    ) !void {
        const option_fields = comptime optionFieldArrayBuild(T);
        const sub_command_messages = if (@hasField(T, command_field_name_default)) blk: {
            const fields = std.meta.fields(T);
            inline for (fields) |field| {
                if (comptime std.mem.eql(u8, field.name, command_field_name_default)) {
                    break :blk subCommandMessageArrayBuild(
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
            try current_option_list.append(arena, option_field.option_kind.asString());

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
                    const real_type = typeNonOptionalGet(field.type);
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
};

fn ArgumentsResult(
    comptime T: type,
    comptime version_string: ?[]const u8,
    comptime argument_prompt: ?[]const u8,
) type {
    return struct {
        program_name: []const u8,
        // Parsed arguments
        arguments: T,
        positional_arguments: [][:0]u8,

        // Unparsed arguments
        arguments_raw: [][:0]u8,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn deinit(self: Self) void {
            if (!is_test) {
                std.process.argsFree(self.allocator, self.arguments_raw);
            }
        }

        pub fn helpPrint(self: Self, writer: anytype) !void {
            try MessageHelper.init(
                self.allocator,
                self.program_name,
                version_string,
                argument_prompt,
            ).helpPrint(T, null, writer);
        }
    };
}

const OptionKind = enum(u32) {
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

    fn fromZigType(
        comptime T: type,
    ) OptionKind {
        return Self.convert(T, false);
    }

    fn convert(comptime T: type, comptime is_optional: bool) OptionKind {
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

    fn isRequired(self: Self) bool {
        return @intFromEnum(self) < REQUIRED_VERSION_SHIFT;
    }

    fn asString(self: Self) []const u8 {
        return switch (self) {
            .Int, .RequiredInt => " INTEGER",
            .Bool, .RequiredBool => "",
            .Float, .RequiredFloat => " FLOAT",
            .String, .RequiredString => " STRING",
            .Enum, .RequiredEnum => " STRING",
        };
    }
};

test "parse OptionKind" {
    const testcases = [_]std.meta.Tuple(&.{ type, OptionKind }){
        .{ i32, OptionKind.RequiredInt },
        .{ ?u8, OptionKind.Int },
        .{ f32, OptionKind.RequiredFloat },
        .{ ?f64, OptionKind.Float },
        .{ []const u8, OptionKind.RequiredString },
        .{ ?[]const u8, OptionKind.String },
        .{ enum { A, B }, OptionKind.RequiredEnum },
        .{ ?enum { A, B }, OptionKind.Enum },
    };

    inline for (testcases) |testcase| {
        try std.testing.expectEqual(testcase.@"1", comptime OptionKind.fromZigType(testcase.@"0"));
    }
}

const MessageSubCommand = struct {
    name: []const u8,
    message: []const u8,
};

fn subCommandMessageArrayBuild(comptime T: type, comptime length: usize) ?[length]MessageSubCommand {
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

fn subCommandTypeBuild(comptime T: type) type {
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
        option_fields: [optionCountGet(T)]OptionField = optionFieldArrayBuild(T),
        sub_commands_parser: if (@hasField(T, command_field_name_default)) blk: {
            const fields = std.meta.fields(T);
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, command_field_name_default)) {
                    break :blk subCommandTypeBuild(field.type);
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
            arguments_input: [][:0]u8,
            argument_index: *usize,
            message_helper: MessageHelper,
            sub_command_name: ?[]const u8,
        ) !Args {
            var arguments: Args = undefined;
            var command_parser = CommandParser(Args){};
            var sub_command_is_set = false;

            const struct_fields = std.meta.fields(Args);
            inline for (struct_fields) |field| {
                if (comptime std.mem.eql(u8, field.name, command_field_name_default)) {
                    if (field.default_value_ptr) |value_ptr| {
                        sub_command_is_set = true;
                        @field(arguments, field.name) = @as(*align(1) const field.type, @ptrCast(value_ptr)).*;
                    }
                    continue;
                }

                if (field.default_value_ptr) |value_ptr| {
                    @field(arguments, field.name) = @as(*align(1) const field.type, @ptrCast(value_ptr)).*;
                } else {
                    const option_kind = OptionKind.fromZigType(field.type);
                    if (!option_kind.isRequired()) {
                        if (@typeInfo(field.type) == .optional) {
                            @field(arguments, field.name) = null;
                        }
                    }
                }
            }

            var state = ParseState.start;
            var current_option: ?*OptionField = null;

            outer: while (argument_index.* < arguments_input.len) {
                const argument = arguments_input[argument_index.*];
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

                        if (option.option_kind == .Bool or option.option_kind == .RequiredBool) {
                            _ = try optionValueSet(Args, &arguments, option.long_name, "true");
                            option.is_set = true;
                            state = .start;
                            current_option = null;

                            if (!is_test) {
                                if (std.mem.eql(u8, option.long_name, "help")) {
                                    var stdout_buffer: [1024]u8 = undefined;
                                    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
                                    const stdout = &stdout_writer.interface;
                                    message_helper.helpPrint(Args, sub_command_name, stdout) catch @panic("OOM");
                                    std.process.exit(0);
                                } else if (std.mem.eql(u8, option.long_name, "version")) {
                                    message_helper.versionPrint() catch @panic("OOM");
                                    std.process.exit(0);
                                }
                            }
                        } else {
                            state = .waitValue;
                        }
                    },
                    .arguments => {
                        if (@TypeOf(command_parser.sub_commands_parser) != void) {
                            const sub_parser_type = @TypeOf(command_parser.sub_commands_parser);
                            const sub_parser_fields = std.meta.fields(sub_parser_type);
                            inline for (sub_parser_fields) |field| {
                                if (std.mem.eql(u8, field.name, argument)) {
                                    const UnionType = @TypeOf(@field(arguments, command_field_name_default));
                                    const union_fields = std.meta.fields(UnionType);
                                    inline for (union_fields) |union_field| {
                                        if (comptime std.mem.eql(u8, union_field.name, field.name)) {
                                            const value = try Self.parseCommand(
                                                union_field.type,
                                                arguments_input,
                                                argument_index,
                                                message_helper,
                                                field.name,
                                            );
                                            @field(arguments, command_field_name_default) = @unionInit(UnionType, field.name, value);
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
                        _ = try optionValueSet(Args, &arguments, option.long_name, argument);
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

            if (@TypeOf(command_parser.sub_commands_parser) != void and !sub_command_is_set) {
                return error.MissingSubCommand;
            }

            for (command_parser.option_fields) |option_field| {
                if (option_field.option_kind.isRequired()) {
                    if (!option_field.is_set) {
                        if (!is_test) {
                            std.log.err("Missing required option '{s}'", .{option_field.long_name});
                        }
                        return error.MissingRequiredOption;
                    }
                }
            }

            return arguments;
        }

        fn parse(
            self: *Self,
            comptime argument_prompt: ?[]const u8,
            comptime version_string: ?[]const u8,
            arguments_input: [][:0]u8,
        ) OptionParseErrorAll!ArgumentsResult(T, version_string, argument_prompt) {
            if (arguments_input.len == 0) {
                return error.NoProgram;
            }

            const arguments_to_parse = arguments_input[1..];
            var argument_index: usize = 0;
            const message_helper = MessageHelper.init(
                self.allocator,
                arguments_input[0],
                version_string,
                argument_prompt,
            );
            const parsed_arguments = try Self.parseCommand(
                T,
                arguments_to_parse,
                &argument_index,
                message_helper,
                null,
            );
            var result = ArgumentsResult(T, version_string, argument_prompt){
                .program_name = arguments_input[0],
                .allocator = self.allocator,
                .arguments = parsed_arguments,
                .positional_arguments = arguments_to_parse[argument_index..],
                .arguments_raw = arguments_input,
            };
            errdefer result.deinit();

            return result;
        }
    };
}

fn typeSignednessGet(comptime option_type: type) std.builtin.Signedness {
    return switch (@typeInfo(option_type)) {
        .int => |int_info| int_info.signedness,
        .optional => |optional_info| typeSignednessGet(optional_info.child),
        else => .unsigned,
    };
}

// return true when set successfully
fn optionValueSet(comptime Args: type, arguments: *Args, long_name: []const u8, raw_value: []const u8) !bool {
    const fields = std.meta.fields(Args);
    inline for (fields) |field| {
        if (comptime std.mem.eql(u8, field.name, command_field_name_default)) {
            continue;
        }

        if (std.mem.eql(u8, field.name, long_name)) {
            const kind = OptionKind.fromZigType(field.type);
            const BaseType = typeNonOptionalGet(field.type);
            switch (kind) {
                .Int, .RequiredInt => {
                    if (comptime @typeInfo(BaseType) == .int) {
                        @field(arguments, field.name) = switch (typeSignednessGet(field.type)) {
                            .signed => try std.fmt.parseInt(BaseType, raw_value, 0),
                            .unsigned => try std.fmt.parseUnsigned(BaseType, raw_value, 0),
                        };
                    }
                },
                .Float, .RequiredFloat => {
                    if (comptime @typeInfo(BaseType) == .float) {
                        @field(arguments, field.name) = try std.fmt.parseFloat(BaseType, raw_value);
                    }
                },
                .String, .RequiredString => {
                    if (comptime BaseType == []const u8) {
                        @field(arguments, field.name) = raw_value;
                    }
                },
                .Bool, .RequiredBool => {
                    if (comptime BaseType == bool) {
                        @field(arguments, field.name) = std.mem.eql(u8, raw_value, "true") or std.mem.eql(u8, raw_value, "1");
                    }
                },
                .Enum, .RequiredEnum => {
                    if (comptime @typeInfo(BaseType) == .@"enum") {
                        if (std.meta.stringToEnum(BaseType, raw_value)) |value| {
                            @field(arguments, field.name) = value;
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
    var arguments_input = [_][:0]u8{
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
    defer for (arguments_input) |argument| {
        gpa.free(argument);
    };

    var parser = OptionParser(TestArguments).init(gpa);
    const result = try parser.parse("...", null, &arguments_input);
    defer result.deinit();

    try std.testing.expectEqualDeep(TestArguments{
        .help = true,
        .rate = 1.2,
        .timeout = 30,
        .@"user-agent" = "firefox",
    }, result.arguments);

    const expected_positional = arguments_input[arguments_input.len - 2 ..];
    try std.testing.expectEqualDeep(result.positional_arguments, expected_positional);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.helpPrint(writer_list.writer(gpa));
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
        var arguments_input = [_][:0]u8{
            try gpa.dupeZ(u8, "awesome-cli"),
            try gpa.dupeZ(u8, "--help"),
        };
        defer for (arguments_input) |argument| {
            gpa.free(argument);
        };
        var parser = OptionParser(struct { help: bool }).init(gpa);
        const result = try parser.parse(null, null, &arguments_input);
        defer result.deinit();

        try std.testing.expect(result.arguments.help);
        try std.testing.expectEqual(result.positional_arguments.len, 0);
    }
    {
        var arguments_input = [_][:0]u8{
            try gpa.dupeZ(u8, "awesome-cli"),
            try gpa.dupeZ(u8, "--help"),
            try gpa.dupeZ(u8, "true"),
        };
        defer for (arguments_input) |argument| {
            gpa.free(argument);
        };
        var parser = OptionParser(struct { help: bool }).init(gpa);
        const result = try parser.parse(null, null, &arguments_input);
        defer result.deinit();

        try std.testing.expect(result.arguments.help);
        const expected_positional = arguments_input[arguments_input.len - 1 ..];
        try std.testing.expectEqualDeep(
            result.positional_arguments,
            expected_positional,
        );
    }
}

test "parse/missing required arguments" {
    const gpa = std.testing.allocator;
    var arguments_input = [_][:0]u8{
        try gpa.dupeZ(u8, "abc"),
        try gpa.dupeZ(u8, "def"),
    };
    defer for (arguments_input) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.MissingRequiredOption, parser.parse(null, null, &arguments_input));
}

test "parse/invalid u16 values" {
    const gpa = std.testing.allocator;
    var arguments_input = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--timeout"),
        try gpa.dupeZ(u8, "not-a-number"),
        try gpa.dupeZ(u8, "--help"),
    };
    defer for (arguments_input) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(null, null, &arguments_input));
}

test "parse/invalid f32 values" {
    const gpa = std.testing.allocator;
    var arguments_input = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--rate"),
        try gpa.dupeZ(u8, "not-a-number"),
        try gpa.dupeZ(u8, "--help"),
    };
    defer for (arguments_input) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(null, null, &arguments_input));
}

test "parse/unknown option" {
    const gpa = std.testing.allocator;
    var arguments_input = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "-h"),
        try gpa.dupeZ(u8, "--timeout"),
        try gpa.dupeZ(u8, "1"),
        try gpa.dupeZ(u8, "--notexists"),
    };
    defer for (arguments_input) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.NoOption, parser.parse(null, null, &arguments_input));
}

test "parse/missing option value" {
    const gpa = std.testing.allocator;
    var arguments_input = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "-h"),
        try gpa.dupeZ(u8, "--timeout"),
    };
    defer for (arguments_input) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.MissingOptionValue, parser.parse(null, null, &arguments_input));
}

test "parse/default value" {
    const gpa = std.testing.allocator;
    var arguments_input = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
    };
    defer for (arguments_input) |argument| {
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
    const result = try parser.parse("...", null, &arguments_input);
    try std.testing.expectEqualStrings("A1", result.arguments.a1);
    try std.testing.expectEqual(result.positional_arguments.len, 0);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.helpPrint(writer_list.writer(gpa));
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
    var arguments_input = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--a3"),
        try gpa.dupeZ(u8, "Y"),
    };
    defer for (arguments_input) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(struct {
        a1: ?enum { A, B } = .A,
        a2: enum { C, D } = .D,
        a3: enum { X, Y },
    }).init(gpa);
    const result = try parser.parse("...", null, &arguments_input);
    defer result.deinit();

    try std.testing.expectEqual(result.arguments.a1, .A);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.helpPrint(writer_list.writer(gpa));
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
    var arguments_input = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--"),
        try gpa.dupeZ(u8, "-a"),
        try gpa.dupeZ(u8, "2"),
    };
    defer for (arguments_input) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(struct {
        a: u8 = 1,
    }).init(gpa);
    const result = try parser.parse("...", null, &arguments_input);
    defer result.deinit();

    try std.testing.expectEqualDeep(result.arguments.a, 1);
    const expected_positional = arguments_input[arguments_input.len - 2 ..];
    try std.testing.expectEqualDeep(result.positional_arguments, expected_positional);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.helpPrint(writer_list.writer(gpa));
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
    var arguments_input = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--a"),
        try gpa.dupeZ(u8, "2"),
        try gpa.dupeZ(u8, "cmd1"),
        try gpa.dupeZ(u8, "--aa"),
        try gpa.dupeZ(u8, "22"),
    };
    defer for (arguments_input) |argument| {
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
    const result = try parser.parse("...", null, &arguments_input);
    defer result.deinit();

    try std.testing.expectEqualDeep(result.arguments.a, 2);
    try std.testing.expectEqual(result.positional_arguments.len, 0);

    var writer_list: std.ArrayList(u8) = .empty;
    defer writer_list.deinit(gpa);

    try result.helpPrint(writer_list.writer(gpa));
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
