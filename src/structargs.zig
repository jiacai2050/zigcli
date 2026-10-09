//! structargs turns a Zig struct into a command-line interface.

const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
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
    std.process.Args.ToSliceError;

/// Configuration options for the parser.
pub const ParseOptions = struct {
    argument_prompt: ?[]const u8 = null,
    version_string: ?[]const u8 = null,
    print_help_and_exit: bool = true,
    /// When true, print the help text to stderr before returning any parse error.
    print_help_on_error: bool = true,
};

/// Parses arguments according to the given structure.
/// - `allocator` is used to allocate memory for raw arguments.
/// - `args` is the source of process arguments (from `init.minimal.args`).
/// - `Options` is the configuration of the arguments.
/// - `options` contains metadata like argument prompt and version string.
pub fn parse(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: std.process.Args,
    comptime Options: type,
    comptime options: ParseOptions,
) OptionError!ParseResult(Options, options.version_string, options.argument_prompt) {
    const raw_arguments = try args.toSlice(allocator);
    errdefer allocator.free(raw_arguments);

    var parser = OptionParser(Options).init(allocator, io);
    return parser.parse(raw_arguments, options);
}

const OptionField = struct {
    long_name: []const u8,
    option_type: OptionType,
    short_name: ?u8 = null,
    message: ?[]const u8 = null,
    // Whether this option is set by the user or has a default value.
    is_set: bool = false,
};

fn getOptionLength(comptime Options: type) usize {
    const type_info = @typeInfo(Options);
    if (type_info != .@"struct") {
        @compileError(
            "Option configuration should be defined using struct, found " ++ @typeName(Options),
        );
    }

    const s = type_info.@"struct";
    inline for (s.field_names) |name| {
        if (std.mem.eql(u8, name, command_field_name_default)) {
            return s.field_names.len - 1;
        }
    }

    return s.field_names.len;
}

