//! A simple, opinionated, struct-based argument parser in Zig

const std = @import("std");
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

const COMMAND_FIELD_NAME = "__commands__";

const OptionError = ParseError || std.mem.Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError || std.process.ArgIterator.InitError;

/// Parses arguments according to the given structure.
/// - `T` is the configuration of the arguments.
pub fn parse(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime arg_prompt: ?[]const u8,
    comptime version: ?[]const u8,
) OptionError!StructArguments(T, version, arg_prompt) {
    const args = try std.process.argsAlloc(allocator);
    var parser = OptionParser(T).init(allocator);
    return parser.parse(arg_prompt, version, args);
}

const OptionField = struct {
    long_name: []const u8,
    opt_type: OptionType,
    short_name: ?u8 = null,
    message: ?[]const u8 = null,
    // whether this option is set
    is_set: bool = false,
};

fn getOptionLength(comptime T: type) usize {
    const option_type_info = @typeInfo(T);
    if (!isStruct(option_type_info)) {
        @compileError("option should be defined using struct, found " ++ @typeName(T));
    }
    inline for (std.meta.fields(T)) |fld| {
        if (std.mem.eql(u8, fld.name, COMMAND_FIELD_NAME)) {
            return std.meta.fields(T).len - 1;
        }
    }

    return std.meta.fields(T).len;
}

fn buildOptionFields(comptime T: type) [getOptionLength(T)]OptionField {
    const option_type_info = @typeInfo(T);
    if (!isStruct(option_type_info)) {
        @compileError("option should be defined using struct, found " ++ @typeName(T));
    }

    var opt_fields: [getOptionLength(T)]OptionField = undefined;
    inline for (std.meta.fields(T), 0..) |fld, idx| {
        const long_name = fld.name;
        if (std.mem.eql(u8, fld.name, COMMAND_FIELD_NAME)) {
            continue;
        }
        const opt_type = OptionType.from_zig_type(fld.type);
        opt_fields[idx] = .{
            .long_name = long_name,
            .opt_type = opt_type,
            // option with default value is set automatically
            .is_set = fld.default_value_ptr != null,
        };
    }

    // parse short names
    if (@hasDecl(T, "__shorts__")) {
        const shorts_type = @TypeOf(T.__shorts__);
        if (!isStruct(@typeInfo(shorts_type))) {
            @compileError("__shorts__ should be defined using struct, found " ++ @typeName(@typeInfo(shorts_type)));
        }

        inline for (std.meta.fields(shorts_type)) |fld| {
            const long_name = fld.name;
            inline for (&opt_fields) |*opt_fld| {
                if (std.mem.eql(u8, opt_fld.long_name, long_name)) {
                    const short_name = @field(T.__shorts__, long_name);
                    if (@typeInfo(@TypeOf(short_name)) != .enum_literal) {
                        @compileError("short option value must be literal enum, found " ++ @typeName(@typeInfo(@TypeOf(short_name))));
                    }
                    opt_fld.short_name = @tagName(short_name)[0];

                    break;
                }
            } else {
                @compileError("no such option exists, long_name: " ++ long_name);
            }
        }
    }

    // parse messages
    if (@hasDecl(T, "__messages__")) {
        const messages_type = @TypeOf(T.__messages__);
        if (!isStruct(@typeInfo(messages_type))) {
            @compileError("__messages__ should be defined using struct, found " ++ @typeName(@typeInfo(messages_type)));
        }

        inline for (std.meta.fields(messages_type)) |fld| {
            const long_name = fld.name;
            inline for (&opt_fields) |*opt_fld| {
                if (std.mem.eql(u8, opt_fld.long_name, long_name)) {
                    opt_fld.message = @field(T.__messages__, long_name);
                    break;
                }
            } else {
                @compileError("no such option exists, long_name: " ++ long_name);
            }
        }
    }

    return opt_fields;
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
        .{ .long_name = "verbose", .short_name = 'v', .message = "show verbose log", .opt_type = .RequiredBool },
        .{ .long_name = "help", .opt_type = .Bool },
        .{ .long_name = "timeout", .opt_type = .RequiredInt },
        .{ .long_name = "user-agent", .opt_type = .String },
    }, fields);
}

