const std = @import("std");
const zigcli = @import("zigcli");
const pt = zigcli.pretty_table;
const Table = pt.Table;
const Cell = pt.Cell;
const Separator = pt.Separator;
const structargs = zigcli.structargs;
const util = @import("util.zig");
const gitignore = zigcli.gitignore;
const StringUtil = util.StringUtil;
const fs = std.fs;
const Io = std.Io;

const Language = enum {
    Zig,
    C,
    CPP,
    CHeader,
    Go,
    Rust,
    Bash,
    Python,
    Ruby,
    JavaScript,
    Java,
    Makefile,
    Markdown,
    HTML,
    YAML,
    TOML,
    JSON,
    TypeScript,
    Swift,
    Other,
    // Used in footer
    Total,

    const Self = @This();

    fn multiLineCommentBeginChars(self: Self) ?[]const u8 {
        return switch (self) {
            .Markdown, .HTML => "<!--",
            .C, .CPP, .CHeader, .Java, .JavaScript => "/*",
            else => null,
        };
    }

    fn multiLineCommentEndChars(self: Self) []const u8 {
        return switch (self) {
            .Markdown, .HTML => "--!>",
            .C, .CPP, .CHeader, .Java, .JavaScript => "*/",
            else => unreachable,
        };
    }

    fn commentChars(self: Self) ?[]const u8 {
        return switch (self) {
            .Bash, .Python, .Ruby, .Makefile, .YAML, .TOML => "#",
            .Markdown, .HTML => null,
            else => "//",
        };
    }

    const ExtLangMap = std.StaticStringMap(Self).initComptime(.{
        .{ ".zig", .Zig },
        .{ ".c", .C },
        .{ ".cpp", .CPP },
        .{ ".cxx", .CPP },
        .{ ".cc", .CPP },
        .{ ".h", .CHeader },
        .{ ".go", .Go },
        .{ ".rs", .Rust },
        .{ ".sh", .Bash },
        .{ ".py", .Python },
        .{ ".rb", .Ruby },
        .{ ".js", .JavaScript },
        .{ ".java", .Java },
        .{ ".md", .Markdown },
        .{ ".markdown", .Markdown },
        .{ ".html", .HTML },
        .{ ".yml", .YAML },
        .{ ".yaml", .YAML },
        .{ ".toml", .TOML },
        .{ ".json", .JSON },
        .{ ".ts", .TypeScript },
        .{ ".swift", .Swift },
    });
    const FilenameLangMap = std.StaticStringMap(Self).initComptime(.{
        .{ "Makefile", .Makefile },
    });

    fn parse(basename: []const u8) Self {
        const ext = fs.path.extension(basename);
        if (std.mem.eql(u8, ext, "")) {
            return FilenameLangMap.get(basename) orelse .Other;
        }

        return ExtLangMap.get(ext) orelse .Other;
    }

    fn toString(self: Self) []const u8 {
        return @tagName(self);
    }
};

const Column = enum {
    language,
    file,
    line,
    code,
    comment,
    blank,
    size,
};

const LinesOfCode = struct {
    lang: Language,
    files: usize,
    codes: usize,
    comments: usize,
    blanks: usize,
    size: usize,

    const Self = @This();

    const header = b: {
        const fieldInfos = std.meta.fields(Column);
        var names: [fieldInfos.len]Cell = undefined;
        for (fieldInfos, 0..) |field, i| {
            names[i] = Cell.init([_]u8{std.ascii.toUpper(field.name[0])} ++ field.name[1..]);
        }
        break :b names;
    };
    const LOCTable = Table(Self.header.len);
    const LOCTableData = [Self.header.len]Cell;

    fn merge(self: *Self, other: Self) void {
        self.files += other.files;
        self.codes += other.codes;
        self.comments += other.comments;
        self.blanks += other.blanks;
        self.size += other.size;
    }

    fn lines(self: Self) usize {
        return self.blanks + self.codes + self.comments;
    }

    fn cmp(sort_col: Column, a: *Self, b: *Self) bool {
        return switch (sort_col) {
            .language => std.mem.lessThan(u8, @tagName(a.lang), @tagName(b.lang)),
            .file => a.files > b.files,
            .code => a.codes > b.codes,
            .comment => a.comments > b.comments,
            .blank => a.comments > b.comments,
            .size => a.size > b.size,
            .line => a.lines() > b.lines(),
        };
    }

    fn numToString(n: usize, allocator: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(allocator, "{d}", .{n}) catch unreachable;
    }

    fn toTableData(self: Self, allocator: std.mem.Allocator) Self.LOCTableData {
        return [_]Cell{
            Cell.init(self.lang.toString()),
            Cell.init(Self.numToString(self.files, allocator)),
            Cell.init(Self.numToString(self.codes + self.blanks + self.comments, allocator)),
            Cell.init(Self.numToString(self.codes, allocator)),
            Cell.init(Self.numToString(self.comments, allocator)),
            Cell.init(Self.numToString(self.blanks, allocator)),
            Cell.init(StringUtil.humanSize(allocator, self.size) catch unreachable),
        };
    }
};

