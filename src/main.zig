const std = @import("std");
const Table = @import("table-helper").Table;
const fs = std.fs;

const MAX_COLUMNS: usize = 4096;
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
    TS,
    Other,

    const Self = @This();

    fn commentChars(self: Self) []const u8 {
        return switch (self) {
            Self.Bash, Self.Python, Self.Ruby, Self.Makefile, Self.YAML, Self.TOML => "#",
            // TODO: multiple line comment not supported
            Self.Markdown, Self.HTML => "<!--",
            else => "//",
        };
    }

    const ExtLangMap = std.ComptimeStringMap(Self, .{
        .{ ".zig", Self.Zig },
        .{ ".c", Self.C },
        .{ ".h", Self.C },
        .{ ".go", Self.Go },
        .{ ".rs", Self.Rust },
        .{ ".sh", Self.Bash },
        .{ ".py", Self.Python },
        .{ ".rb", Self.Ruby },
        .{ ".js", Self.JavaScript },
        .{ ".java", Self.Java },
        .{ ".md", Self.Markdown },
        .{ ".markdown", Self.Markdown },
        .{ ".html", Self.HTML },
        .{ ".yml", Self.YAML },
        .{ ".yaml", Self.YAML },
        .{ ".toml", Self.YAML },
        .{ ".json", Self.JSON },
        .{ ".ts", Self.TS },
    });
    const FilenameLangMap = std.ComptimeStringMap(Self, .{
        .{ "Makefile", Self.Makefile },
    });

    fn parse(basename: []const u8) Self {
        const ext = fs.path.extension(basename);
        if (std.mem.eql(u8, ext, "")) {
            return FilenameLangMap.get(basename) orelse Self.Other;
        }

        return ExtLangMap.get(ext) orelse Self.Other;
    }

    fn toString(self: Self) []const u8 {
        return switch (self) {
            Self.Zig => "Zig",
            Self.C => "C",
            Self.Go => "Go",
            Self.Rust => "Rust",
            Self.Bash => "Bash",
            Self.Python => "Python",
            Self.Ruby => "Ruby",
            Self.JavaScript => "JavaScript",
            Self.Java => "Java",
            Self.Makefile => "Makefile",
            Self.Markdown => "Markdown",
            Self.HTML => "HTML",
            Self.YAML => "YAML",
            Self.TOML => "TOML",
            Self.JSON => "JSON",
            Self.TS => "TypeScript",
            Self.Other => "Other",
        };
    }
};

const LinesOfCode = struct {
    lang: Language,
    files: usize,
    codes: usize,
    comments: usize,
    blanks: usize,

    const Self = @This();

    const header = [_][]const u8{ "Language", "Files", "Lines", "Code", "Comment", "Blank" };
    const LOCTable = Table(&Self.header);
    const LOCTableData = [Self.header.len][]const u8;

    fn cmp(context: void, a: *Self, b: *Self) bool {
        _ = context;
        return a.blanks + a.codes + a.comments > b.blanks + b.codes + b.comments;
    }

    fn numToString(n: usize, allocator: std.mem.Allocator) []const u8 {
        var buf = allocator.alloc(u8, 10) catch unreachable;
        return std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable;
    }

    fn toTableData(self: Self, allocator: std.mem.Allocator) Self.LOCTableData {
        return [_][]const u8{
            self.lang.toString(),
            Self.numToString(self.files, allocator),
            Self.numToString(self.codes + self.blanks + self.comments, allocator),
            Self.numToString(self.codes, allocator),
            Self.numToString(self.comments, allocator),
            Self.numToString(self.blanks, allocator),
        };
    }
};

const LocMap = std.AutoHashMap(Language, LinesOfCode);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next();
    const file_or_dir = args.next() orelse ".";
    var loc_map = LocMap.init(allocator);
    var iter_dir =
        fs.cwd().openIterableDir(file_or_dir, .{}) catch |err| switch (err) {
        error.NotDir => return loc(allocator, &loc_map, fs.cwd(), file_or_dir),
        else => return err,
    };
    defer iter_dir.close();

    try walk(allocator, &loc_map, iter_dir);
    try printLocMap(allocator, loc_map);
}

fn printLocMap(allocator: std.mem.Allocator, loc_map: LocMap) !void {
    var iter = loc_map.iterator();
    var table_data = std.ArrayList(LinesOfCode.LOCTableData).init(allocator);
    var list = std.ArrayList(*LinesOfCode).init(allocator);
    while (iter.next()) |entry| {
        try list.append(entry.value_ptr);
    }

    std.sort.sort(*LinesOfCode, list.items, {}, LinesOfCode.cmp);
    for (list.items) |entry| {
        try table_data.append(entry.toTableData(allocator));
    }
    const table = LinesOfCode.LOCTable{ .data = table_data.items };
    try std.io.getStdOut().writer().print("{}\n", .{table});
}

fn walk(allocator: std.mem.Allocator, loc_map: *LocMap, dir: fs.IterableDir) anyerror!void {
    var it = dir.iterate();
    while (try it.next()) |e| {
        switch (e.kind) {
            fs.File.Kind.File => {
                std.log.debug("loc file:{s}", .{e.name});
                try loc(allocator, loc_map, dir.dir, e.name);
            },
            fs.File.Kind.Directory => {
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
    const lang = Language.parse(basename);
    if (lang == Language.Other) {
        return;
    }

    var loc_entry = try loc_map.getOrPutValue(lang, .{
        .codes = 0,
        .comments = 0,
        .blanks = 0,
        .lang = lang,
        .files = 0,
    });

    var file = try dir.openFile(basename, .{});
    defer file.close();
    // After replace file.reader with buffered reader,
    // sys time dropped from 0m1.944s to 0m0.055s
    // var reader = file.reader();
    var buf = std.io.bufferedReader(file.reader());
    var reader = buf.reader();

    while (true) {
        var line = reader.readUntilDelimiterAlloc(allocator, '\n', MAX_COLUMNS) catch |err| switch (err) {
            error.StreamTooLong => {
                std.log.debug("skip file, line too long. {s}", .{basename});
                return;
            },
            error.EndOfStream => {
                // only increment file when iterate file over.
                loc_entry.value_ptr.files += 1;
                break;
            },
            else => return err,
        };
        defer allocator.free(line);

        var non_blank_idx: ?usize = null;
        for (line) |c, idx| {
            var is_blank = false;
            for (std.ascii.spaces) |space| {
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
            if (std.mem.startsWith(u8, line[idx..], lang.commentChars())) {
                loc_entry.value_ptr.comments += 1;
            } else {
                loc_entry.value_ptr.codes += 1;
            }
        } else loc_entry.value_ptr.blanks += 1;
    }
}

test "LOC Zig/Python/Ruby" {
    const allocator = std.testing.allocator;
    var loc_map = LocMap.init(allocator);
    defer loc_map.deinit();
    var dir = fs.cwd();

    const testcases = .{
        .{
            "tests/test.zig", .{
                .lang = Language.Zig,
                .files = 1,
                .codes = 34,
                .comments = 2,
                .blanks = 8,
            },
        },
        .{
            "tests/test.py", .{
                .lang = Language.Python,
                .files = 1,
                .codes = 113,
                .comments = 4,
                .blanks = 17,
            },
        },
        .{
            "tests/test.rb", .{
                .lang = Language.Ruby,
                .files = 1,
                .codes = 116,
                .comments = 8,
                .blanks = 30,
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