fn NonOptionType(comptime opt_type: type) type {
    return switch (@typeInfo(opt_type)) {
        .optional => |o| NonOptionType(o.child),
        else => opt_type,
    };
}

const MessageHelper = struct {
    allocator: std.mem.Allocator,
    program: []const u8,
    arg_prompt: ?[]const u8,
    version: ?[]const u8,

    fn init(
        allocator: std.mem.Allocator,
        program: []const u8,
        version: ?[]const u8,
        arg_prompt: ?[]const u8,
    ) MessageHelper {
        return .{
            .allocator = allocator,
            .program = program,
            .version = version,
            .arg_prompt = arg_prompt,
        };
    }

    fn printDefault(comptime f: std.builtin.Type.StructField, writer: *Writer) !void {
        if (f.default_value_ptr == null) {
            if (@typeInfo(f.type) != .optional) {
                try writer.writeAll("(required)");
            }
            return;
        }

        // Don't print default for false (?)bool
        const default = @as(*align(1) const f.type, @ptrCast(f.default_value_ptr.?)).*;
        switch (@typeInfo(f.type)) {
            .bool => if (!default) return,
            .optional => |opt| if (@typeInfo(opt.child) == .bool)
                if (!(default orelse false)) return,
            else => {},
        }

        const format = "(default: " ++ switch (f.type) {
            []const u8 => "{s}",
            ?[]const u8 => "{?s}",
            else => if (@typeInfo(NonOptionType(f.type)) == .@"enum")
                "{s}"
            else
                "{any}",
        } ++ ")";
        try writer.print(format, .{switch (@typeInfo(f.type)) {
            .@"enum" => @tagName(default),
            .optional => |opt| if (@typeInfo(opt.child) == .@"enum")
                @tagName(default.?)
            else
                default,
            else => default,
        }});
    }

    pub fn printVersion(
        self: MessageHelper,
    ) !void {
        const stdout = std.fs.File.stdout();
        var buf: [1024]u8 = undefined;
        var writer = stdout.writer(&buf);
        if (self.version) |v| {
            try writer.interface.writeAll(v);
        } else {
            try writer.interface.writeAll("Unknown");
        }
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    pub fn printHelp(
        self: MessageHelper,
        comptime T: type,
        sub_cmd_name: ?[]const u8,
        writer: *Writer,
    ) !void {
        const fields = comptime buildOptionFields(T);
        const sub_cmds = if (@hasField(T, COMMAND_FIELD_NAME)) blk: {
            inline for (std.meta.fields(T)) |fld| {
                if (comptime std.mem.eql(u8, fld.name, COMMAND_FIELD_NAME)) {
                    break :blk subCommandsHelpMsg(
                        fld.type,
                        std.meta.fields(fld.type).len,
                    );
                }
            }
        } else null;

        const header_tmpl =
            \\ USAGE:
            \\     {s} [OPTIONS] {s}
            \\
            \\ OPTIONS:
            \\
        ;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const header = try std.fmt.allocPrint(aa, header_tmpl, .{
            if (sub_cmd_name) |cmd| blk: {
                break :blk try std.fmt.allocPrint(aa, "{s} {s}", .{ self.program, cmd });
            } else self.program,

            if (sub_cmds) |cmds|
            blk: {
                const cmd_msg_offset = 10;
                var lst: std.ArrayList([]const u8) = .empty;
                try lst.append(aa, "[COMMANDS]\n\n COMMANDS:");
                for (cmds) |cmd| {
                    if (cmd.name.len <= cmd_msg_offset) {
                        try lst.append(aa, try std.fmt.allocPrint(aa, "  {s:<10} {s}", .{ cmd.name, cmd.message }));
                    } else {
                        const spaces = " " ** cmd_msg_offset;
                        try lst.append(aa, try std.fmt.allocPrint(aa, "  {s}\n  {s} {s}", .{ cmd.name, spaces, cmd.message }));
                    }
                }
                break :blk try std.mem.join(aa, "\n", lst.items);
            } else if (self.arg_prompt) |p|
            blk: {
                if (sub_cmd_name == null) {
                    break :blk try std.fmt.allocPrint(aa, "[--] {s}", .{p});
                } else {
                    break :blk "";
                }
            } else "",
        });

        try writer.writeAll(header);
        // TODO: Maybe be too small(or big)?
        const msg_offset = 35;
        for (fields) |opt_fld| {
            var curr_opt: std.ArrayList([]const u8) = .empty;
            defer curr_opt.deinit(aa);

            try curr_opt.append(aa, "  ");
            if (opt_fld.short_name) |sn| {
                try curr_opt.append(aa, "-");
                try curr_opt.append(aa, &[_]u8{sn});
                try curr_opt.append(aa, ", ");
            } else {
                try curr_opt.append(aa, "    ");
            }
            try curr_opt.append(aa, "--");
            try curr_opt.append(aa, opt_fld.long_name);
            try curr_opt.append(aa, opt_fld.opt_type.as_string());

            var blanks: usize = msg_offset;
            for (curr_opt.items) |v| {
                blanks = if (blanks > v.len) blanks - v.len else 0;
            }

            if (blanks == 0) {
                try curr_opt.append(aa, "\n");
                try curr_opt.append(aa, " " ** msg_offset);
            } else while (blanks > 0) {
                try curr_opt.append(aa, " ");
                blanks -= 1;
            }

            if (opt_fld.message) |msg| {
                try curr_opt.append(aa, msg);
            }
            const first_part = try std.mem.join(aa, "", curr_opt.items);
            try writer.writeAll(first_part);

            inline for (std.meta.fields(T)) |f| {
                if (std.mem.eql(u8, f.name, opt_fld.long_name)) {
                    const real_type = NonOptionType(f.type);
                    if (@typeInfo(real_type) == .@"enum") {
                        const enum_opts = try std.mem.join(aa, "|", std.meta.fieldNames(real_type));
                        try writer.writeAll(" (valid: ");
                        try writer.writeAll(enum_opts);
                        try writer.writeAll(")");
                    }

                    try MessageHelper.printDefault(
                        f,
                        writer,
                    );
                }
            }

            try writer.writeAll("\n");
        } // end for fields

        try writer.flush();
    }
};

fn StructArguments(
    comptime T: type,
    comptime version: ?[]const u8,
    comptime arg_prompt: ?[]const u8,
) type {
    return struct {
        program: []const u8,
        // Parsed arguments
        args: T,
        positional_args: [][:0]u8,

        // Unparsed arguments
        raw_args: [][:0]u8,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn deinit(self: Self) void {
            if (!is_test) {
                std.process.argsFree(self.allocator, self.raw_args);
            }
        }

        pub fn printHelp(self: Self, writer: *Writer) !void {
            try MessageHelper.init(
                self.allocator,
                self.program,
                version,
                arg_prompt,
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
        const base_type: Self = switch (@typeInfo(T)) {
            .int => .RequiredInt,
            .bool => .RequiredBool,
            .float => .RequiredFloat,
            .optional => |opt_info| return Self.convert(opt_info.child, true),
            .pointer => |ptr_info|
            // only support []const u8
            if (ptr_info.size == .slice and ptr_info.child == u8 and ptr_info.is_const)
                .RequiredString
            else {
                @compileError("not supported option type:" ++ @typeName(T));
            },
            .@"enum" => .RequiredEnum,
            else => {
                @compileError("not supported option type:" ++ @typeName(T));
            },
        };
        return @enumFromInt(@intFromEnum(base_type) + if (is_optional) @This().REQUIRED_VERSION_SHIFT else 0);
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
        .{ enum {}, OptionType.RequiredEnum },
        .{ ?enum {}, OptionType.Enum },
    };

    inline for (testcases) |tc| {
        try std.testing.expectEqual(tc.@"1", comptime OptionType.from_zig_type(tc.@"0"));
    }
}

const MessageWrapper = struct {
    name: []const u8,
    message: []const u8,
};

fn subCommandsHelpMsg(comptime T: type, comptime len: usize) ?[len]MessageWrapper {
    const union_type_info = @typeInfo(T);
    if (union_type_info != .@"union") {
        @compileError("sub commands should be defined using Union(enum), found " ++ @typeName(T));
    }

    if (@hasDecl(T, "__messages__")) {
        const messages_type = @TypeOf(T.__messages__);
        if (comptime !isStruct(@typeInfo(messages_type))) {
            @compileError("__messages__ should be defined using struct");
        }

        var fields: [std.meta.fields(messages_type).len]MessageWrapper = undefined;
        inline for (std.meta.fields(messages_type), 0..) |msg_fld, idx| {
            inline for (std.meta.fields(T)) |union_fld| {
                if (comptime std.mem.eql(u8, msg_fld.name, union_fld.name)) {
                    fields[idx] = MessageWrapper{
                        .name = msg_fld.name,
                        .message = @field(T.__messages__, msg_fld.name),
                    };
                    break;
                }
            } else {
                @compileError("no such sub_cmd exists, name: " ++ msg_fld.name);
            }
        }

        return fields;
    }

    return null;
}

fn SubCommandsType(comptime T: type) type {
    const union_type_info = @typeInfo(T);
    if (union_type_info != .@"union") {
        @compileError("sub commands should be defined using Union(enum), found " ++ @typeName(T));
    }

    var fields: [std.meta.fields(T).len]std.builtin.Type.StructField = undefined;
    inline for (std.meta.fields(T), 0..) |fld, idx| {
        comptime if (!isStruct(@typeInfo(fld.type))) {
            @compileError("sub command should be defined using struct, found " ++ @typeName(@typeInfo(fld.type)));
        };
        const FieldType = CommandParser(fld.type);
        const default_value = FieldType{};
        fields[idx] = .{
            .name = fld.name,
            .type = CommandParser(fld.type),
            .default_value_ptr = @ptrCast(&default_value),
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn CommandParser(comptime T: type) type {
    return struct {
        opt_fields: [getOptionLength(T)]OptionField = buildOptionFields(T),
        opt_cmds: if (@hasField(T, COMMAND_FIELD_NAME)) blk: {
            for (std.meta.fields(T)) |fld| {
                if (std.mem.eql(u8, fld.name, COMMAND_FIELD_NAME)) {
                    break :blk SubCommandsType(fld.type);
                }
            } else {
                unreachable;
            }
        } else void = if (@hasField(T, COMMAND_FIELD_NAME)) .{} else {},
    };
}

/// `T` is a struct, which define options
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

        // State machine used to parse arguments.
        // Available state transitions:
        // 1. start -> args
        // 2. start -> waitValue -> .. -> waitValue --> args -> ... -> args
        // 3. start
        const ParseState = enum {
            start,
            waitValue,
            args,
        };

        fn parseCommand(
            comptime Args: type,
            input_args: [][:0]u8,
            arg_idx: *usize,
            msg_helper: MessageHelper,
            sub_cmd_name: ?[]const u8,
        ) !Args {
            var args: Args = undefined;
            var parser = CommandParser(Args){};
            var sub_cmd_set = false;
            inline for (std.meta.fields(Args)) |fld| {
                if (comptime std.mem.eql(u8, fld.name, COMMAND_FIELD_NAME)) {
                    if (fld.default_value_ptr) |v| {
                        sub_cmd_set = true;
                        @field(args, fld.name) = @as(*align(1) const fld.type, @ptrCast(v)).*;
                    }
                    continue;
                }

                if (fld.default_value_ptr) |v| {
                    // https://github.com/ziglang/zig/blob/d69e97ae1677ca487833caf6937fa428563ed0ae/lib/std/json.zig#L1590
                    // why align(1) is used here?
                    @field(args, fld.name) = @as(*align(1) const fld.type, @ptrCast(v)).*;
                } else {
                    const is_option = !comptime OptionType.from_zig_type(fld.type).is_required();
                    if (is_option) {
                        @field(args, fld.name) = null;
                    }
                }
            }

            var state = ParseState.start;
            var current_opt: ?*OptionField = null;
            outer: while (arg_idx.* < input_args.len) {
                const arg = input_args[arg_idx.*];
                // Point to the next argument
                arg_idx.* += 1;

                switch (state) {
                    .start => {
                        // From now on, all arguments are positional arguments
                        if (std.mem.eql(u8, arg, "--")) {
                            state = .args;
                            continue;
                        }
                        if (!std.mem.startsWith(u8, arg, "-")) {
                            // no option any more, the rest are positional args
                            state = .args;
                            // step back one arg to parse it as positional args
                            arg_idx.* -= 1;
                            continue;
                        }

                        if (std.mem.startsWith(u8, arg[1..], "-")) {
                            // long option
                            const long_name = arg[2..];
                            for (&parser.opt_fields) |*opt_fld| {
                                if (std.mem.eql(u8, opt_fld.long_name, long_name)) {
                                    current_opt = opt_fld;
                                    break;
                                }
                            }
                        } else {
                            // short option
                            const short_name = arg[1..];
                            if (short_name.len != 1) {
                                if (!is_test) {
                                    std.log.err("No such short option '{s}'", .{arg});
                                }
                                return error.NoOption;
                            }
                            for (&parser.opt_fields) |*opt| {
                                if (opt.short_name) |name| {
                                    if (name == short_name[0]) {
                                        current_opt = opt;
                                        break;
                                    }
                                }
                            }
                        }

                        var opt = current_opt orelse {
                            if (!is_test) {
                                std.log.err("Unknown option '{s}'", .{arg});
                            }
                            return error.NoOption;
                        };

                        if (opt.opt_type == .Bool or opt.opt_type == .RequiredBool) {
                            opt.is_set = try Self.setOptionValue(Args, &args, opt.long_name, "true");
                            // reset to initial status
                            state = .start;
                            current_opt = null;

                            // if current option is help, print help_message and exit directly.
                            if (!is_test) {
                                if (std.mem.eql(u8, opt.long_name, "help")) {
                                    var stdout_buffer: [1024]u8 = undefined;
                                    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
                                    const stdout = &stdout_writer.interface;
                                    msg_helper.printHelp(Args, sub_cmd_name, stdout) catch @panic("OOM");
                                    std.process.exit(0);
                                } else if (std.mem.eql(u8, opt.long_name, "version")) {
                                    msg_helper.printVersion() catch @panic("OOM");
                                    std.process.exit(0);
                                }
                            }
                        } else {
                            state = .waitValue;
                        }
                    },
                    .args => {
                        if (@TypeOf(parser.opt_cmds) != void) {
                            // parse sub command
                            inline for (std.meta.fields(@TypeOf(parser.opt_cmds))) |fld| {
                                if (std.mem.eql(u8, fld.name, arg)) {
                                    const CmdType = @TypeOf(@field(args, COMMAND_FIELD_NAME));
                                    inline for (std.meta.fields(CmdType)) |union_fld| {
                                        if (comptime std.mem.eql(u8, union_fld.name, fld.name)) {
                                            const value = try Self.parseCommand(
                                                union_fld.type,
                                                input_args,
                                                arg_idx,
                                                msg_helper,
                                                fld.name,
                                            );
                                            @field(args, COMMAND_FIELD_NAME) = @unionInit(CmdType, fld.name, value);
                                            sub_cmd_set = true;
                                            break :outer;
                                        }
                                    }
                                }
                            }
                        }
                        // From now on, the rest are all positional arguments.
                        arg_idx.* -= 1;
                        break :outer;
                    },
                    .waitValue => {
                        var opt = current_opt.?;
                        opt.is_set = try Self.setOptionValue(Args, &args, opt.long_name, arg);
                        // reset to initial status
                        state = .start;
                        current_opt = null;
                    },
                }
            }

            switch (state) {
                // normal exit state
                .start, .args => {},
                .waitValue => return error.MissingOptionValue,
            }

            if (@TypeOf(parser.opt_cmds) != void and !sub_cmd_set) {
                return error.MissingSubCommand;
            }
            inline for (parser.opt_fields) |opt| {
                if (opt.opt_type.is_required()) {
                    if (!opt.is_set) {
                        if (!is_test) {
                            std.log.err("Missing required option '{s}'", .{opt.long_name});
                        }
                        return error.MissingRequiredOption;
                    }
                }
            }

            return args;
        }

        fn parse(
            self: *Self,
            comptime arg_prompt: ?[]const u8,
            comptime version: ?[]const u8,
            input_args: [][:0]u8,
        ) OptionError!StructArguments(T, version, arg_prompt) {
            if (input_args.len == 0) {
                return error.NoProgram;
            }

            const parse_args = input_args[1..];
            var arg_idx: usize = 0;
            const msg_helper = MessageHelper.init(
                self.allocator,
                input_args[0],
                version,
                arg_prompt,
            );
            const parsed = try Self.parseCommand(
                T,
                parse_args,
                &arg_idx,
                msg_helper,
                null,
            );
            var result = StructArguments(T, version, arg_prompt){
                .program = input_args[0],
                .allocator = self.allocator,
                .args = parsed,
                .positional_args = parse_args[arg_idx..],
                .raw_args = input_args,
            };
            errdefer result.deinit();

            return result;
        }

        fn getSignedness(comptime opt_type: type) std.builtin.Signedness {
            return switch (@typeInfo(opt_type)) {
                .int => |i| i.signedness,
                .optional => |o| Self.getSignedness(o.child),
                else => @compileError("not int type, have no signedness"),
            };
        }

        // return true when set successfully
        fn setOptionValue(comptime Args: type, opt: *Args, long_name: []const u8, raw_value: []const u8) !bool {
            inline for (std.meta.fields(Args)) |field| {
                if (comptime std.mem.eql(u8, field.name, COMMAND_FIELD_NAME)) {
                    continue;
                }

                if (std.mem.eql(u8, field.name, long_name)) {
                    @field(opt, field.name) =
                        switch (comptime OptionType.from_zig_type(field.type)) {
                            .Int, .RequiredInt => blk: {
                                const real_type = comptime NonOptionType(field.type);
                                break :blk switch (Self.getSignedness(field.type)) {
                                    .signed => try std.fmt.parseInt(real_type, raw_value, 0),
                                    .unsigned => try std.fmt.parseUnsigned(real_type, raw_value, 0),
                                };
                            },
                            .Float, .RequiredFloat => try std.fmt.parseFloat(comptime NonOptionType(field.type), raw_value),
                            .String, .RequiredString => raw_value,
                            .Bool, .RequiredBool => std.mem.eql(u8, raw_value, "true") or std.mem.eql(u8, raw_value, "1"),
                            .Enum, .RequiredEnum => blk: {
                                if (std.meta.stringToEnum(comptime NonOptionType(field.type), raw_value)) |v| {
                                    break :blk v;
                                } else {
                                    return error.InvalidEnumValue;
                                }
                            },
                        };

                    return true;
                }
            }

            return false;
        }
    };
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
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "--help"),
        try allocator.dupeZ(u8, "--rate"),
        try allocator.dupeZ(u8, "1.2"),
        try allocator.dupeZ(u8, "--timeout"),
        try allocator.dupeZ(u8, "30"),
        try allocator.dupeZ(u8, "--user-agent"),
        try allocator.dupeZ(u8, "firefox"),
        // positional args
        try allocator.dupeZ(u8, "hello"),
        try allocator.dupeZ(u8, "world"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };

    var parser = OptionParser(TestArguments).init(allocator);
    const opt = try parser.parse("...", null, &args);
    defer opt.deinit();

    try std.testing.expectEqualDeep(TestArguments{
        .help = true,
        .rate = 1.2,
        .timeout = 30,
        .@"user-agent" = "firefox",
    }, opt.args);

    const expected = args[args.len - 2 ..];
    try std.testing.expectEqualDeep(opt.positional_args, expected);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try opt.printHelp(&writer.writer);
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
    , writer.writer.buffered());
}

test "parse/bool value" {
    const allocator = std.testing.allocator;
    {
        var args = [_][:0]u8{
            try allocator.dupeZ(u8, "awesome-cli"),
            try allocator.dupeZ(u8, "--help"),
        };
        defer for (args) |arg| {
            allocator.free(arg);
        };
        var parser = OptionParser(struct { help: bool }).init(allocator);
        const opt = try parser.parse(null, null, &args);
        defer opt.deinit();

        try std.testing.expect(opt.args.help);
        try std.testing.expectEqual(opt.positional_args.len, 0);
    }
    {
        var args = [_][:0]u8{
            try allocator.dupeZ(u8, "awesome-cli"),
            try allocator.dupeZ(u8, "--help"),
            try allocator.dupeZ(u8, "true"),
        };
        defer for (args) |arg| {
            allocator.free(arg);
        };
        var parser = OptionParser(struct { help: bool }).init(allocator);
        const opt = try parser.parse(null, null, &args);
        defer opt.deinit();

        try std.testing.expect(opt.args.help);
        const expected = args[args.len - 1 ..];
        try std.testing.expectEqualDeep(
            opt.positional_args,
            expected,
        );
    }
}

test "parse/missing required arguments" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "abc"),
        try allocator.dupeZ(u8, "def"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator);

    try std.testing.expectError(error.MissingRequiredOption, parser.parse(null, null, &args));
}

