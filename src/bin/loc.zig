const std = @import("std");
const Table = @import("pretty-table").Table;
const Separator = @import("pretty-table").Separator;
const simargs = @import("simargs");
const util = @import("util.zig");
const StringUtil = util.StringUtil;
const fs = std.fs;

const IGNORE_DIRS = [_][]const u8{ ".git", "zig-cache", "zig-out", "target", "vendor", "node_modules", "out" };

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

    const ExtLangMap = std.ComptimeStringMap(Self, .{
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
    });
    const FilenameLangMap = std.ComptimeStringMap(Self, .{
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
        var names: [fieldInfos.len][]const u8 = undefined;
        for (fieldInfos, 0..) |field, i| {
            names[i] = [_]u8{std.ascii.toUpper(field.name[0])} ++ field.name[1..];
        }
        break :b names;
    };
    const LOCTable = Table(Self.header.len);
    const LOCTableData = [Self.header.len][]const u8;

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
        return [_][]const u8{
            self.lang.toString(),
            Self.numToString(self.files, allocator),
            Self.numToString(self.codes + self.blanks + self.comments, allocator),
            Self.numToString(self.codes, allocator),
            Self.numToString(self.comments, allocator),
            Self.numToString(self.blanks, allocator),
            StringUtil.humanSize(allocator, self.size) catch unreachable,
        };
    }
};

const LocMap = std.enums.EnumMap(Language, LinesOfCode);

pub const std_options = struct {
    pub const log_level: std.log.Level = .info;
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const opt = try simargs.parse(allocator, struct {
        sort: Column = .line,
        mode: Separator.Mode = .box,
        padding: usize = 3,
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
            .version = "Print version",
            .sort = "Column to sort by",
        };
    }, "[file or directory]", util.get_build_info());
    defer opt.deinit();

    const file_or_dir = if (opt.positional_args.items.len == 0)
        "."
    else
        opt.positional_args.items[0];

    var loc_map = LocMap{};
    const dir = fs.cwd().openDir(file_or_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            try populateLoc(allocator, &loc_map, fs.cwd(), file_or_dir);
            return printLocMap(
                allocator,
                &loc_map,
                opt.args.sort,
                opt.args.mode,
                opt.args.padding,
            );
        },
        else => return err,
    };
    try walk(allocator, &loc_map, dir);
    try printLocMap(
        allocator,
        &loc_map,
        opt.args.sort,
        opt.args.mode,
        opt.args.padding,
    );
}

fn printLocMap(
    allocator: std.mem.Allocator,
    loc_map: *LocMap,
    sort_col: Column,
    mode: Separator.Mode,
    padding: usize,
) !void {
    var iter = loc_map.iterator();
    var list = std.ArrayList(*LinesOfCode).init(allocator);
    var total_entry = LinesOfCode{
        .lang = .Total,
        .codes = 0,
        .comments = 0,
        .blanks = 0,
        .files = 0,
        .size = 0,
    };

    while (iter.next()) |entry| {
        try list.append(entry.value);
        total_entry.merge(entry.value.*);
    }
    std.sort.heap(*LinesOfCode, list.items, sort_col, LinesOfCode.cmp);

    var table_data = std.ArrayList(LinesOfCode.LOCTableData).init(allocator);
    for (list.items) |entry| {
        try table_data.append(entry.toTableData(allocator));
    }
    const table = LinesOfCode.LOCTable{
        .header = LinesOfCode.header,
        .footer = total_entry.toTableData(allocator),
        .rows = table_data.items,
        .mode = mode,
        .padding = padding,
    };
    try std.io.getStdOut().writer().print("{}\n", .{table});
}

fn walk(allocator: std.mem.Allocator, loc_map: *LocMap, dir: fs.Dir) anyerror!void {
    var it = dir.iterate();
    while (try it.next()) |e| {
        switch (e.kind) {
            .file => {
                try populateLoc(allocator, loc_map, dir, e.name);
            },
            .directory => {
                var should_ignore = false;
                for (IGNORE_DIRS) |ignore| {
                    if (std.mem.eql(u8, ignore, e.name)) {
                        should_ignore = true;
                        break;
                    }
                }
                if (!should_ignore) {
                    const sub_dir = try dir.openDir(e.name, .{ .iterate = true });
                    try walk(allocator, loc_map, sub_dir);
                }
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

fn populateLoc(allocator: std.mem.Allocator, loc_map: *LocMap, dir: fs.Dir, basename: []const u8) anyerror!void {
    _ = allocator;
    const lang = Language.parse(basename);
    if (lang == Language.Other) {
        return;
    }

    // Why no `getOrPutValue` in EnumMap?
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
    var file = try dir.openFile(basename, .{});
    defer file.close();
    loc_entry.files += 1;

    const metadata = try file.metadata();
    const file_size: usize = @truncate(metadata.size());
    if (file_size == 0) {
        return;
    }
    loc_entry.size += file_size;

    var state = State.Unknown;
    switch (@import("builtin").os.tag) {
        .windows => {
            const rdr = file.reader();
            var buf: [1024]u8 = undefined;
            while (rdr.readUntilDelimiterOrEof(&buf, '\n') catch |e| {
                std.log.err("File contains too long lines, name:{s}, err:{any}", .{ basename, e });
                return;
            }) |line| {
                state = updateLineType(state, line, lang, loc_entry);
            }
        },
        else => {
            var ptr = try std.os.mmap(null, file_size, std.os.PROT.READ, std.os.MAP.PRIVATE, file.handle, 0);
            defer std.os.munmap(ptr);

            var offset_so_far: usize = 0;
            while (offset_so_far < ptr.len) {
                var line_end = offset_so_far;
                while (line_end < ptr.len and ptr[line_end] != '\n') {
                    line_end += 1;
                }
                const line = ptr[offset_so_far..line_end];
                offset_so_far = line_end + 1;

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
    var loc_map = LocMap{};
    const dir = fs.cwd();

    const testcases = .{
        .{
            "tests/test.zig", .{
                .lang = Language.Zig,
                .files = 1,
                .codes = 34,
                .comments = 2,
                .blanks = 8,
                .size = 1203,
            },
        },
        .{
            "tests/test.py", .{
                .lang = Language.Python,
                .files = 1,
                .codes = 7,
                .comments = 2,
                .blanks = 1,
                .size = 166,
            },
        },
        .{
            "tests/test.rb", .{
                .lang = Language.Ruby,
                .files = 1,
                .codes = 5,
                .comments = 2,
                .blanks = 1,
                .size = 201,
            },
        },
        .{
            "tests/test.c", .{
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

        try populateLoc(allocator, &loc_map, dir, basename);
        var loc = loc_map.get(lang).?;
        // On windows, newline will be \r\n, so size is different
        // Zig file stays the same since it's special taken care of in .gitattributes
        if (.windows == @import("builtin").os.tag) {
            if (lang != .Zig) {
                loc.size = expected.size;
            }
        }
        try std.testing.expectEqual(loc, expected);
    }
}
