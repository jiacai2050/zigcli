const std = @import("std");
const Table = @import("table-helper").Table;
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

    fn commentChars(self: Self) []const u8 {
        return switch (self) {
            .Bash, .Python, .Ruby, .Makefile, .YAML, .TOML => "#",
            // TODO: multiple line comment not supported
            .Markdown, .HTML => "<!--",
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

const LinesOfCode = struct {
    lang: Language,
    files: usize,
    codes: usize,
    comments: usize,
    blanks: usize,
    size: usize,

    const Self = @This();

    const SIZE_UNIT = [_][]const u8{ "B", "K", "M", "G", "T" };
    const header = [_][]const u8{ "Language", "Files", "Lines", "Code", "Comment", "Blank", "Size" };
    const LOCTable = Table(&Self.header);
    const LOCTableData = [Self.header.len][]const u8;

    fn merge(self: *Self, other: Self) void {
        self.files += other.files;
        self.codes += other.codes;
        self.comments += other.comments;
        self.blanks += other.blanks;
        self.size += other.size;
    }

    fn cmp(context: void, a: *Self, b: *Self) bool {
        _ = context;
        return a.blanks + a.codes + a.comments > b.blanks + b.codes + b.comments;
    }

    fn numToString(n: usize, allocator: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(allocator, "{d}", .{n}) catch unreachable;
    }

    fn sizeToString(n: u64, allocator: std.mem.Allocator) []const u8 {
        var remaining = @intToFloat(f64, n);
        var i: usize = 0;
        while (remaining > 1024) {
            remaining /= 1024;
            i += 1;
        }
        return std.fmt.allocPrint(allocator, "{d:.2}{s}", .{ remaining, SIZE_UNIT[i] }) catch unreachable;
    }

    fn toTableData(self: Self, allocator: std.mem.Allocator) Self.LOCTableData {
        return [_][]const u8{
            self.lang.toString(),
            Self.numToString(self.files, allocator),
            Self.numToString(self.codes + self.blanks + self.comments, allocator),
            Self.numToString(self.codes, allocator),
            Self.numToString(self.comments, allocator),
            Self.numToString(self.blanks, allocator),
            Self.sizeToString(self.size, allocator),
        };
    }
};

const LocMap = std.enums.EnumMap(Language, LinesOfCode);

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.next();
    const file_or_dir = args.next() orelse ".";
    var loc_map = LocMap{};
    var iter_dir =
        fs.cwd().openIterableDir(file_or_dir, .{}) catch |err| switch (err) {
        error.NotDir => return loc(allocator, &loc_map, fs.cwd(), file_or_dir),
        else => return err,
    };
    defer iter_dir.close();

    try walk(allocator, &loc_map, iter_dir);
    try printLocMap(allocator, &loc_map);
}

fn printLocMap(allocator: std.mem.Allocator, loc_map: *LocMap) !void {
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
    std.sort.sort(*LinesOfCode, list.items, {}, LinesOfCode.cmp);

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
        break :blk loc_map.getPtr(lang) orelse unreachable;
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
    while (offset_so_far < ptr.len) {
        var line_end = offset_so_far;
        while (line_end < ptr.len and ptr[line_end] != '\n') {
            line_end += 1;
        }
        const line = ptr[offset_so_far..line_end];
        offset_so_far = line_end + 1;

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
                loc_entry.comments += 1;
            } else {
                loc_entry.codes += 1;
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