const LocMap = std.enums.EnumMap(Language, LinesOfCode);

pub fn main(init: std.process.Init) !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();
    const io = init.io;

    const opt = try structargs.parse(allocator, io, init.minimal.args, struct {
        sort: Column = .line,
        mode: Separator.Mode = .box,
        padding: usize = 3,
        @"no-gitignore": bool = false,
        version: bool = false,
        help: bool = false,

        pub const __shorts__ = .{
            .sort = .s,
            .mode = .m,
            .padding = .p,
            .version = .v,
            .help = .h,
        };

        pub const __messages__ = .{
            .help = "Print help information",
            .mode = "Line drawing characters",
            .padding = "Column padding",
            .@"no-gitignore" = "Do not use .gitignore rules to filter files.",
            .version = "Print version",
            .sort = "Column to sort by",
        };
    }, .{
        .argument_prompt = "[file or directory]",
        .version_string = util.get_build_info(),
    });
    defer opt.deinit();

    const file_or_dir = if (opt.positional_arguments.len == 0)
        "."
    else
        opt.positional_arguments[0];

    var loc_map = LocMap{};
    var dir = Io.Dir.cwd().openDir(io, file_or_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            try populateLoc(io, allocator, &loc_map, Io.Dir.cwd(), file_or_dir);
            return printLocMap(
                io,
                allocator,
                &loc_map,
                opt.options.sort,
                opt.options.mode,
                opt.options.padding,
            );
        },
        else => return err,
    };
    defer dir.close(io);

    var gi_stack = gitignore.GitignoreStack.init();
    defer gi_stack.deinit(allocator);
    if (!opt.options.@"no-gitignore") {
        _ = try gi_stack.tryPushDir(io, dir, "", allocator);
    }

    try walk(io, allocator, opt.options.@"no-gitignore", &gi_stack, &loc_map, dir, "");
    try printLocMap(
        io,
        allocator,
        &loc_map,
        opt.options.sort,
        opt.options.mode,
        opt.options.padding,
    );
}

fn printLocMap(
    io: Io,
    allocator: std.mem.Allocator,
    loc_map: *LocMap,
    sort_col: Column,
    mode: Separator.Mode,
    padding: usize,
) !void {
    // All allocations here are temporary (table strings, sort list).
    // Use a local arena so they are freed together after printing.
    var local_arena = std.heap.ArenaAllocator.init(allocator);
    defer local_arena.deinit();
    const local = local_arena.allocator();

    var iter = loc_map.iterator();
    var list: std.ArrayList(*LinesOfCode) = .empty;

    var total_entry = LinesOfCode{
        .lang = .Total,
        .codes = 0,
        .comments = 0,
        .blanks = 0,
        .files = 0,
        .size = 0,
    };

    while (iter.next()) |entry| {
        try list.append(local, entry.value);
        total_entry.merge(entry.value.*);
    }
    std.sort.heap(*LinesOfCode, list.items, sort_col, LinesOfCode.cmp);

    var table_data: std.ArrayList(LinesOfCode.LOCTableData) = .empty;

    for (list.items) |entry| {
        try table_data.append(local, entry.toTableData(local));
    }
    const table = LinesOfCode.LOCTable{
        .header = LinesOfCode.header,
        .footer = total_entry.toTableData(local),
        .rows = table_data.items,
        .mode = mode,
        .padding = padding,
    };
    const stdout = Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer = stdout.writer(io, &buf);
    try writer.interface.print("{f}\n", .{table});
    try writer.interface.flush();
}

