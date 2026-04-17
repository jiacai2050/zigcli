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

pub const CompletionItem = struct {
    value: []const u8,
    description: ?[]const u8 = null,
};

pub const Shell = enum {
    bash,
    fish,
    zsh,
    auto,
};

pub const CompletionContext = struct {
    allocator: std.mem.Allocator,
    shell: Shell,
    context: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!usize,

    pub fn init(allocator: std.mem.Allocator, shell: Shell, writer_ptr: anytype) CompletionContext {
        const Ptr = @TypeOf(writer_ptr);
        const Gen = struct {
            fn write(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
                const self: Ptr = @ptrCast(@alignCast(ctx));
                const RealT = if (@typeInfo(Ptr) == .pointer) @typeInfo(Ptr).pointer.child else Ptr;
                if (comptime @hasField(RealT, "interface")) {
                    return self.interface.write(bytes);
                } else {
                    return self.write(bytes);
                }
            }
        };
        return .{
            .allocator = allocator,
            .shell = shell,
            .context = writer_ptr,
            .write_fn = Gen.write,
        };
    }

    fn writeAll(self: CompletionContext, bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const n = try self.write_fn(self.context, bytes[index..]);
            if (n == 0) return error.DiskQuota;
            index += n;
        }
    }

    pub fn add(self: CompletionContext, value: []const u8, description: ?[]const u8) !void {
        try self.addItem(.{ .value = value, .description = description });
    }

    pub fn addItem(self: CompletionContext, item: CompletionItem) !void {
        switch (self.shell) {
            .zsh => {
                try self.writeAll(item.value);
                if (item.description) |desc| {
                    try self.writeAll(":");
                    try self.writeAll(desc);
                }
                try self.writeAll("\n");
            },
            .fish => {
                try self.writeAll(item.value);
                if (item.description) |desc| {
                    try self.writeAll("\t");
                    try self.writeAll(desc);
                }
                try self.writeAll("\n");
            },
            .bash => {
                try self.writeAll(item.value);
                try self.writeAll("\n");
            },
            .auto => unreachable,
        }
    }
};

fn runCompleter(
    allocator: std.mem.Allocator,
    shell: Shell,
    writer: anytype,
    completer: anytype,
) !void {
    const ctx = CompletionContext.init(allocator, shell, writer);
    const T = @TypeOf(completer);

    switch (@typeInfo(T)) {
        .@"fn" => |f| {
            if (f.params.len == 0) {
                const result = completer();
                try writeCompleterResult(ctx, result);
            } else if (f.params.len == 1) {
                const Param0 = f.params[0].type.?;
                if (Param0 == std.mem.Allocator) {
                    const result = try completer(allocator);
                    defer allocator.free(result);
                    try writeCompleterResult(ctx, result);
                } else if (Param0 == CompletionContext) {
                    try completer(ctx);
                } else {
                    @compileError("Unsupported completer parameter type: " ++ @typeName(Param0));
                }
            } else {
                @compileError("Unsupported completer function signature: " ++ @typeName(T));
            }
        },
        .pointer => |p| {
            switch (p.size) {
                .slice, .one => {
                    if (p.size == .one and @typeInfo(p.child) != .array) {
                        @compileError("Unsupported completer type: " ++ @typeName(T));
                    }
                    try writeCompleterResult(ctx, completer);
                },
                else => @compileError("Unsupported completer type: " ++ @typeName(T)),
            }
        },
        .array => {
            try writeCompleterResult(ctx, completer);
        },
        else => @compileError("Unsupported completer type: " ++ @typeName(T)),
    }
}

fn writeCompleterResult(ctx: CompletionContext, result: anytype) !void {
    const T = @TypeOf(result);
    const info = @typeInfo(T);

    if (info == .error_union) {
        return writeCompleterResult(ctx, try result);
    }

    const ResultT = @TypeOf(if (info == .error_union) try result else result);
    const res_info = @typeInfo(ResultT);

    if (res_info == .pointer or res_info == .array) {
        const Base = if (res_info == .pointer) res_info.pointer.child else res_info.array.child;
        const base_info = @typeInfo(Base);
        const Elem = if (base_info == .array) base_info.array.child else Base;
        if (Elem == []const u8 or Elem == [:0]const u8 or Elem == []u8) {
            for (result) |val| {
                try ctx.addItem(.{ .value = val });
            }
        } else if (Elem == CompletionItem) {
            for (result) |item| {
                try ctx.addItem(item);
            }
        } else {
            @compileError("Unsupported completer result element type: " ++ @typeName(Elem));
        }
    } else {
        @compileError("Unsupported completer result type: " ++ @typeName(ResultT));
    }
}

const DYNAMIC_COMPLETION_FLAG = "--complete-dynamic-run";

const OptionError = ParseError ||
    std.mem.Allocator.Error ||
    std.fmt.ParseIntError ||
    std.fmt.ParseFloatError ||
    std.process.ArgIterator.InitError;

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
/// - `Options` is the configuration of the arguments.
/// - `options` contains metadata like argument prompt and version string.
pub fn parse(
    allocator: std.mem.Allocator,
    comptime Options: type,
    comptime options: ParseOptions,
) OptionError!ParseResult(Options, options.version_string, options.argument_prompt) {
    const raw_arguments = try std.process.argsAlloc(allocator);
    errdefer std.process.argsFree(allocator, raw_arguments);

    var parser = OptionParser(Options).init(allocator);
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
        @compileError("Option configuration should be defined using struct, found " ++ @typeName(Options));
    }

    const fields = std.meta.fields(Options);
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, command_field_name_default)) {
            return fields.len - 1;
        }
    }

    return fields.len;
}