fn buildOptionFields(comptime Options: type) [getOptionLength(Options)]OptionField {
    const type_info = @typeInfo(Options);
    if (type_info != .@"struct") {
        @compileError(
            "Option configuration should be defined using struct, found " ++ @typeName(Options),
        );
    }

    var option_fields: [getOptionLength(Options)]OptionField = undefined;
    const s = type_info.@"struct";
    var current_index: usize = 0;
    inline for (s.field_names, s.field_types, s.field_attrs) |name, field_type, attrs| {
        if (std.mem.eql(u8, name, command_field_name_default)) {
            continue;
        }

        const long_name = name;
        const option_type = OptionType.from_zig_type(field_type);
        option_fields[current_index] = .{
            .long_name = long_name,
            .option_type = option_type,
            // Option with default value is set automatically.
            .is_set = attrs.default_value_ptr != null,
        };
        current_index += 1;
    }

    // Parse short names.
    if (@hasDecl(Options, "__shorts__")) {
        const shorts_type = @TypeOf(Options.__shorts__);
        if (@typeInfo(shorts_type) != .@"struct") {
            @compileError(
                "__shorts__ should be defined using struct, found " ++ @typeName(shorts_type),
            );
        }

        const shorts_struct = @typeInfo(shorts_type).@"struct";
        inline for (shorts_struct.field_names) |long_name| {
            inline for (&option_fields) |*option_field| {
                if (std.mem.eql(u8, option_field.long_name, long_name)) {
                    const short_name_literal = @field(Options.__shorts__, long_name);
                    if (@typeInfo(@TypeOf(short_name_literal)) != .enum_literal) {
                        @compileError(
                            "Short option value must be literal enum, found " ++
                                @typeName(@TypeOf(short_name_literal)),
                        );
                    }
                    option_field.short_name = @tagName(short_name_literal)[0];

                    break;
                }
            } else {
                @compileError(
                    "No such option exists for short name mapping, long_name: " ++ long_name,
                );
            }
        }
    }

    // Parse messages.
    if (@hasDecl(Options, "__messages__")) {
        const messages_type = @TypeOf(Options.__messages__);
        if (@typeInfo(messages_type) != .@"struct") {
            @compileError(
                "__messages__ should be defined using struct, found " ++ @typeName(messages_type),
            );
        }

        const messages_struct = @typeInfo(messages_type).@"struct";
        inline for (messages_struct.field_names) |long_name| {
            inline for (&option_fields) |*option_field| {
                if (std.mem.eql(u8, option_field.long_name, long_name)) {
                    option_field.message = @field(Options.__messages__, long_name);
                    break;
                }
            } else {
                @compileError(
                    "No such option exists for message mapping, long_name: " ++ long_name,
                );
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
        .{
            .long_name = "verbose",
            .short_name = 'v',
            .message = "show verbose log",
            .option_type = .RequiredBool,
        },
        .{ .long_name = "help", .option_type = .Bool },
        .{ .long_name = "timeout", .option_type = .RequiredInt },
        .{ .long_name = "user-agent", .option_type = .String },
    }, fields);
}

fn NonOptionType(comptime option_type: type) type {
    return switch (@typeInfo(option_type)) {
        .optional => |optional_info| NonOptionType(optional_info.child),
        else => option_type,
    };
}

const MessageHelper = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    program_name: []const u8,
    argument_prompt: ?[]const u8,
    version_string: ?[]const u8,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        program_name: []const u8,
        version_string: ?[]const u8,
        argument_prompt: ?[]const u8,
    ) MessageHelper {
        return .{
            .allocator = allocator,
            .io = io,
            .program_name = program_name,
            .version_string = version_string,
            .argument_prompt = argument_prompt,
        };
    }

    fn printDefault(
        comptime FieldType: type,
        default_value_ptr: ?*const anyopaque,
        writer: *Writer,
    ) !void {
        if (default_value_ptr == null) {
            if (@typeInfo(FieldType) != .optional) {
                try writer.writeAll("(required)");
            }
            return;
        }

        const default_value = @as(*align(1) const FieldType, @ptrCast(default_value_ptr.?)).*;
        switch (@typeInfo(FieldType)) {
            .bool => if (!default_value) return,
            .optional => |optional_info| if (@typeInfo(optional_info.child) == .bool) {
                if (!(default_value orelse false)) return;
            },
            else => {},
        }

        const format_string = "(default: " ++ switch (FieldType) {
            []const u8 => "{s}",
            ?[]const u8 => "{?s}",
            else => if (@typeInfo(NonOptionType(FieldType)) == .@"enum")
                "{s}"
            else
                "{any}",
        } ++ ")";

        try writer.print(format_string, .{switch (@typeInfo(FieldType)) {
            .@"enum" => @tagName(default_value),
            .optional => |optional_info| if (@typeInfo(optional_info.child) == .@"enum")
                if (default_value) |v| @tagName(v) else "null"
            else
                default_value,
            else => default_value,
        }});
    }

    pub fn printHelp(
        self: MessageHelper,
        comptime Options: type,
        sub_command_name: ?[]const u8,
        writer: *Writer,
    ) !void {
        const option_fields = comptime buildOptionFields(Options);
        const sub_command_messages = if (@hasField(Options, command_field_name_default)) blk: {
            const s = @typeInfo(Options).@"struct";
            inline for (s.field_names, s.field_types) |name, field_type| {
                if (comptime std.mem.eql(u8, name, command_field_name_default)) {
                    const u = @typeInfo(field_type).@"union";
                    break :blk subCommandsHelpMsg(
                        field_type,
                        u.field_names.len,
                    );
                }
            }
        } else null;

        const header_template =
            \\ USAGE:
            \\     {s} [OPTIONS]{s}
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
                    const line = try std.fmt.allocPrint(
                        arena,
                        "  {s:<10} {s}",
                        .{ message_wrapper.name, message_wrapper.message },
                    );
                    try list.append(arena, line);
                } else {
                    const spaces: [command_message_offset]u8 = @splat(' ');
                    const line = try std.fmt.allocPrint(
                        arena,
                        "  {s}\n  {s} {s}",
                        .{ message_wrapper.name, &spaces, message_wrapper.message },
                    );
                    try list.append(arena, line);
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

        const command_usage_suffix = if (command_usage_string.len > 0)
            try std.fmt.allocPrint(arena, " {s}", .{command_usage_string})
        else
            "";

        const header_string = try std.fmt.allocPrint(arena, header_template, .{
            program_usage_string,
            command_usage_suffix,
        });

        try writer.writeAll(header_string);

        const message_offset = 35;
        const message_offset_spaces: [message_offset]u8 = @splat(' ');
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
                try current_option_list.append(arena, &message_offset_spaces);
            } else while (blank_count > 0) {
                try current_option_list.append(arena, " ");
                blank_count -= 1;
            }

            if (option_field.message) |message_text| {
                try current_option_list.append(arena, message_text);
            }
            const first_part_string = try std.mem.join(arena, "", current_option_list.items);
            try writer.writeAll(first_part_string);

            const struct_fields = @typeInfo(Options).@"struct";
            inline for (
                struct_fields.field_names,
                struct_fields.field_types,
                struct_fields.field_attrs,
            ) |name, field_type, attrs| {
                if (std.mem.eql(u8, name, option_field.long_name)) {
                    const real_type = NonOptionType(field_type);
                    if (@typeInfo(real_type) == .@"enum") {
                        const enum_options_string = try std.mem.join(
                            arena,
                            "|",
                            std.meta.fieldNames(real_type),
                        );
                        try writer.writeAll(" (valid: ");
                        try writer.writeAll(enum_options_string);
                        try writer.writeAll(")");
                    }

                    try MessageHelper.printDefault(
                        field_type,
                        attrs.default_value_ptr,
                        writer,
                    );
                }
            }

            try writer.writeAll("\n");
        }

        try writer.flush();
    }

    pub fn printVersion(self: MessageHelper) !void {
        const stdout = std.Io.File.stdout();
        var buffer: [1024]u8 = undefined;
        var writer = stdout.writer(self.io, &buffer);
        const version_string = self.version_string orelse "Unknown";
        try writer.interface.print("{s}\n", .{version_string});
        try writer.interface.flush();
    }
};