fn walk(
    io: Io,
    /// Long-lived allocator for GitignoreStack patterns.
    allocator: std.mem.Allocator,
    no_gitignore: bool,
    gi_stack: *gitignore.GitignoreStack,
    loc_map: *LocMap,
    dir: Io.Dir,
    rel_dir: []const u8,
) anyerror!void {
    // Per-level arena for temporary strings (rel_path).
    // Freed when this call returns, so memory doesn't accumulate.
    var local_arena = std.heap.ArenaAllocator.init(allocator);
    defer local_arena.deinit();
    const local = local_arena.allocator();

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const rel_path = if (rel_dir.len == 0)
            e.name
        else
            try std.fmt.allocPrint(local, "{s}/{s}", .{ rel_dir, e.name });

        if (gi_stack.shouldIgnore(rel_path, e.kind == .directory)) continue;

        switch (e.kind) {
            .file => {
                try populateLoc(io, allocator, loc_map, dir, e.name);
            },
            .directory => {
                var sub_dir = try dir.openDir(io, e.name, .{ .iterate = true });
                defer sub_dir.close(io);

                // rel_path lives in local arena which is freed on return;
                // dup into long-lived allocator so recursion doesn't see freed memory.
                const rel_path_owned = try allocator.dupe(u8, rel_path);
                defer allocator.free(rel_path_owned);

                const layer_pushed = if (!no_gitignore)
                    try gi_stack.tryPushDir(io, sub_dir, rel_path_owned, allocator)
                else
                    false;
                defer if (layer_pushed) gi_stack.pop(allocator);

                try walk(io, allocator, no_gitignore, gi_stack, loc_map, sub_dir, rel_path_owned);
            },
            else => {},
        }
    }
}

// State used when decide if this line is code,comment or blank
// Two possible transitions:
// 1. Normal: Unknown -> Unknown
// 2. MultipleLineComment: Unknown -> [InMultipleLineComment]? -> Unknown
const State = enum {
    Unknown,
    InMultipleLineComment,
};

fn populateLoc(io: Io, allocator: std.mem.Allocator, loc_map: *LocMap, dir: Io.Dir, basename: []const u8) anyerror!void {
    _ = allocator;
    const lang = Language.parse(basename);
    if (lang == Language.Other) {
        return;
    }

    // Initialize counters lazily because EnumMap does not expose getOrPutValue.
    var loc_entry = loc_map.getPtr(lang) orelse blk: {
        loc_map.put(lang, .{
            .codes = 0,
            .comments = 0,
            .blanks = 0,
            .lang = lang,
            .files = 0,
            .size = 0,
        });
        break :blk loc_map.getPtr(lang).?;
    };
    var file = try dir.openFile(io, basename, .{});
    defer file.close(io);
    loc_entry.files += 1;

    const stat = try file.stat(io);
    const file_size: usize = @truncate(stat.size);
    if (file_size == 0) {
        return;
    }
    loc_entry.size += file_size;

    var state = State.Unknown;
    switch (@import("builtin").os.tag) {
        .windows => {
            var buf: [1024]u8 = undefined;
            var rdr = file.reader(io, &buf);
            while ((rdr.interface.takeDelimiter('\n') catch |e| {
                std.log.err("Error when seek line delimiter, name:{s}, err:{any}", .{ basename, e });
                return e;
            })) |line| {
                state = updateLineType(state, line, lang, loc_entry);
            }
        },
        else => {
            const mapped = try std.posix.mmap(
                null,
                file_size,
                .{ .READ = true },
                .{ .TYPE = .PRIVATE },
                file.handle,
                0,
            );
            defer std.posix.munmap(mapped);

            var offset_so_far: usize = 0;
            while (offset_so_far < mapped.len) {
                var line_end = offset_so_far;
                while (line_end < mapped.len and mapped[line_end] != '\n') {
                    line_end += 1;
                }
                const line = mapped[offset_so_far..line_end];
                offset_so_far = if (line_end < mapped.len) line_end + 1 else line_end;

                state = updateLineType(state, line, lang, loc_entry);
            }
        },
    }
}