fn buildOptionFields(comptime Options: type) [getOptionLength(Options)]OptionField {
    const type_info = @typeInfo(Options);
    if (type_info != .@"struct") {
        @compileError("Option configuration should be defined using struct, found " ++ @typeName(Options));
    }

    var option_fields: [getOptionLength(Options)]OptionField = undefined;
    const fields = std.meta.fields(Options);
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
    if (@hasDecl(Options, "__shorts__")) {
        const shorts_type = @TypeOf(Options.__shorts__);
        if (@typeInfo(shorts_type) != .@"struct") {
            @compileError("__shorts__ should be defined using struct, found " ++ @typeName(shorts_type));
        }

        const shorts_fields = std.meta.fields(shorts_type);
        inline for (shorts_fields) |field| {
            const long_name = field.name;
            inline for (&option_fields) |*option_field| {
                if (std.mem.eql(u8, option_field.long_name, long_name)) {
                    const short_name_literal = @field(Options.__shorts__, long_name);
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
    if (@hasDecl(Options, "__messages__")) {
        const messages_type = @TypeOf(Options.__messages__);
        if (@typeInfo(messages_type) != .@"struct") {
            @compileError("__messages__ should be defined using struct, found " ++ @typeName(messages_type));
        }

        const messages_fields = std.meta.fields(messages_type);
        inline for (messages_fields) |field| {
            const long_name = field.name;
            inline for (&option_fields) |*option_field| {
                if (std.mem.eql(u8, option_field.long_name, long_name)) {
                    option_field.message = @field(Options.__messages__, long_name);
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

fn NonOptionType(comptime option_type: type) type {
    return switch (@typeInfo(option_type)) {
        .optional => |optional_info| NonOptionType(optional_info.child),
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

    fn printDefault(comptime field: std.builtin.Type.StructField, writer: *Writer) !void {
        if (field.default_value_ptr == null) {
            if (@typeInfo(field.type) != .optional) {
                try writer.writeAll("(required)");
            }
            return;
        }

        const default_value = @as(*align(1) const field.type, @ptrCast(field.default_value_ptr.?)).*;
        switch (@typeInfo(field.type)) {
            .bool => if (!default_value) return,
            .optional => |optional_info| {
                if (@typeInfo(optional_info.child) == .bool) {
                    if (!(default_value orelse false)) return;
                } else if (@typeInfo(optional_info.child) == .@"enum") {
                    if (default_value == null) return;
                } else {
                    if (default_value == null) return;
                }
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
        comptime Options: type,
        sub_command_name: ?[]const u8,
        writer: *Writer,
    ) !void {
        const option_fields = comptime buildOptionFields(Options);
        const sub_command_messages = if (@hasField(Options, command_field_name_default)) blk: {
            const fields = std.meta.fields(Options);
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

            const struct_fields = std.meta.fields(Options);
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

fn ParseResult(
    comptime Options: type,
    comptime version_string: ?[]const u8,
    comptime argument_prompt: ?[]const u8,
) type {
    return struct {
        program_name: []const u8,
        // Parsed options (the user-defined struct)
        options: Options,
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

        pub fn printHelp(self: Self, writer: *Writer) !void {
            try MessageHelper.init(
                self.allocator,
                self.program_name,
                version_string,
                argument_prompt,
            ).printHelp(Options, null, writer);
        }

        pub fn printCompletion(self: Self, shell: Shell, writer: *Writer) !void {
            var target_shell = shell;
            if (target_shell == .auto) {
                target_shell = try detectShell(self.allocator);
            }

            const base_name = std.fs.path.basename(self.program_name);
            try writeCompletionScript(Options, target_shell, base_name, self.program_name, writer);
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
            if (pointer_info.size == .slice and pointer_info.child == u8 and pointer_info.is_const)
                .RequiredString
            else {
                @compileError("Not supported option type:" ++ @typeName(Options));
            },
            .@"enum" => .RequiredEnum,
            else => {
                @compileError("Not supported option type:" ++ @typeName(Options));
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

fn subCommandsHelpMsg(comptime Options: type, comptime length: usize) ?[length]MessageSubCommand {
    const union_type_info = @typeInfo(Options);
    if (union_type_info != .@"union") {
        @compileError("Sub commands should be defined using Union(enum), found " ++ @typeName(Options));
    }

    if (@hasDecl(Options, "__messages__")) {
        const messages_type = @TypeOf(Options.__messages__);
        if (comptime @typeInfo(messages_type) != .@"struct") {
            @compileError("__messages__ should be defined using struct");
        }

        var message_wrappers: [std.meta.fields(messages_type).len]MessageSubCommand = undefined;
        const messages_fields = std.meta.fields(messages_type);
        const union_fields = std.meta.fields(Options);

        inline for (messages_fields, 0..) |message_field, index| {
            inline for (union_fields) |union_field| {
                if (comptime std.mem.eql(u8, message_field.name, union_field.name)) {
                    message_wrappers[index] = MessageSubCommand{
                        .name = message_field.name,
                        .message = @field(Options.__messages__, message_field.name),
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

fn SubCommandsType(comptime Options: type) type {
    const union_type_info = @typeInfo(Options);
    if (union_type_info != .@"union") {
        @compileError("Sub commands should be defined using Union(enum), found " ++ @typeName(Options));
    }

    const union_fields = std.meta.fields(Options);
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

fn validateCompleters(comptime T: type) void {
    if (@hasDecl(T, "__completers__")) {
        const completers = T.__completers__;
        const CompletersT = @TypeOf(completers);
        if (@typeInfo(CompletersT) != .@"struct") {
            @compileError("__completers__ should be defined using struct");
        }
        inline for (std.meta.fields(CompletersT)) |fld| {
            if (!@hasField(T, fld.name)) {
                @compileError("no such option exists in __completers__, name: " ++ fld.name);
            }
        }
    }
}

fn CommandParser(comptime Options: type) type {
    comptime validateCompleters(Options);
    return struct {
        option_fields: [getOptionLength(Options)]OptionField = buildOptionFields(Options),
        option_commands: if (@hasField(Options, command_field_name_default)) blk: {
            const fields = std.meta.fields(Options);
            for (fields) |field| {
                if (std.mem.eql(u8, field.name, command_field_name_default)) {
                    break :blk SubCommandsType(field.type);
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
            comptime CurrentOptions: type,
            input_arguments: [][:0]u8,
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
                        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
                        message_helper.printHelp(
                            CurrentOptions,
                            sub_command_name,
                            &stderr_writer.interface,
                        ) catch {};
                        stderr_writer.interface.flush() catch {};
                        help_was_printed.* = true;
                    }
                }
                return err;
            };
        }

        fn parseCommandImpl(
            comptime CurrentOptions: type,
            input_arguments: [][:0]u8,
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

            const struct_fields = std.meta.fields(CurrentOptions);
            inline for (struct_fields) |field| {
                if (comptime std.mem.eql(u8, field.name, command_field_name_default)) {
                    if (field.default_value_ptr) |value_ptr| {
                        sub_command_is_set = true;
                        @field(options_value, field.name) = @as(*align(1) const field.type, @ptrCast(value_ptr)).*;
                    }
                    continue;
                }

                if (field.default_value_ptr) |value_ptr| {
                    @field(options_value, field.name) = @as(*align(1) const field.type, @ptrCast(value_ptr)).*;
                } else {
                    const option_type_kind = OptionType.from_zig_type(field.type);
                    if (!option_type_kind.is_required()) {
                        if (@typeInfo(field.type) == .optional) {
                            @field(options_value, field.name) = null;
                        }
                    }
                }
            }

            var state = ParseState.start;

            if (argument_index.* < input_arguments.len and std.mem.eql(u8, input_arguments[argument_index.*], DYNAMIC_COMPLETION_FLAG)) {
                argument_index.* += 1;
                if (argument_index.* >= input_arguments.len) {
                    return error.MissingOptionValue;
                }
                const opt_name = input_arguments[argument_index.*];
                argument_index.* += 1;

                var shell: Shell = .fish;
                if (argument_index.* < input_arguments.len) {
                    const possible_shell = input_arguments[argument_index.*];
                    if (std.meta.stringToEnum(Shell, possible_shell)) |s| {
                        shell = s;
                        argument_index.* += 1;
                    }
                }

                if (@hasDecl(CurrentOptions, "__completers__")) {
                    const completers = CurrentOptions.__completers__;
                    inline for (std.meta.fields(@TypeOf(completers))) |fld| {
                        if (std.mem.eql(u8, fld.name, opt_name)) {
                            const completer = @field(completers, fld.name);
                            const stdout = std.fs.File.stdout();
                            var buf: [4096]u8 = undefined;
                            var stdout_writer = stdout.writer(&buf);

                            runCompleter(message_helper.allocator, shell, &stdout_writer, completer) catch {};
                            stdout_writer.interface.flush() catch {};
                            std.process.exit(0);
                        }
                    }
                }
                std.process.exit(0);
            }

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

                        if (std.mem.eql(u8, option.long_name, "completion")) {
                            if (!is_test) {
                                var requested_shell: Shell = .auto;
                                if (argument_index.* < input_arguments.len) {
                                    const next_arg = input_arguments[argument_index.*];
                                    if (std.meta.stringToEnum(Shell, next_arg)) |s| {
                                        requested_shell = s;
                                        argument_index.* += 1;
                                    }
                                }

                                const detected_shell = if (requested_shell == .auto)
                                    detectShell(message_helper.allocator) catch .bash
                                else
                                    requested_shell;

                                const stdout = std.fs.File.stdout();
                                var buf: [4096]u8 = undefined;
                                var stdout_writer = stdout.writer(&buf);
                                const base_name = std.fs.path.basename(message_helper.program_name);
                                writeCompletionScript(CurrentOptions, detected_shell, base_name, message_helper.program_name, &stdout_writer.interface) catch {};
                                stdout_writer.interface.flush() catch {};
                                std.process.exit(0);
                            }
                        }

                        if (option.option_type == .Bool or option.option_type == .RequiredBool) {
                            _ = try setOptionValue(CurrentOptions, &options_value, option.long_name, "true");
                            option.is_set = true;
                            state = .start;
                            current_option = null;

                            if (!is_test and options.print_help_and_exit) {
                                if (std.mem.eql(u8, option.long_name, "help")) {
                                    var stdout_buffer: [4096]u8 = undefined;
                                    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
                                    const stdout = &stdout_writer.interface;
                                    message_helper.printHelp(CurrentOptions, sub_command_name, stdout) catch @panic("OOM");
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
                            const sub_parser_fields = std.meta.fields(sub_parser_type);
                            inline for (sub_parser_fields) |field| {
                                if (std.mem.eql(u8, field.name, argument)) {
                                    const UnionType = @TypeOf(@field(options_value, command_field_name_default));
                                    const union_fields = std.meta.fields(UnionType);
                                    inline for (union_fields) |union_field| {
                                        if (comptime std.mem.eql(u8, union_field.name, field.name)) {
                                            const value = try Self.parseCommand(
                                                union_field.type,
                                                input_arguments,
                                                argument_index,
                                                help_was_printed,
                                                message_helper,
                                                field.name,
                                                options,
                                            );
                                            @field(options_value, command_field_name_default) = @unionInit(UnionType, field.name, value);
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
                        _ = try setOptionValue(CurrentOptions, &options_value, option.long_name, argument);
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
            input_arguments: [][:0]u8,
            comptime options: ParseOptions,
        ) OptionError!ParseResult(Options, options.version_string, options.argument_prompt) {
            if (input_arguments.len == 0) {
                return error.NoProgram;
            }

            const arguments_to_parse = input_arguments[1..];
            var argument_index: usize = 0;
            const message_helper = MessageHelper.init(
                self.allocator,
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
fn setOptionValue(comptime Options: type, options: *Options, long_name: []const u8, raw_value: []const u8) !bool {
    const fields = std.meta.fields(Options);
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
    {
        var input_arguments = [_][:0]u8{
            try gpa.dupeZ(u8, "awesome-cli"),
            try gpa.dupeZ(u8, "--help"),
        };
        defer for (input_arguments) |argument| {
            gpa.free(argument);
        };
        var parser = OptionParser(struct { help: bool }).init(gpa);
        const result = try parser.parse(&input_arguments, .{});
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
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "abc"),
        try gpa.dupeZ(u8, "def"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };
    var parser = OptionParser(TestArguments).init(gpa);

    try std.testing.expectError(error.MissingRequiredOption, parser.parse(&input_arguments, .{}));
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

    try std.testing.expectError(error.InvalidCharacter, parser.parse(&input_arguments, .{}));
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

    try std.testing.expectError(error.InvalidCharacter, parser.parse(&input_arguments, .{}));
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

    try std.testing.expectError(error.NoOption, parser.parse(&input_arguments, .{}));
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

    try std.testing.expectError(error.MissingOptionValue, parser.parse(&input_arguments, .{}));
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

test "parse/print_help_and_exit false" {
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--help"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };

    var parser = OptionParser(struct { help: bool }).init(gpa);
    const result = try parser.parse(&input_arguments, .{ .print_help_and_exit = false });
    defer result.deinit();

    try std.testing.expect(result.options.help);
    try std.testing.expectEqual(result.positional_arguments.len, 0);
}

test "parse/print_help_on_error" {
    // Verify that parse errors are propagated correctly regardless of print_help_on_error.
    // The actual stderr printing is guarded by !is_test, so only the error return is tested here.
    const gpa = std.testing.allocator;
    var input_arguments = [_][:0]u8{
        try gpa.dupeZ(u8, "awesome-cli"),
        try gpa.dupeZ(u8, "--help"),
    };
    defer for (input_arguments) |argument| {
        gpa.free(argument);
    };

    // With print_help_on_error: true (default), errors are still propagated.
    {
        var parser = OptionParser(TestArguments).init(gpa);
        try std.testing.expectError(
            error.MissingRequiredOption,
            parser.parse(&input_arguments, .{ .print_help_on_error = true }),
        );
    }
    // With print_help_on_error: false, errors are also propagated (no other change in test mode).
    {
        var parser = OptionParser(TestArguments).init(gpa);
        try std.testing.expectError(
            error.MissingRequiredOption,
            parser.parse(&input_arguments, .{ .print_help_on_error = false }),
        );
    }
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
    const CommandOptions = struct {
        aa: u8,
    };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try MessageHelper.init(
        gpa,
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

const ZSH_COMPLETION_HEADER =
    \\zstyle ':completion:*:*:*:*:descriptions' format '%F{green}-- %d --%f'
    \\zstyle ':completion:*' group-name ''
    \\
;

const BASH_COMPLETION_PREFIX =
    \\    local cur prev opts
    \\    COMPREPLY=()
    \\    cur="${COMP_WORDS[COMP_CWORD]}"
    \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\    opts="
;

const BASH_COMPLETION_SUFFIX =
    \\    if [[ ${cur} == -* ]] ; then
    \\        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
    \\        return 0
    \\    fi
    \\
    \\    COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
    \\}
    \\
;

fn writeBashCompletion(comptime Typ: type, base_name: []const u8, full_cmd: []const u8, writer: anytype) !void {
    var safe_buf: [256]u8 = undefined;
    const safe = safeBashName(&safe_buf, base_name);

    try writer.print("_{s}_completion() {{\n", .{safe});
    try writer.writeAll(BASH_COMPLETION_PREFIX);
    try writeBashOptions(Typ, writer);
    try writer.writeAll("\"\n\n");

    try writeBashDynamicCompleters(Typ, writer);

    try writer.writeAll(BASH_COMPLETION_SUFFIX);
    try writer.print("complete -F _{s}_completion \"{s}\" \"{s}\"\n", .{ safe, base_name, full_cmd });
}

fn safeBashName(buf: []u8, name: []const u8) []const u8 {
    var j: usize = 0;
    for (name) |c| {
        if (j >= buf.len) break;
        buf[j] = if (c == '-') '_' else c;
        j += 1;
    }
    return buf[0..j];
}

fn writeBashDynamicCompleters(comptime Typ: type, writer: anytype) !void {
    const fields = comptime buildOptionFields(Typ);
    inline for (fields) |f| {
        if (comptime @hasDecl(Typ, "__completers__")) {
            if (comptime @hasField(@TypeOf(Typ.__completers__), f.long_name)) {
                try writer.print("    if [[ ${{prev}} == --{s}", .{f.long_name});
                if (f.short_name) |s| {
                    try writer.print(" || ${{prev}} == -{c}", .{s});
                }
                try writer.writeAll(" ]]; then\n");
                try writer.print("        COMPREPLY=( $( $1 {s} {s} bash ) )\n", .{ DYNAMIC_COMPLETION_FLAG, f.long_name });
                try writer.writeAll("        return 0\n");
                try writer.writeAll("    fi\n");
            }
        }
    }

    if (comptime @hasField(Typ, command_field_name_default)) {
        inline for (std.meta.fields(Typ)) |fld| {
            if (comptime std.mem.eql(u8, fld.name, command_field_name_default)) {
                inline for (std.meta.fields(fld.type)) |cmd_fld| {
                    try writeBashDynamicCompleters(cmd_fld.type, writer);
                }
            }
        }
    }
}

fn detectShell(allocator: std.mem.Allocator) !Shell {
    const builtin_os = @import("builtin").os.tag;

    if (builtin_os == .linux) {
        var current_ppid = std.os.linux.getppid();
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            var path_buf: [64]u8 = undefined;
            const comm_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{current_ppid});
            if (std.fs.openFileAbsolute(comm_path, .{})) |file| {
                defer file.close();
                var name_buf: [256]u8 = undefined;
                const len = try file.readAll(&name_buf);
                const name = std.mem.trim(u8, name_buf[0..len], " \n\r\t");

                if (std.mem.indexOf(u8, name, "zsh") != null) return .zsh;
                if (std.mem.indexOf(u8, name, "fish") != null) return .fish;
                if (std.mem.indexOf(u8, name, "bash") != null) return .bash;

                const is_parent_cmd = std.mem.eql(u8, name, "zig") or
                    std.mem.eql(u8, name, "make") or
                    std.mem.eql(u8, name, "sudo");

                if (is_parent_cmd) {
                    const status_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{current_ppid});
                    if (std.fs.openFileAbsolute(status_path, .{}) catch null) |sfile| {
                        defer sfile.close();
                        var sbuf: [4096]u8 = undefined;
                        const slen = sfile.readAll(&sbuf) catch 0;
                        if (std.mem.indexOf(u8, sbuf[0..slen], "PPid:")) |idx| {
                            const line = sbuf[idx..];
                            const end = std.mem.indexOf(u8, line, "\n") orelse line.len;
                            const ppid_str = std.mem.trim(u8, line[5..end], " \t\r");
                            current_ppid = std.fmt.parseInt(i32, ppid_str, 10) catch break;
                            continue;
                        }
                    }
                }
            } else |_| {}
            break;
        }
    }

    if (std.process.getEnvVarOwned(allocator, "SHELL")) |shell_path| {
        defer allocator.free(shell_path);
        const basename = std.fs.path.basename(shell_path);
        if (std.mem.indexOf(u8, basename, "zsh") != null) return .zsh;
        if (std.mem.indexOf(u8, basename, "fish") != null) return .fish;
        if (std.mem.indexOf(u8, basename, "bash") != null) return .bash;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "ZSH_NAME")) |val| {
        allocator.free(val);
        return .zsh;
    } else |_| {}

    return .bash;
}

fn writeCompletionScript(comptime T: type, shell: Shell, base_name: []const u8, full_cmd: []const u8, writer: anytype) !void {
    switch (shell) {
        .zsh => {
            try writer.print("#compdef \"{s}\" \"{s}\"\n\n", .{ base_name, full_cmd });
            try writer.writeAll(ZSH_COMPLETION_HEADER);
            try writeZshCompletion(T, base_name, base_name, writer);
            try writer.print("\ncompdef _{s} \"{s}\" \"{s}\"\n", .{ base_name, base_name, full_cmd });
        },
        .bash => {
            try writeBashCompletion(T, base_name, full_cmd, writer);
        },
        .fish => {
            try writeFishCompletion(T, base_name, full_cmd, null, writer);
            if (!std.mem.eql(u8, base_name, full_cmd)) {
                try writeFishCompletion(T, full_cmd, full_cmd, null, writer);
            }
        },
        .auto => unreachable,
    }
}

fn writeBashOptions(comptime Typ: type, writer: anytype) !void {
    const fields = comptime buildOptionFields(Typ);
    inline for (fields) |f| {
        try writer.print("--{s} ", .{f.long_name});
        if (f.short_name) |s| {
            try writer.print("-{c} ", .{s});
        }
    }
    if (comptime @hasField(Typ, command_field_name_default)) {
        inline for (std.meta.fields(Typ)) |fld| {
            if (comptime std.mem.eql(u8, fld.name, command_field_name_default)) {
                inline for (std.meta.fields(fld.type)) |cmd_fld| {
                    try writer.print("{s} ", .{cmd_fld.name});
                    try writeBashOptions(cmd_fld.type, writer);
                }
            }
        }
    }
}

fn escapeFishSingleQuote(buf: []u8, target: []const u8) []const u8 {
    var j: usize = 0;
    for (target) |c| {
        if (j + 4 > buf.len) break;
        if (c == '\'') {
            buf[j] = '\'';
            buf[j + 1] = '\\';
            buf[j + 2] = '\'';
            buf[j + 3] = '\'';
            j += 4;
        } else {
            buf[j] = c;
            j += 1;
        }
    }
    return buf[0..j];
}

fn writeFishCompletion(comptime Typ: type, target: []const u8, bin_to_run: []const u8, parent_cmd: ?[]const u8, writer: anytype) !void {
    const fields = comptime buildOptionFields(Typ);

    inline for (fields) |f| {
        const is_special = std.mem.eql(u8, f.long_name, "help") or
            std.mem.eql(u8, f.long_name, "version") or
            std.mem.eql(u8, f.long_name, "completion");

        var target_buf: [512]u8 = undefined;
        const escaped_target = escapeFishSingleQuote(&target_buf, target);

        try writer.print("complete -c '{s}'", .{escaped_target});
        if (parent_cmd == null) {
            try writer.writeAll(" -f");
        }
        if (parent_cmd) |pc| {
            try writer.print(" -n \"__fish_seen_subcommand_from {s}\"", .{pc});
        } else {
            try writer.writeAll(" -n \"__fish_use_subcommand\"");
        }

        if (f.short_name) |s| {
            try writer.print(" -s {c}", .{s});
        }
        try writer.print(" -l {s}", .{f.long_name});

        if (f.message) |m| {
            try writer.writeAll(" -d '");
            for (m) |c| {
                if (c == '\'') {
                    try writer.writeAll("\\'");
                } else {
                    try writer.writeByte(c);
                }
            }
            try writer.writeAll("'");
        }

        var has_completer = false;
        if (comptime @hasDecl(Typ, "__completers__")) {
            if (comptime @hasField(@TypeOf(Typ.__completers__), f.long_name)) {
                has_completer = true;
                try writer.writeAll(" -x");
                try writer.print(" -a '(\"{s}\" {s} {s} fish)'", .{ bin_to_run, DYNAMIC_COMPLETION_FLAG, f.long_name });
            }
        }

        switch (f.option_type) {
            .Bool, .RequiredBool => {},
            else => try writer.writeAll(" -r"),
        }

        switch (f.option_type) {
            .String, .RequiredString => {},
            .Enum, .RequiredEnum => {
                try writer.writeAll(" -f");
                inline for (std.meta.fields(Typ)) |tf| {
                    if (std.mem.eql(u8, tf.name, f.long_name)) {
                        const RealT = NonOptionType(tf.type);
                        if (@typeInfo(RealT) == .@"enum") {
                            try writer.writeAll(" -a \"");
                            inline for (std.meta.fields(RealT)) |ef| {
                                try writer.print("{s} ", .{ef.name});
                            }
                            try writer.writeAll("\"");
                        }
                    }
                }
            },
            else => if (!has_completer) try writer.writeAll(" -f"),
        }

        try writer.writeAll("\n");

        if (!is_special) {
            try writer.print("complete -c '{s}' -f", .{escaped_target});
            if (parent_cmd) |pc| {
                try writer.print(" -n \"__fish_seen_subcommand_from {s}\"", .{pc});
            } else {
                try writer.writeAll(" -n \"__fish_use_subcommand\"");
            }
            try writer.print(" -a --{s}", .{f.long_name});
            if (f.message) |m| {
                try writer.writeAll(" -d '");
                for (m) |c| {
                    if (c == '\'') try writer.writeAll("\\'") else try writer.writeByte(c);
                }
                try writer.writeAll("'");
            }
            try writer.writeAll("\n");
        }
    }
    if (comptime @hasField(Typ, command_field_name_default)) {
        inline for (std.meta.fields(Typ)) |fld| {
            if (comptime std.mem.eql(u8, fld.name, command_field_name_default)) {
                inline for (std.meta.fields(fld.type)) |cmd_fld| {
                    var target_buf2: [512]u8 = undefined;
                    const escaped_target2 = escapeFishSingleQuote(&target_buf2, target);

                    try writer.print("complete -c '{s}' -f", .{escaped_target2});
                    if (parent_cmd) |pc| {
                        try writer.print(" -n \"__fish_seen_subcommand_from {s}\"", .{pc});
                    } else {
                        try writer.writeAll(" -n \"__fish_use_subcommand\"");
                    }
                    try writer.print(" -a {s}", .{cmd_fld.name});
                    if (comptime @hasDecl(fld.type, "__messages__")) {
                        if (comptime @hasField(@TypeOf(fld.type.__messages__), cmd_fld.name)) {
                            const m = @field(fld.type.__messages__, cmd_fld.name);
                            try writer.writeAll(" -d '");
                            for (m) |c| {
                                if (c == '\'') {
                                    try writer.writeAll("\\'");
                                } else {
                                    try writer.writeByte(c);
                                }
                            }
                            try writer.writeAll("'");
                        }
                    }
                    try writer.writeAll("\n");
                    try writeFishCompletion(cmd_fld.type, target, bin_to_run, cmd_fld.name, writer);
                }
            }
        }
    }
}

fn writeZshEscaped(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '\'' => try writer.writeAll("'\\''"),
            ':' => try writer.writeAll("\\:"),
            '[' => try writer.writeAll("\\["),
            ']' => try writer.writeAll("\\]"),
            '"' => try writer.writeAll("\\\""),
            else => try writer.writeByte(c),
        }
    }
}

fn writeZshCompletion(comptime Typ: type, base_name: []const u8, cmd_path: []const u8, writer: anytype) !void {
    try writer.print("function _{s} {{\n", .{cmd_path});
    try writer.writeAll("  local context state state_descr line\n  typeset -A opt_args\n\n");

    if (comptime @hasField(Typ, command_field_name_default)) {
        try writer.writeAll("  local -a commands\n  commands=(\n");
        inline for (std.meta.fields(Typ)) |fld| {
            if (comptime std.mem.eql(u8, fld.name, command_field_name_default)) {
                inline for (std.meta.fields(fld.type)) |cmd_fld| {
                    var desc: []const u8 = "";
                    if (comptime @hasDecl(fld.type, "__messages__")) {
                        if (comptime @hasField(@TypeOf(fld.type.__messages__), cmd_fld.name)) {
                            desc = @field(fld.type.__messages__, cmd_fld.name);
                        }
                    }
                    try writer.print("    '{s}:", .{cmd_fld.name});
                    try writeZshEscaped(writer, desc);
                    try writer.writeAll("'\n");
                }
            }
        }
        try writer.writeAll("  )\n\n");
    }

    try writer.writeAll("  _arguments -C");

    const fields = comptime buildOptionFields(Typ);
    inline for (fields) |f| {
        const has_short = f.short_name != null;
        const iterations: usize = if (has_short) 2 else 1;
        var i: usize = 0;

        while (i < iterations) : (i += 1) {
            try writer.writeAll(" \\\n    '");

            if (has_short) {
                if (i == 0) {
                    try writer.print("(--{s})-{c}", .{ f.long_name, f.short_name.? });
                } else {
                    try writer.print("(-{c})--{s}", .{ f.short_name.?, f.long_name });
                }
            } else {
                try writer.print("--{s}", .{f.long_name});
            }

            try writer.writeAll("[");
            const desc = if (f.message) |m| m else f.long_name;
            try writeZshEscaped(writer, desc);
            try writer.writeAll("]");

            var action_written = false;
            if (comptime @hasDecl(Typ, "__completers__")) {
                if (comptime @hasField(@TypeOf(Typ.__completers__), f.long_name)) {
                    try writer.writeAll(":");
                    try writeZshEscaped(writer, desc);
                    try writer.print(":{{ local -a candidates; candidates=( ${{(f)\"$(command ${{words[1]}} {s} {s} zsh)\"}} ); _describe '\\''", .{ DYNAMIC_COMPLETION_FLAG, f.long_name });
                    try writeZshEscaped(writer, desc);
                    try writer.writeAll("'\\'' candidates }");
                    action_written = true;
                }
            }

            if (!action_written) {
                switch (f.option_type) {
                    .String, .RequiredString => try writer.writeAll(":filename:_files"),
                    .Bool, .RequiredBool => {},
                    .Int, .RequiredInt, .Float, .RequiredFloat => try writer.writeAll(":number"),
                    .Enum, .RequiredEnum => {
                        inline for (std.meta.fields(Typ)) |tf| {
                            if (std.mem.eql(u8, tf.name, f.long_name)) {
                                const RealT = NonOptionType(tf.type);
                                if (@typeInfo(RealT) == .@"enum") {
                                    try writer.writeAll(":(");
                                    inline for (std.meta.fields(RealT)) |ef| {
                                        try writer.print("{s} ", .{ef.name});
                                    }
                                    try writer.writeAll(")");
                                } else {
                                    try writer.writeAll(":value");
                                }
                            }
                        }
                    },
                }
            }

            try writer.writeAll("'");
        }
    }

    if (comptime @hasField(Typ, command_field_name_default)) {
        try writer.writeAll(" \\\n");
        try writer.writeAll("    '1: :->cmd' \\\n");
        try writer.writeAll("    '*:: :->args'");

        try writer.writeAll("\n\n");
        try writer.writeAll(
            \\  case $state in
            \\    cmd)
            \\      _describe -t subcommands 'subcommands' commands
            \\      ;;
            \\    args)
            \\      case $line[1] in
        );
        inline for (std.meta.fields(Typ)) |fld| {
            if (comptime std.mem.eql(u8, fld.name, command_field_name_default)) {
                inline for (std.meta.fields(fld.type)) |cmd_fld| {
                    try writer.print("        {s})\n          _{s}_{s}\n          ;;\n", .{ cmd_fld.name, cmd_path, cmd_fld.name });
                }
            }
        }
        try writer.writeAll(
            \\      esac
            \\      ;;
            \\  esac
        );
    } else {
        try writer.writeAll("\n");
    }

    try writer.writeAll("\n}\n\n");

    if (comptime @hasField(Typ, command_field_name_default)) {
        inline for (std.meta.fields(Typ)) |fld| {
            if (comptime std.mem.eql(u8, fld.name, command_field_name_default)) {
                inline for (std.meta.fields(fld.type)) |cmd_fld| {
                    var new_path_buf: [128]u8 = undefined;
                    const new_path = try std.fmt.bufPrint(&new_path_buf, "{s}_{s}", .{ cmd_path, cmd_fld.name });
                    try writeZshCompletion(cmd_fld.type, base_name, new_path, writer);
                }
            }
        }
    }
}

test "dynamic completion/different types" {
    const allocator = std.testing.allocator;
    const Args = struct {
        foo: []const u8 = "",
        bar: []const u8 = "",
        baz: []const u8 = "",
        qux: []const u8 = "",

        pub const __completers__ = .{
            .foo = &[_][]const u8{ "apple", "banana" },
            .bar = struct {
                fn run() []const []const u8 {
                    return &.{ "cherry", "date" };
                }
            }.run,
            .baz = struct {
                fn run(alloc: std.mem.Allocator) ![]const CompletionItem {
                    var list: std.ArrayList(CompletionItem) = .empty;
                    try list.append(alloc, .{ .value = "eggplant", .description = "purple" });
                    return list.toOwnedSlice(alloc);
                }
            }.run,
            .qux = struct {
                fn run(ctx: CompletionContext) !void {
                    try ctx.add("fig", "sweet");
                }
            }.run,
        };
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var writer = buf.writer(allocator);

    try runCompleter(allocator, .fish, &writer, Args.__completers__.foo);
    try std.testing.expectEqualStrings("apple\nbanana\n", buf.items);
    buf.items.len = 0;

    try runCompleter(allocator, .fish, &writer, Args.__completers__.bar);
    try std.testing.expectEqualStrings("cherry\ndate\n", buf.items);
    buf.items.len = 0;

    try runCompleter(allocator, .fish, &writer, Args.__completers__.baz);
    try std.testing.expectEqualStrings("eggplant\tpurple\n", buf.items);
    buf.items.len = 0;

    try runCompleter(allocator, .fish, &writer, Args.__completers__.qux);
    try std.testing.expectEqualStrings("fig\tsweet\n", buf.items);
}

test "completion generation/complex" {
    const allocator = std.testing.allocator;
    const ComplexArgs = struct {
        verbose: bool = false,
        @"user-agent": ?[]const u8 = "Firefox",
        __commands__: union(enum) {
            upload: struct {
                file: []const u8,
                force: bool = false,
                pub const __shorts__ = .{ .force = .f };
            },
            config: struct {
                key: []const u8,
                __commands__: union(enum) {
                    get: struct {
                        json: bool = false,
                    },
                    set: struct {
                        value: []const u8,
                    },
                    pub const __messages__ = .{
                        .get = "Get a config value",
                        .set = "Set a config value",
                    };
                },
            },
            pub const __messages__ = .{
                .upload = "Upload a file",
                .config = "Manage configuration",
            };
        },

        pub const __shorts__ = .{
            .verbose = .v,
        };
    };

    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "my-tool"),
        try allocator.dupeZ(u8, "upload"),
        try allocator.dupeZ(u8, "--file"),
        try allocator.dupeZ(u8, "test.txt"),
    };
    defer for (args) |arg| allocator.free(arg);

    var parser = OptionParser(ComplexArgs).init(allocator);
    const result = try parser.parse(&args, .{});
    defer result.deinit();

    {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try result.printCompletion(.fish, &aw.writer);
        const fish_out = aw.written();

        try std.testing.expect(std.mem.indexOf(u8, fish_out, "complete -c 'my-tool' -f -n \"__fish_use_subcommand\" -s v -l verbose") != null);
        try std.testing.expect(std.mem.indexOf(u8, fish_out, "complete -c 'my-tool' -f -n \"__fish_use_subcommand\" -a upload -d 'Upload a file'") != null);
        try std.testing.expect(std.mem.indexOf(u8, fish_out, "complete -c 'my-tool' -n \"__fish_seen_subcommand_from upload\" -s f -l force") != null);
        try std.testing.expect(std.mem.indexOf(u8, fish_out, "complete -c 'my-tool' -f -n \"__fish_seen_subcommand_from config\" -a get -d 'Get a config value'") != null);
        try std.testing.expect(std.mem.indexOf(u8, fish_out, "complete -c 'my-tool' -n \"__fish_seen_subcommand_from get\" -l json") != null);
    }

    {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try result.printCompletion(.bash, &aw.writer);
        const bash_out = aw.written();
        try std.testing.expect(std.mem.indexOf(u8, bash_out, "_my_tool_completion()") != null);
        try std.testing.expect(std.mem.indexOf(u8, bash_out, "opts=\"--verbose -v --user-agent upload --file --force -f config --key get --json set --value \"") != null);
    }

    {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try result.printCompletion(.zsh, &aw.writer);
        const zsh_out = aw.written();
        try std.testing.expect(std.mem.indexOf(u8, zsh_out, "#compdef \"my-tool\" \"my-tool\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, zsh_out, "function _my-tool") != null);
        try std.testing.expect(std.mem.indexOf(u8, zsh_out, "upload:Upload a file") != null);
        try std.testing.expect(std.mem.indexOf(u8, zsh_out, "config:Manage configuration") != null);
        try std.testing.expect(std.mem.indexOf(u8, zsh_out, "compdef _my-tool \"my-tool\" \"my-tool\"") != null);
    }
}
