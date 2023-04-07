const std = @import("std");
const Table = @import("table-helper").Table;
const simargs = @import("simargs");
const StringUtil = @import("util.zig").StringUtil;
const fs = std.fs;

const IGNORE_DIRS = [_][]const u8{ ".git", "zig-cache", "zig-out", "target", "vendor", "node_modules", "out" };

const Language = enum {
    Zig,
    C,
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
            .C => "/*",
            else => null,
        };
    }

    fn multiLineCommentEndChars(self: Self) []const u8 {
        return switch (self) {
            .Markdown, .HTML => "--!>",
            .C => "*/",
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
        .{ ".h", .C },
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
        .{ ".toml", .YAML },
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
    const LOCTable = Table(&Self.header);
    const LOCTableData = [Self.header.len][]const u8;

    fn merge(self: *Self, other: Self) void {
        self.files += other.files;
        self.codes += other.codes;
        self.comments += other.comments;
        self.blanks += other.blanks;
        self.size += other.size;
    }

    fn cmp(sort_col: Column, a: *Self, b: *Self) bool {
        return switch (sort_col) {
            .language => std.mem.lessThan(u8, @tagName(a.lang), @tagName(b.lang)),
            .file => a.files > b.files,
            .code => a.codes > b.codes,
            .comment => a.comments > b.comments,
            .blank => a.comments > b.comments,
            .size => a.size > b.size,
            .line => a.blanks + a.codes + a.comments > b.blanks + b.codes + b.comments,
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
        help: bool = false,

        pub const __shorts__ = .{
            .sort = .s,
            .help = .h,
        };

        pub const __messages__ = .{ .help = "Prints help information", .sort = "Column to sort by" };
    });
    defer opt.deinit();

    if (opt.args.help) {
        const stdout = std.io.getStdOut();
        try opt.print_help(stdout.writer(), "[file or directory]");
        return;
    }

    const file_or_dir = if (opt.positional_args.items.len == 0)
        "."
    else
        opt.positional_args.items[0];

    var loc_map = LocMap{};
    var iter_dir =
        fs.cwd().openIterableDir(file_or_dir, .{}) catch |err| switch (err) {
        error.NotDir => return loc(allocator, &loc_map, fs.cwd(), file_or_dir),
        else => return err,
    };
    defer iter_dir.close();

    try walk(allocator, &loc_map, iter_dir);
    try printLocMap(allocator, &loc_map, opt.args.sort);
}

fn printLocMap(allocator: std.mem.Allocator, loc_map: *LocMap, sort_col: Column) !void {
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
    std.sort.sort(*LinesOfCode, list.items, sort_col, LinesOfCode.cmp);

    var table_data = std.ArrayList(LinesOfCode.LOCTableData).init(allocator);
    for (list.items) |entry| {
        try table_data.append(entry.toTableData(allocator));
    }
    const table = LinesOfCode.LOCTable{
        .data = table_data.items,
        .footer = total_entry.toTableData(allocator),
    };
    try std.io.getStdOut().writer().print("{}\n", .{table});
}

fn walk(allocator: std.mem.Allocator, loc_map: *LocMap, dir: fs.IterableDir) anyerror!void {
    var it = dir.iterate();
    while (try it.next()) |e| {
        switch (e.kind) {
            .File => {
                std.log.debug("loc file:{s}", .{e.name});
                try loc(allocator, loc_map, dir.dir, e.name);
            },
            .Directory => {
                var should_ignore = false;
                for (IGNORE_DIRS) |ignore| {
                    if (std.mem.eql(u8, ignore, e.name)) {
                        should_ignore = true;
                        break;
                    }
                }
                if (!should_ignore) {
                    var child_dir = try dir.dir.openIterableDir(e.name, .{});
                    defer child_dir.close();
                    try walk(allocator, loc_map, child_dir);
                }
            },
            else => {},
        }
    }
}

fn loc(allocator: std.mem.Allocator, loc_map: *LocMap, dir: fs.Dir, basename: []const u8) anyerror!void {
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
    const file_size = @truncate(usize, metadata.size());
    if (file_size == 0) {
        return;
    }
    loc_entry.size += file_size;

    var ptr = try std.os.mmap(null, file_size, std.os.PROT.READ, std.os.MAP.PRIVATE, file.handle, 0);
    defer std.os.munmap(ptr);

    var offset_so_far: usize = 0;
    var in_mutli_line_comments = false;
    while (offset_so_far < ptr.len) {
        var line_end = offset_so_far;
        while (line_end < ptr.len and ptr[line_end] != '\n') {
            line_end += 1;
        }
        const line = ptr[offset_so_far..line_end];
        offset_so_far = line_end + 1;

        var non_blank_idx: ?usize = null;
        for (line, 0..) |c, idx| {
            var is_blank = false;
            for (std.ascii.whitespace) |space| {
                if (space == c) {
                    is_blank = true;
                    break;
                }
            }
            if (!is_blank) {
                non_blank_idx = idx;
                break;
            }
        }

        if (non_blank_idx) |idx| {
            if (!in_mutli_line_comments) {
                if (lang.multiLineCommentBeginChars()) |begin_chars| {
                    in_mutli_line_comments = std.mem.startsWith(u8, line[idx..], begin_chars);
                }
            }

            if (in_mutli_line_comments) {
                loc_entry.comments += 1;
                in_mutli_line_comments = !std.mem.endsWith(u8, line[idx..], lang.multiLineCommentEndChars());
            } else {
                if (lang.commentChars()) |begin_chars| {
                    if (std.mem.startsWith(u8, line[idx..], begin_chars)) {
                        loc_entry.comments += 1;
                    }
                } else {
                    loc_entry.codes += 1;
                }
            }
        } else loc_entry.blanks += 1;
    }
}

test "LOC Zig/Python/Ruby" {
    const allocator = std.testing.allocator;
    var loc_map = LocMap{};
    var dir = fs.cwd();

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
    };

    inline for (testcases) |case| {
        const basename = case.@"0";
        const expected = case.@"1";
        const lang = expected.lang;

        try std.testing.expectEqual(Language.parse(basename), lang);

        try loc(allocator, &loc_map, dir, basename);
        const zig_codes = loc_map.get(lang).?;
        try std.testing.expectEqual(zig_codes, expected);
    }
}