fn ParseResult(
    comptime Options: type,
    comptime version_string: ?[]const u8,
    comptime argument_prompt: ?[]const u8,
) type {
    return struct {
        program_name: []const u8,
        // Parsed options (the user-defined struct)
        options: Options,
        positional_arguments: []const [:0]const u8,

        // Unparsed original input arguments
        raw_arguments: []const [:0]const u8,
        allocator: std.mem.Allocator,
        io: std.Io,

        const Self = @This();

        pub fn deinit(self: Self) void {
            if (!is_test) {
                self.allocator.free(self.raw_arguments);
            }
        }

        pub fn printHelp(self: Self, writer: *Writer) !void {
            try MessageHelper.init(
                self.allocator,
                self.io,
                self.program_name,
                version_string,
                argument_prompt,
            ).printHelp(Options, null, writer);
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
        comptime Options: type,
    ) OptionType {
        return Self.convert(Options, false);
    }

    fn convert(comptime Options: type, comptime is_optional: bool) OptionType {
        const base_kind: Self = switch (@typeInfo(Options)) {
            .int => .RequiredInt,
            .bool => .RequiredBool,
            .float => .RequiredFloat,
            .optional => |optional_info| return Self.convert(optional_info.child, true),
            .pointer => |pointer_info|
            // Only support []const u8.
            if (pointer_info.size == .slice and
                pointer_info.child == u8 and
                pointer_info.attrs.@"const")
                .RequiredString
            else {
                @compileError("Not supported option type:" ++ @typeName(Options));
            },
            .@"enum" => .RequiredEnum,
            else => {
                @compileError("Not supported option type:" ++ @typeName(Options));
            },
        };
        const shift_val: u32 = if (is_optional) REQUIRED_VERSION_SHIFT else 0;
        const kind_value = @backingInt(base_kind) + shift_val;
        return @fromBackingInt(@intCast(kind_value));
    }

    fn is_required(self: Self) bool {
        return @backingInt(self) < REQUIRED_VERSION_SHIFT;
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
    const testcases = [_]@Tuple(&.{ type, OptionType }){
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
        try std.testing.expectEqual(
            testcase.@"1",
            comptime OptionType.from_zig_type(testcase.@"0"),
        );
    }
}

const MessageSubCommand = struct {
    name: []const u8,
    message: []const u8,
};

fn subCommandsHelpMsg(comptime Options: type, comptime length: usize) ?[length]MessageSubCommand {
    const union_type_info = @typeInfo(Options);
    if (union_type_info != .@"union") {
        @compileError(
            "Sub commands should be defined using Union(enum), found " ++ @typeName(Options),
        );
    }

    if (@hasDecl(Options, "__messages__")) {
        const messages_type = @TypeOf(Options.__messages__);
        if (comptime @typeInfo(messages_type) != .@"struct") {
            @compileError("__messages__ should be defined using struct");
        }

        const msg_struct = @typeInfo(messages_type).@"struct";
        const union_info = @typeInfo(Options).@"union";

        var message_wrappers: [msg_struct.field_names.len]MessageSubCommand = undefined;

        inline for (msg_struct.field_names, 0..) |msg_name, index| {
            inline for (union_info.field_names) |u_name| {
                if (comptime std.mem.eql(u8, msg_name, u_name)) {
                    message_wrappers[index] = MessageSubCommand{
                        .name = msg_name,
                        .message = @field(Options.__messages__, msg_name),
                    };
                    break;
                }
            } else {
                @compileError("No such sub_cmd exists, name: " ++ msg_name);
            }
        }

        return message_wrappers;
    }

    return null;
}

fn SubCommandsType(comptime Options: type) type {
    const union_type_info = @typeInfo(Options);
    if (union_type_info != .@"union") {
        @compileError(
            "Sub commands should be defined using Union(enum), found " ++ @typeName(Options),
        );
    }

    const union_fields = union_type_info.@"union";
    const len = union_fields.field_names.len;
    var field_names: [len][:0]const u8 = undefined;
    var field_types: [len]type = undefined;
    var field_attrs: [len]std.builtin.Type.Struct.FieldAttributes = undefined;
    inline for (union_fields.field_names, union_fields.field_types, 0..) |u_name, u_type, index| {
        if (comptime @typeInfo(u_type) != .@"struct") {
            @compileError(
                "Sub command should be defined using struct, found " ++
                    @typeName(@typeInfo(u_type)),
            );
        }

        const ParserType = CommandParser(u_type);
        const default_value = ParserType{};
        field_names[index] = u_name;
        field_types[index] = ParserType;
        field_attrs[index] = .{
            .default_value_ptr = @ptrCast(&default_value),
        };
    }
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn CommandParser(comptime Options: type) type {
    return struct {
        option_fields: [getOptionLength(Options)]OptionField = buildOptionFields(Options),
        option_commands: if (@hasField(Options, command_field_name_default)) blk: {
            const s = @typeInfo(Options).@"struct";
            for (s.field_names, s.field_types) |name, field_type| {
                if (std.mem.eql(u8, name, command_field_name_default)) {
                    break :blk SubCommandsType(field_type);
                }
            } else {
                unreachable;
            }
        } else void = if (@hasField(Options, command_field_name_default)) .{} else {},
    };
}

/// `Options` is a struct, which defines options.
fn OptionParser(
    comptime Options: type,
) type {
    return struct {
        allocator: std.mem.Allocator,
        io: std.Io,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return .{
                .allocator = allocator,
                .io = io,
            };
        }

        const ParseState = enum {
            start,
            waitValue,
            arguments,
        };

        fn parseCommand(
            comptime CurrentOptions: type,
            input_arguments: []const [:0]const u8,
            argument_index: *usize,
            help_was_printed: *bool,
            message_helper: MessageHelper,
            sub_command_name: ?[]const u8,
            comptime options: ParseOptions,
        ) !CurrentOptions {
            return parseCommandImpl(
                CurrentOptions,
                input_arguments,
                argument_index,
                help_was_printed,
                message_helper,
                sub_command_name,
                options,
            ) catch |err| {
                if (!help_was_printed.*) {
                    if (!is_test and options.print_help_on_error) {
                        var stderr_buffer: [4096]u8 = undefined;
                        var stderr_writer =
                            std.Io.File.stderr().writer(message_helper.io, &stderr_buffer);
                        message_helper.printHelp(
                            CurrentOptions,
                            sub_command_name,
                            &stderr_writer.interface,
                        ) catch {};
                        help_was_printed.* = true;
                    }
                }
                return err;
            };
        }

        fn parseCommandImpl(
            comptime CurrentOptions: type,
            input_arguments: []const [:0]const u8,
            argument_index: *usize,
            help_was_printed: *bool,
            message_helper: MessageHelper,
            sub_command_name: ?[]const u8,
            comptime options: ParseOptions,
        ) !CurrentOptions {
            // State machine used to parse option flags and positional arguments.
            // The parser transitions between states based on the prefix of each input.
            //
            // Available state transitions:
            // 1. .start -> .arguments:
            //    Encountered "--" or a non-flag string. Marks the end of options and
            //    beginning of positional arguments or subcommands.
            // 2. .start -> .waitValue -> .start:
            //    Encountered an option flag requiring a value (e.g., --timeout 30).
            //    The next input is consumed as the value before returning to search for flags.
            // 3. .start -> .arguments -> subcommand.parseCommand:
            //    When positional arguments start, if the first one matches a subcommand name,
            //    the parser delegates control to that subcommand's logic.
            var options_value: CurrentOptions = undefined;
            var command_parser = CommandParser(CurrentOptions){};
            var sub_command_is_set = false;

            const struct_fields = @typeInfo(CurrentOptions).@"struct";
            inline for (
                struct_fields.field_names,
                struct_fields.field_types,
                struct_fields.field_attrs,
            ) |name, field_type, attrs| {
                if (comptime std.mem.eql(u8, name, command_field_name_default)) {
                    if (attrs.default_value_ptr) |value_ptr| {
                        sub_command_is_set = true;
                        const ptr: *align(1) const field_type = @ptrCast(value_ptr);
                        @field(options_value, name) = ptr.*;
                    }
                    continue;
                }

                if (attrs.default_value_ptr) |value_ptr| {
                    const ptr: *align(1) const field_type = @ptrCast(value_ptr);
                    @field(options_value, name) = ptr.*;
                } else {
                    const option_type_kind = OptionType.from_zig_type(field_type);
                    if (!option_type_kind.is_required()) {
                        if (@typeInfo(field_type) == .optional) {
                            @field(options_value, name) = null;
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
                        if (std.mem.eql(u8, argument, "-")) {
                            state = .arguments;
                            argument_index.* -= 1;
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
                            _ = try setOptionValue(
                                CurrentOptions,
                                &options_value,
                                option.long_name,
                                "true",
                            );
                            option.is_set = true;
                            state = .start;
                            current_option = null;

                            if (!is_test and options.print_help_and_exit) {
                                if (std.mem.eql(u8, option.long_name, "help")) {
                                    var stdout_buffer: [4096]u8 = undefined;
                                    var stdout_file = std.Io.File.stdout();
                                    var stdout_writer =
                                        stdout_file.writer(message_helper.io, &stdout_buffer);
                                    const stdout = &stdout_writer.interface;
                                    message_helper.printHelp(
                                        CurrentOptions,
                                        sub_command_name,
                                        stdout,
                                    ) catch @panic("OOM");
                                    stdout_writer.interface.flush() catch {};
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
                            const sub_parser_fields = @typeInfo(sub_parser_type).@"struct";
                            inline for (sub_parser_fields.field_names) |field_name| {
                                if (std.mem.eql(u8, field_name, argument)) {
                                    const UnionType =
                                        @TypeOf(@field(options_value, command_field_name_default));
                                    const union_fields = @typeInfo(UnionType).@"union";
                                    inline for (
                                        union_fields.field_names,
                                        union_fields.field_types,
                                    ) |union_field_name, union_field_type| {
                                        if (comptime std.mem.eql(
                                            u8,
                                            union_field_name,
                                            field_name,
                                        )) {
                                            const value = try Self.parseCommand(
                                                union_field_type,
                                                input_arguments,
                                                argument_index,
                                                help_was_printed,
                                                message_helper,
                                                field_name,
                                                options,
                                            );
                                            @field(
                                                options_value,
                                                command_field_name_default,
                                            ) = @unionInit(UnionType, field_name, value);
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
                        _ = try setOptionValue(
                            CurrentOptions,
                            &options_value,
                            option.long_name,
                            argument,
                        );
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

            return options_value;
        }

        fn parse(
            self: *Self,
            input_arguments: []const [:0]const u8,
            comptime options: ParseOptions,
        ) OptionError!ParseResult(Options, options.version_string, options.argument_prompt) {
            if (input_arguments.len == 0) {
                return error.NoProgram;
            }

            const arguments_to_parse = input_arguments[1..];
            var argument_index: usize = 0;
            const message_helper = MessageHelper.init(
                self.allocator,
                self.io,
                input_arguments[0],
                options.version_string,
                options.argument_prompt,
            );
            var help_was_printed = false;
            const parsed_options = try Self.parseCommand(
                Options,
                arguments_to_parse,
                &argument_index,
                &help_was_printed,
                message_helper,
                null,
                options,
            );
            var result = ParseResult(Options, options.version_string, options.argument_prompt){
                .program_name = input_arguments[0],
                .allocator = self.allocator,
                .io = self.io,
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
fn setOptionValue(
    comptime Options: type,
    options: *Options,
    long_name: []const u8,
    raw_value: []const u8,
) !bool {
    const s = @typeInfo(Options).@"struct";
    inline for (s.field_names, s.field_types) |name, field_type| {
        if (comptime std.mem.eql(u8, name, command_field_name_default)) {
            continue;
        }

        if (std.mem.eql(u8, name, long_name)) {
            const kind = OptionType.from_zig_type(field_type);
            const BaseType = NonOptionType(field_type);
            switch (kind) {
                .Int, .RequiredInt => {
                    if (comptime @typeInfo(BaseType) == .int) {
                        @field(options, name) = switch (getSignedness(field_type)) {
                            .signed => try std.fmt.parseInt(BaseType, raw_value, 0),
                            .unsigned => try std.fmt.parseUnsigned(BaseType, raw_value, 0),
                        };
                    }
                },
                .Float, .RequiredFloat => {
                    if (comptime @typeInfo(BaseType) == .float) {
                        @field(options, name) = try std.fmt.parseFloat(BaseType, raw_value);
                    }
                },
                .String, .RequiredString => {
                    if (comptime BaseType == []const u8) {
                        @field(options, name) = raw_value;
                    }
                },
                .Bool, .RequiredBool => {
                    if (comptime BaseType == bool) {
                        const is_true = std.mem.eql(u8, raw_value, "true") or
                            std.mem.eql(u8, raw_value, "1");
                        @field(options, name) = is_true;
                    }
                },
                .Enum, .RequiredEnum => {
                    if (comptime @typeInfo(BaseType) == .@"enum") {
                        if (std.meta.stringToEnum(BaseType, raw_value)) |value| {
                            @field(options, name) = value;
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
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "--help", 0),
        try gpa.dupeSentinel(u8, "--rate", 0),
        try gpa.dupeSentinel(u8, "1.2", 0),
        try gpa.dupeSentinel(u8, "--timeout", 0),
        try gpa.dupeSentinel(u8, "30", 0),
        try gpa.dupeSentinel(u8, "--user-agent", 0),
        try gpa.dupeSentinel(u8, "firefox", 0),
        // Positional arguments.
        try gpa.dupeSentinel(u8, "hello", 0),
        try gpa.dupeSentinel(u8, "world", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };

    var parser = OptionParser(TestArguments).init(gpa, io);
    const result = try parser.parse(&input_arguments, .{ .argument_prompt = "..." });
    defer result.deinit();

    try std.testing.expectEqualDeep(TestArguments{
        .help = true,
        .rate = 1.2,
        .timeout = 30,
        .@"user-agent" = "firefox",
    }, result.options);

    const expected_positional = input_arguments[input_arguments.len - 2 ..];
    try std.testing.expectEqualDeep(result.positional_arguments, expected_positional);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try result.printHelp(&aw.writer);
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
    , aw.written());
}

test "parse/bool value" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    {
        var input_arguments = [_][:0]u8{
            try gpa.dupeSentinel(u8, "awesome-cli", 0),
            try gpa.dupeSentinel(u8, "--help", 0),
        };
        defer for (input_arguments) |argument| {
            gpa.free(argument);
        };
        var parser = OptionParser(struct { help: bool }).init(gpa, io);
        const result = try parser.parse(&input_arguments, .{});
        defer result.deinit();

        try std.testing.expect(result.options.help);
        try std.testing.expectEqual(result.positional_arguments.len, 0);
    }
    {
        var input_arguments = [_][:0]u8{
            try gpa.dupeSentinel(u8, "awesome-cli", 0),
            try gpa.dupeSentinel(u8, "--help", 0),
            try gpa.dupeSentinel(u8, "true", 0),
        };
        defer for (input_arguments) |argument| {
            gpa.free(argument);
        };
        var parser = OptionParser(struct { help: bool }).init(gpa, io);
        const result = try parser.parse(&input_arguments, .{});
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
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "abc", 0),
        try gpa.dupeSentinel(u8, "def", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa, io);

    try std.testing.expectError(error.MissingRequiredOption, parser.parse(&input_arguments, .{}));
}

test "parse/invalid u16 values" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "--timeout", 0),
        try gpa.dupeSentinel(u8, "not-a-number", 0),
        try gpa.dupeSentinel(u8, "--help", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa, io);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(&input_arguments, .{}));
}

test "parse/invalid f32 values" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "--rate", 0),
        try gpa.dupeSentinel(u8, "not-a-number", 0),
        try gpa.dupeSentinel(u8, "--help", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa, io);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(&input_arguments, .{}));
}

test "parse/unknown option" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "-h", 0),
        try gpa.dupeSentinel(u8, "--timeout", 0),
        try gpa.dupeSentinel(u8, "1", 0),
        try gpa.dupeSentinel(u8, "--notexists", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa, io);

    try std.testing.expectError(error.NoOption, parser.parse(&input_arguments, .{}));
}

test "parse/missing option value" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "-h", 0),
        try gpa.dupeSentinel(u8, "--timeout", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa, io);

    try std.testing.expectError(error.MissingOptionValue, parser.parse(&input_arguments, .{}));
}

test "parse/default value" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
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

        pub const __messages__ = .{ .d2 = "padding message" };
    }).init(gpa, io);
    const result = try parser.parse(&input_arguments, .{ .argument_prompt = "..." });
    try std.testing.expectEqualStrings("A1", result.options.a1);
    try std.testing.expectEqual(result.positional_arguments.len, 0);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try result.printHelp(&aw.writer);
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
    , aw.written());
}

test "parse/enum option" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "--a3", 0),
        try gpa.dupeSentinel(u8, "Y", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(struct {
        a1: ?enum { A, B } = .A,
        a2: enum { C, D } = .D,
        a3: enum { X, Y },
    }).init(gpa, io);
    const result = try parser.parse(&input_arguments, .{ .argument_prompt = "..." });
    defer result.deinit();

    try std.testing.expectEqual(result.options.a1, .A);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try result.printHelp(&aw.writer);
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\      --a1 STRING                   (valid: A|B)(default: A)
        \\      --a2 STRING                   (valid: C|D)(default: D)
        \\      --a3 STRING                   (valid: X|Y)(required)
        \\
    , aw.written());
}

test "parse/positional arguments" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "--", 0),
        try gpa.dupeSentinel(u8, "-a", 0),
        try gpa.dupeSentinel(u8, "2", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(struct {
        a: u8 = 1,
    }).init(gpa, io);
    const result = try parser.parse(&input_arguments, .{ .argument_prompt = "..." });
    defer result.deinit();

    try std.testing.expectEqualDeep(result.options.a, 1);
    const expected_positional = input_arguments[input_arguments.len - 2 ..];
    try std.testing.expectEqualDeep(result.positional_arguments, expected_positional);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try result.printHelp(&aw.writer);
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\      --a INTEGER                  (default: 1)
        \\
    , aw.written());
}

test "parse/single dash as positional argument" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "-", 0),
        try gpa.dupeSentinel(u8, "file.txt", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(struct {
        a: u8 = 1,
    }).init(gpa, io);
    const result = try parser.parse(&input_arguments, .{});
    defer result.deinit();

    try std.testing.expectEqual(result.options.a, 1);
    try std.testing.expectEqual(result.positional_arguments.len, 2);
    try std.testing.expectEqualStrings("-", result.positional_arguments[0]);
    try std.testing.expectEqualStrings("file.txt", result.positional_arguments[1]);
}

test "parse/print_help_and_exit false" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "--help", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };

    var parser = OptionParser(struct { help: bool }).init(gpa, io);
    const result = try parser.parse(&input_arguments, .{ .print_help_and_exit = false });
    defer result.deinit();

    try std.testing.expect(result.options.help);
    try std.testing.expectEqual(result.positional_arguments.len, 0);
}