test "parse/invalid u16 values" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "--timeout"),
        try allocator.dupeZ(u8, "not-a-number"),
        try allocator.dupeZ(u8, "--help"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(null, null, &args));
}

test "parse/invalid f32 values" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "--rate"),
        try allocator.dupeZ(u8, "not-a-number"),
        try allocator.dupeZ(u8, "--help"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(null, null, &args));
}

test "parse/unknown option" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "-h"),
        try allocator.dupeZ(u8, "--timeout"),
        try allocator.dupeZ(u8, "1"),
        try allocator.dupeZ(u8, "--notexists"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator);

    try std.testing.expectError(error.NoOption, parser.parse(null, null, &args));
}

test "parse/missing option value" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "-h"),
        try allocator.dupeZ(u8, "--timeout"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(TestArguments).init(allocator);

    try std.testing.expectError(error.MissingOptionValue, parser.parse(null, null, &args));
}

test "parse/default value" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
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
    }).init(allocator);
    const opt = try parser.parse("...", null, &args);
    try std.testing.expectEqualStrings("A1", opt.args.a1);
    try std.testing.expectEqual(opt.positional_args.len, 0);
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try opt.printHelp(&writer.writer);
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
    , writer.writer.buffered());
}

test "parse/enum option" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "--a3"),
        try allocator.dupeZ(u8, "Y"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(struct {
        a1: ?enum { A, B } = .A,
        a2: enum { C, D } = .D,
        a3: enum { X, Y },
    }).init(allocator);
    const opt = try parser.parse("...", null, &args);
    defer opt.deinit();

    try std.testing.expectEqual(opt.args.a1, .A);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try opt.printHelp(&writer.writer);
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\      --a1 STRING                   (valid: A|B)(default: A)
        \\      --a2 STRING                   (valid: C|D)(default: D)
        \\      --a3 STRING                   (valid: X|Y)(required)
        \\
    , writer.writer.buffered());
}

