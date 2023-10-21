//! A simple, opinionated, struct-based argument parser in Zig

const std = @import("std");
const testing = std.testing;
const is_test = @import("builtin").is_test;

const ParseError = error{ NoProgram, NoOption, MissingRequiredOption, MissingOptionValue, InvalidEnumValue };

const OptionError = ParseError || std.mem.Allocator.Error || std.fmt.ParseIntError || std.fmt.ParseFloatError || std.process.ArgIterator.InitError;

/// Parses arguments according to the given structure.
/// - `T` is the configuration of the arguments.
pub fn parse(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime arg_prompt: ?[]const u8,
    version: ?[]const u8,
) OptionError!StructArguments(T, arg_prompt) {
    const args = try std.process.argsAlloc(allocator);
    var parser = OptionParser(T).init(allocator, args);
    return parser.parse(arg_prompt, version);
}

const OptionField = struct {
    long_name: []const u8,
    opt_type: OptionType,
    short_name: ?u8 = null,
    message: ?[]const u8 = null,
    // whether this option is set
    is_set: bool = false,
};

fn parseOptionFields(comptime T: type) [std.meta.fields(T).len]OptionField {
    const option_type_info = @typeInfo(T);
    if (option_type_info != .Struct) {
        @compileError("option should be defined using struct, found " ++ @typeName(T));
    }

    var opt_fields: [std.meta.fields(T).len]OptionField = undefined;
    inline for (option_type_info.Struct.fields, 0..) |fld, idx| {
        const long_name = fld.name;
        const opt_type = OptionType.from_zig_type(
            fld.type,
        );
        opt_fields[idx] = .{
            .long_name = long_name,
            .opt_type = opt_type,
            // option with default value is set automatically
            .is_set = !(fld.default_value == null),
        };
    }

    // parse short names
    if (@hasDecl(T, "__shorts__")) {
        const shorts_type = @TypeOf(T.__shorts__);
        if (@typeInfo(shorts_type) != .Struct) {
            @compileError("__shorts__ should be defined using struct, found " ++ @typeName(@typeInfo(shorts_type)));
        }

        inline for (std.meta.fields(shorts_type)) |fld| {
            const long_name = fld.name;
            inline for (&opt_fields) |*opt_fld| {
                if (std.mem.eql(u8, opt_fld.long_name, long_name)) {
                    const short_name = @field(T.__shorts__, long_name);
                    if (@typeInfo(@TypeOf(short_name)) != .EnumLiteral) {
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
        if (@typeInfo(messages_type) != .Struct) {
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

test "parse option fields" {
    const fields = comptime parseOptionFields(struct {
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
        .Optional => |o| NonOptionType(o.child),
        else => opt_type,
    };
}

fn StructArguments(
    comptime T: type,
    comptime arg_prompt: ?[]const u8,
) type {
    return struct {
        program: []const u8,
        // Parsed arguments
        args: T,
        positional_args: std.ArrayList([]const u8),
        // Unparsed arguments
        raw_args: [][:0]u8,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn deinit(self: Self) void {
            self.positional_args.deinit();
            if (!is_test) {
                std.process.argsFree(self.allocator, self.raw_args);
            }
        }

        fn print_default(comptime f: std.builtin.Type.StructField, writer: anytype) !void {
            if (f.default_value == null) {
                if (@typeInfo(f.type) != .Optional) {
                    try writer.writeAll("(required)");
                }
                return;
            }

            // Don't print default for false (?)bool
            const default = @as(*align(1) const f.type, @ptrCast(f.default_value.?)).*;
            switch (@typeInfo(f.type)) {
                .Bool => if (!default) return,
                .Optional => |opt| if (@typeInfo(opt.child) == .Bool)
                    if (!(default orelse false)) return,
                else => {},
            }

            const format = "(default: " ++ switch (f.type) {
                []const u8 => "{s}",
                ?[]const u8 => "{?s}",
                else => if (@typeInfo(NonOptionType(f.type)) == .Enum)
                    "{s}"
                else
                    "{any}",
            } ++ ")";

            try std.fmt.format(writer, format, .{switch (@typeInfo(f.type)) {
                .Enum => @tagName(default),
                .Optional => |opt| if (@typeInfo(opt.child) == .Enum)
                    @tagName(default.?)
                else
                    default,
                else => default,
            }});
        }

        pub fn print_help(
            self: Self,
            writer: anytype,
        ) !void {
            const fields = comptime parseOptionFields(T);
            const header_tmpl =
                \\ USAGE:
                \\     {s} [OPTIONS] {s}
                \\
                \\ OPTIONS:
                \\
            ;
            const header = try std.fmt.allocPrint(self.allocator, header_tmpl, .{
                self.program,
                if (arg_prompt) |p|
                    "[--] " ++ p
                else
                    "",
            });
            defer self.allocator.free(header);

            try writer.writeAll(header);
            // TODO: Maybe be too small(or big)?
            const msg_offset = 35;
            for (fields) |opt_fld| {
                var curr_opt = std.ArrayList([]const u8).init(self.allocator);
                defer curr_opt.deinit();

                try curr_opt.append("\t");
                if (opt_fld.short_name) |sn| {
                    try curr_opt.append("-");
                    try curr_opt.append(&[_]u8{sn});
                    try curr_opt.append(", ");
                } else {
                    try curr_opt.append("    ");
                }
                try curr_opt.append("--");
                try curr_opt.append(opt_fld.long_name);
                try curr_opt.append(opt_fld.opt_type.as_string());

                var blanks: usize = msg_offset;
                for (curr_opt.items) |v| {
                    blanks -= v.len;
                }
                while (blanks > 0) {
                    try curr_opt.append(" ");
                    blanks -= 1;
                }

                if (opt_fld.message) |msg| {
                    try curr_opt.append(msg);
                }
                const first_part = try std.mem.join(self.allocator, "", curr_opt.items);
                defer self.allocator.free(first_part);
                try writer.writeAll(first_part);

                inline for (std.meta.fields(T)) |f| {
                    if (std.mem.eql(u8, f.name, opt_fld.long_name)) {
                        const real_type = NonOptionType(f.type);
                        if (@typeInfo(real_type) == .Enum) {
                            const enum_opts = try std.mem.join(self.allocator, "|", std.meta.fieldNames(real_type));
                            defer self.allocator.free(enum_opts);
                            try writer.writeAll(" (valid: ");
                            try writer.writeAll(enum_opts);
                            try writer.writeAll(")");
                        }

                        try Self.print_default(
                            f,
                            writer,
                        );
                    }
                }

                try writer.writeAll("\n");
            }
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
            .Int => .RequiredInt,
            .Bool => .RequiredBool,
            .Float => .RequiredFloat,
            .Optional => |opt_info| return Self.convert(opt_info.child, true),
            .Pointer => |ptr_info|
            // only support []const u8
            if (ptr_info.size == .Slice and ptr_info.child == u8 and ptr_info.is_const)
                .RequiredString
            else {
                @compileError("not supported option type:" ++ @typeName(T));
            },
            .Enum => .RequiredEnum,
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

/// `T` is a struct, which define options
fn OptionParser(
    comptime T: type,
) type {
    return struct {
        allocator: std.mem.Allocator,
        args: [][:0]u8,
        opt_fields: [std.meta.fields(T).len]OptionField,

        const Self = @This();

        fn init(allocator: std.mem.Allocator, args: [][:0]u8) Self {
            return .{
                .allocator = allocator,
                .args = args,
                .opt_fields = comptime parseOptionFields(T),
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

        fn parse(
            self: *Self,
            comptime arg_prompt: ?[]const u8,
            version: ?[]const u8,
        ) OptionError!StructArguments(T, arg_prompt) {
            if (self.args.len == 0) {
                return error.NoProgram;
            }

            var args: T = undefined;
            inline for (std.meta.fields(T)) |fld| {
                if (fld.default_value) |v| {
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
            var result = StructArguments(T, arg_prompt){
                .program = self.args[0],
                .allocator = self.allocator,
                .args = args,
                .positional_args = std.ArrayList([]const u8).init(self.allocator),
                .raw_args = self.args,
            };
            errdefer result.deinit();

            var state = ParseState.start;
            var current_opt: ?*OptionField = null;

            var arg_idx: usize = 1;
            while (arg_idx < self.args.len) {
                const arg = self.args[arg_idx];
                arg_idx += 1;

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
                            arg_idx -= 1;
                            continue;
                        }

                        if (std.mem.startsWith(u8, arg[1..], "-")) {
                            // long option
                            const long_name = arg[2..];
                            for (&self.opt_fields) |*opt_fld| {
                                if (std.mem.eql(u8, opt_fld.long_name, long_name)) {
                                    current_opt = opt_fld;
                                    break;
                                }
                            }
                        } else {
                            // short option
                            const short_name = arg[1..];
                            if (short_name.len != 1) {
                                std.log.warn("No such short option, name:{s}", .{arg});
                                return error.NoOption;
                            }
                            for (&self.opt_fields) |*opt| {
                                if (opt.short_name) |name| {
                                    if (name == short_name[0]) {
                                        current_opt = opt;
                                        break;
                                    }
                                }
                            }
                        }

                        var opt = current_opt orelse {
                            std.log.warn("Unknown option, name:{s}", .{arg});
                            return error.NoOption;
                        };

                        if (opt.opt_type == .Bool or opt.opt_type == .RequiredBool) {
                            opt.is_set = try Self.setOptionValue(&result.args, opt.long_name, "true");
                            // reset to initial status
                            state = .start;
                            current_opt = null;

                            // if current option is help, print help_message and exit directly.
                            if (!is_test) {
                                if (std.mem.eql(u8, opt.long_name, "help")) {
                                    const stdout = std.io.getStdOut();
                                    result.print_help(stdout.writer()) catch @panic("OOM");
                                    std.process.exit(0);
                                } else if (std.mem.eql(u8, opt.long_name, "version")) {
                                    if (version) |v| {
                                        const stdout = std.io.getStdOut();
                                        stdout.writer().writeAll(v) catch @panic("OOM");
                                        std.process.exit(0);
                                    }
                                }
                            }
                        } else {
                            state = .waitValue;
                        }
                    },
                    .args => {
                        try result.positional_args.append(arg);
                    },
                    .waitValue => {
                        var opt = current_opt.?;
                        opt.is_set = try Self.setOptionValue(&result.args, opt.long_name, arg);
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

            inline for (self.opt_fields) |opt| {
                if (opt.opt_type.is_required()) {
                    if (!opt.is_set) {
                        std.log.warn("Missing required option, name:{s}", .{opt.long_name});
                        return error.MissingRequiredOption;
                    }
                }
            }
            return result;
        }

        fn getSignedness(comptime opt_type: type) std.builtin.Signedness {
            return switch (@typeInfo(opt_type)) {
                .Int => |i| i.signedness,
                .Optional => |o| Self.getSignedness(o.child),
                else => @compileError("not int type, have no signedness"),
            };
        }

        // return true when set successfully
        fn setOptionValue(opt: *T, long_name: []const u8, raw_value: []const u8) !bool {
            inline for (std.meta.fields(T)) |field| {
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

    var parser = OptionParser(TestArguments).init(allocator, &args);
    const opt = try parser.parse("...", null);
    defer opt.deinit();

    try std.testing.expectEqualDeep(TestArguments{
        .help = true,
        .rate = 1.2,
        .timeout = 30,
        .@"user-agent" = "firefox",
    }, opt.args);

    var expected = [_][]const u8{ "hello", "world" };
    try std.testing.expectEqualDeep(
        opt.positional_args.items,
        &expected,
    );

    var help_msg = std.ArrayList(u8).init(allocator);
    defer help_msg.deinit();

    try opt.print_help(help_msg.writer());
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\	-h, --help                        print this help message(required)
        \\	-r, --rate FLOAT                  (default: 2.0e+00)
        \\	    --timeout INTEGER             (required)
        \\	    --user-agent STRING           (default: Brave)
        \\
    , help_msg.items);
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
        var parser = OptionParser(struct { help: bool }).init(allocator, &args);
        const opt = try parser.parse(null, null);
        defer opt.deinit();

        try std.testing.expectEqual(opt.args, .{ .help = true });
        try std.testing.expectEqual(opt.positional_args.items, &[_][]const u8{});
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
        var parser = OptionParser(struct { help: bool }).init(allocator, &args);
        const opt = try parser.parse(null, null);
        defer opt.deinit();

        try std.testing.expectEqual(opt.args, .{ .help = true });
        var expected = [_][]const u8{
            "true",
        };
        try std.testing.expectEqualDeep(
            opt.positional_args.items,
            &expected,
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
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.MissingRequiredOption, parser.parse(null, null));
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
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(null, null));
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
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.InvalidCharacter, parser.parse(null, null));
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
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.NoOption, parser.parse(null, null));
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
    var parser = OptionParser(TestArguments).init(allocator, &args);

    try std.testing.expectError(error.MissingOptionValue, parser.parse(null, null));
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
    }).init(allocator, &args);
    const opt = try parser.parse("...", null);
    try std.testing.expectEqualStrings("A1", opt.args.a1);
    try std.testing.expectEqual(opt.positional_args.items.len, 0);
    var help_msg = std.ArrayList(u8).init(allocator);
    defer help_msg.deinit();
    try opt.print_help(help_msg.writer());
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\	    --a1 STRING                   (default: A1)
        \\	    --a2 STRING                   (default: A2)
        \\	    --b1 INTEGER                  (default: 1)
        \\	    --b2 INTEGER                  (default: 11)
        \\	    --c1 FLOAT                    (default: 1.5e+00)
        \\	    --c2 FLOAT                    (default: 2.5e+00)
        \\	    --d1                          (default: true)
        \\	    --d2                          padding message
        \\
    , help_msg.items);
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
    }).init(allocator, &args);
    const opt = try parser.parse("...", null);
    defer opt.deinit();

    try std.testing.expectEqual(opt.args.a1, .A);
    var help_msg = std.ArrayList(u8).init(allocator);
    defer help_msg.deinit();
    try opt.print_help(help_msg.writer());
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\	    --a1 STRING                    (valid: A|B)(default: A)
        \\	    --a2 STRING                    (valid: C|D)(default: D)
        \\	    --a3 STRING                    (valid: X|Y)(required)
        \\
    , help_msg.items);
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
    }).init(allocator, &args);
    const opt = try parser.parse("...", null);
    defer opt.deinit();

    try std.testing.expectEqualDeep(opt.args, .{ .a = 1 });
    var expected = [_][]const u8{ "-a", "2" };
    try std.testing.expectEqualDeep(opt.positional_args.items, &expected);

    var help_msg = std.ArrayList(u8).init(allocator);
    defer help_msg.deinit();
    try opt.print_help(help_msg.writer());
    try std.testing.expectEqualStrings(
        \\ USAGE:
        \\     awesome-cli [OPTIONS] [--] ...
        \\
        \\ OPTIONS:
        \\	    --a INTEGER                   (default: 1)
        \\
    , help_msg.items);
}