test "parse/print_help_on_error" {
    // Verify that parse errors are propagated correctly regardless of print_help_on_error.
    // The actual stderr printing is guarded by !is_test, so only the error return is tested here.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "--help", 0),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };

    // With print_help_on_error: true (default), errors are still propagated.
    {
        var parser = OptionParser(TestArguments).init(gpa, io);
        try std.testing.expectError(
            error.MissingRequiredOption,
            parser.parse(&input_arguments, .{ .print_help_on_error = true }),
        );
    }
    // With print_help_on_error: false, errors are also propagated (no other change in test mode).
    {
        var parser = OptionParser(TestArguments).init(gpa, io);
        try std.testing.expectError(
            error.MissingRequiredOption,
            parser.parse(&input_arguments, .{ .print_help_on_error = false }),
        );
    }
}

test "parse/sub commands" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var input_arguments = [_][:0]u8{
        try gpa.dupeSentinel(u8, "awesome-cli", 0),
        try gpa.dupeSentinel(u8, "--a", 0),
        try gpa.dupeSentinel(u8, "2", 0),
        try gpa.dupeSentinel(u8, "cmd1", 0),
        try gpa.dupeSentinel(u8, "--aa", 0),
        try gpa.dupeSentinel(u8, "22", 0),
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
    }).init(gpa, io);
    const result = try parser.parse(&input_arguments, .{});
    defer result.deinit();

    try std.testing.expectEqualDeep(result.options.a, 2);
    try std.testing.expectEqual(result.positional_arguments.len, 0);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try result.printHelp(&aw.writer);
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
    , aw.written());
}

test "print help uses sub command context" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const CommandOptions = struct {
        aa: u8,
    };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try MessageHelper.init(
        gpa,
        io,
        "awesome-cli",
        null,
        null,
    ).printHelp(CommandOptions, "cmd1", &aw.writer);

    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli cmd1 [OPTIONS]
        \\
        \\ OPTIONS:
        \\      --aa INTEGER                 (required)
        \\
    , aw.written());
}