test "parse/positional arguments" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "--"),
        try allocator.dupeZ(u8, "-a"),
        try allocator.dupeZ(u8, "2"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
    };
    var parser = OptionParser(struct {
        a: u8 = 1,
    }).init(allocator);
    const opt = try parser.parse("...", null, &args);
    defer opt.deinit();

    try std.testing.expectEqualDeep(opt.args.a, 1);
    const expected = args[args.len - 2 ..];
    try std.testing.expectEqualDeep(opt.positional_args, expected);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try opt.printHelp(&writer.writer);
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\      --a INTEGER                  (default: 1)
        \\
    , writer.writer.buffered());
}

test "parse/sub commands" {
    const allocator = std.testing.allocator;
    var args = [_][:0]u8{
        try allocator.dupeZ(u8, "awesome-cli"),
        try allocator.dupeZ(u8, "--a"),
        try allocator.dupeZ(u8, "2"),
        try allocator.dupeZ(u8, "cmd1"),
        try allocator.dupeZ(u8, "--aa"),
        try allocator.dupeZ(u8, "22"),
    };
    defer for (args) |arg| {
        allocator.free(arg);
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
    }).init(allocator);
    const opt = try parser.parse("...", null, &args);
    defer opt.deinit();

    try std.testing.expectEqualDeep(opt.args.a, 2);
    try std.testing.expectEqual(opt.positional_args.len, 0);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try opt.printHelp(&writer.writer);
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
    , writer.writer.buffered());
}

fn isStruct(info: std.builtin.Type) bool {
    return info == .@"struct";
}