fn updateLineType(
    state: State,
    raw_line: []const u8,
    lang: Language,
    loc_entry: *LinesOfCode,
) State {
    const line = trimWhitespace(raw_line);
    if (line == null) {
        loc_entry.blanks += 1;
        // state not change
        return state;
    }

    return switch (state) {
        .Unknown => blk: {
            if (lang.commentChars()) |chars| {
                if (std.mem.startsWith(u8, line.?, chars)) {
                    loc_entry.comments += 1;
                    break :blk .Unknown;
                }
            }

            if (lang.multiLineCommentBeginChars()) |chars| {
                if (std.mem.startsWith(u8, line.?, chars)) {
                    loc_entry.comments += 1;
                    const end_chars = lang.multiLineCommentEndChars();
                    if (std.mem.endsWith(u8, line.?, end_chars)) {
                        break :blk .Unknown;
                    }

                    break :blk .InMultipleLineComment;
                }
            }

            loc_entry.codes += 1;
            break :blk .Unknown;
        },
        .InMultipleLineComment => blk: {
            loc_entry.comments += 1;
            const end_chars = lang.multiLineCommentEndChars();
            if (std.mem.endsWith(u8, line.?, end_chars)) {
                break :blk .Unknown;
            }
            break :blk .InMultipleLineComment;
        },
    };
}

fn isWhitespace(c: u8) bool {
    for (std.ascii.whitespace) |space| {
        if (space == c) {
            return true;
        }
    }
    return false;
}

fn trimWhitespace(line: []const u8) ?[]const u8 {
    if (line.len == 0) {
        return null;
    }

    var start_idx: usize = 0;
    var end_idx: usize = line.len - 1;
    while (start_idx <= end_idx) {
        if (!isWhitespace(line[start_idx])) {
            break;
        }
        start_idx += 1;
    }
    while (end_idx >= start_idx) {
        if (!isWhitespace(line[end_idx])) {
            break;
        }
        end_idx -= 1;
    }

    return if (start_idx > end_idx)
        null
    else
        return line[start_idx .. end_idx + 1];
}

test "trimWhitespace" {
    try std.testing.expect(null == trimWhitespace(""));
    try std.testing.expect(null == trimWhitespace(" "));
    try std.testing.expect(null == trimWhitespace("  "));
    try std.testing.expectEqualStrings("a", trimWhitespace("a").?);
    try std.testing.expectEqualStrings("a", trimWhitespace("a  ").?);
    try std.testing.expectEqualStrings("a", trimWhitespace("   a").?);
    try std.testing.expectEqualStrings("a", trimWhitespace("  a  ").?);
}

test "LOC Zig/Python/Ruby" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var loc_map = LocMap{};
    const dir = Io.Dir.cwd();

    const testcases = .{
        .{
            "tests/test.zig",
            .{
                .lang = Language.Zig,
                .files = 1,
                .codes = 34,
                .comments = 2,
                .blanks = 8,
                .size = 1203,
            },
        },
        .{
            "tests/test.py",
            .{
                .lang = Language.Python,
                .files = 1,
                .codes = 7,
                .comments = 2,
                .blanks = 1,
                .size = 166,
            },
        },
        .{
            "tests/test.rb",
            .{
                .lang = Language.Ruby,
                .files = 1,
                .codes = 5,
                .comments = 2,
                .blanks = 1,
                .size = 201,
            },
        },
        .{
            "tests/test.c",
            .{
                .lang = Language.C,
                .files = 1,
                .codes = 2,
                .comments = 4,
                .blanks = 3,
                .size = 34,
            },
        },
    };

    inline for (testcases) |case| {
        const basename = case.@"0";
        const expected = case.@"1";
        const lang = expected.lang;

        try std.testing.expectEqual(Language.parse(basename), lang);

        try populateLoc(io, allocator, &loc_map, dir, basename);
        var loc = loc_map.get(lang).?;
        // On windows, newline will be \r\n, so size is different
        // Zig file stays the same since it's special taken care of in .gitattributes
        if (.windows == @import("builtin").os.tag) {
            if (lang != .Zig) {
                loc.size = expected.size;
            }
        }
        inline for (std.meta.fields(@TypeOf(expected))) |field| {
            try std.testing.expectEqual(
                @field(loc, field.name),
                @field(expected, field.name),
            );
        }
    }
}
