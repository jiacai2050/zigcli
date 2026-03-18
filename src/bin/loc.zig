const std = @import("std");
const Table = @import("pretty-table").Table;
const Cell = @import("pretty-table").Cell;
const Separator = @import("pretty-table").Separator;
const simargs = @import("simargs");
const util = @import("util.zig");
const gitignore = @import("gitignore");
const StringUtil = util.StringUtil;
const fs = std.fs;

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

/// A source file found during directory walking, to be processed in parallel.
const FileEntry = struct {
    /// Path relative to the root directory being scanned.
    rel_path: []const u8,
    /// Language determined from the file name.
    lang: Language,
};

/// Shared mutable state for parallel file processing.
const ProcessState = struct {
    root_dir: fs.Dir,
    loc_map: LocMap = .{},
    mutex: std.Thread.Mutex = .{},
};

/// Thread-pool task: process one file and merge its counts into the shared map.
fn processFileTask(state: *ProcessState, entry: FileEntry) void {
    var local_map: LocMap = .{};
    populateLoc(&local_map, state.root_dir, entry.rel_path, entry.lang) catch |err| {
        std.log.err("Failed to process {s}: {}", .{ entry.rel_path, err });
        return;
    };
    state.mutex.lock();
    defer state.mutex.unlock();
    mergeLocMaps(&state.loc_map, &local_map);
}

/// Merge all entries from src into dst.
fn mergeLocMaps(dst: *LocMap, src: *LocMap) void {
    var it = src.iterator();
    while (it.next()) |src_entry| {
        if (dst.getPtr(src_entry.key)) |dst_entry| {
            dst_entry.merge(src_entry.value.*);
        } else {
            dst.put(src_entry.key, src_entry.value.*);
        }
    }
}

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try simargs.parse(allocator, struct {
        sort: Column = .line,
        mode: Separator.Mode = .box,
        padding: usize = 3,
        @"no-gitignore": bool = false,
        jobs: ?usize = null,
        version: bool = false,
        help: bool = false,

        pub const __shorts__ = .{
            .sort = .s,
            .mode = .m,
            .padding = .p,
            .jobs = .j,
            .version = .v,
            .help = .h,
        };

        pub const __messages__ = .{
            .help = "Print help information",
            .mode = "Line drawing characters",
            .padding = "Column padding",
            .@"no-gitignore" = "Do not use .gitignore rules to filter files.",
            .jobs = "Number of parallel threads (default: number of CPUs)",
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

    var root_dir = fs.cwd().openDir(file_or_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            var loc_map = LocMap{};
            const lang = Language.parse(fs.path.basename(file_or_dir));
            if (lang != .Other) {
                try populateLoc(&loc_map, fs.cwd(), file_or_dir, lang);
            }
            return printLocMap(
                allocator,
                &loc_map,
                opt.options.sort,
                opt.options.mode,
                opt.options.padding,
            );
        },
        else => return err,
    };
    defer root_dir.close();

    var gi_stack = gitignore.GitignoreStack.init();
    defer gi_stack.deinit(allocator);
    if (!opt.options.@"no-gitignore") {
        _ = try gi_stack.tryPushDir(root_dir, "", allocator);
    }

    // Collect all files to process.
    var file_entries: std.ArrayList(FileEntry) = .empty;
    defer {
        for (file_entries.items) |entry| allocator.free(entry.rel_path);
        file_entries.deinit(allocator);
    }
    try collectFiles(allocator, opt.options.@"no-gitignore", &gi_stack, &file_entries, root_dir, "");

    // Process all files in parallel using a thread pool.
    var process_state = ProcessState{ .root_dir = root_dir };
    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{
        .allocator = allocator,
        .n_jobs = opt.options.jobs,
    });
    defer thread_pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    for (file_entries.items) |entry| {
        thread_pool.spawnWg(&wg, processFileTask, .{ &process_state, entry });
    }
    thread_pool.waitAndWork(&wg);

    try printLocMap(
        allocator,
        &process_state.loc_map,
        opt.options.sort,
        opt.options.mode,
        opt.options.padding,
    );
}

fn printLocMap(
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
    const stdout = std.fs.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer = stdout.writer(&buf);
    try writer.interface.print("{f}\n", .{table});
    try writer.interface.flush();
}

/// Walk the directory tree and collect all processable file entries into files.
/// The allocator is used for path strings and the ArrayList backing store;
/// callers typically pass an arena allocator so everything can be freed at once.
fn collectFiles(
    allocator: std.mem.Allocator,
    no_gitignore: bool,
    gi_stack: *gitignore.GitignoreStack,
    files: *std.ArrayList(FileEntry),
    dir: fs.Dir,
    rel_dir: []const u8,
) anyerror!void {
    // Per-level arena for temporary rel_path strings.
    // Freed when this call returns so memory does not accumulate across levels.
    var local_arena = std.heap.ArenaAllocator.init(allocator);
    defer local_arena.deinit();
    const local = local_arena.allocator();

    var it = dir.iterate();
    while (try it.next()) |e| {
        const rel_path = if (rel_dir.len == 0)
            e.name
        else
            try std.fmt.allocPrint(local, "{s}/{s}", .{ rel_dir, e.name });

        if (gi_stack.shouldIgnore(rel_path, e.kind == .directory)) continue;

        switch (e.kind) {
            .file => {
                const lang = Language.parse(e.name);
                if (lang == .Other) continue;
                // Duplicate the path so it outlives the local arena.
                const path_copy = try allocator.dupe(u8, rel_path);
                try files.append(allocator, .{ .rel_path = path_copy, .lang = lang });
            },
            .directory => {
                var sub_dir = try dir.openDir(e.name, .{ .iterate = true });
                defer sub_dir.close();

                const layer_pushed = if (!no_gitignore)
                    try gi_stack.tryPushDir(sub_dir, rel_path, allocator)
                else
                    false;
                defer if (layer_pushed) gi_stack.pop(allocator);

                try collectFiles(allocator, no_gitignore, gi_stack, files, sub_dir, rel_path);
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

fn populateLoc(loc_map: *LocMap, dir: fs.Dir, rel_path: []const u8, lang: Language) anyerror!void {
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
    var file = try dir.openFile(rel_path, .{});
    defer file.close();
    loc_entry.files += 1;

    const stat = try file.stat();
    const file_size: usize = @truncate(stat.size);
    if (file_size == 0) {
        return;
    }
    loc_entry.size += file_size;

    var state = State.Unknown;
    // Use buffered read() instead of mmap to avoid TLB shootdown overhead when
    // multiple worker threads process files in parallel.  Each mmap/munmap
    // requires inter-CPU TLB invalidation (IPI) on every core, which serialises
    // all threads.  A plain read() into a private stack buffer has no such cost.
    var buf: [4096]u8 = undefined;
    var rdr = file.reader(&buf);
    while (true) {
        const line_result = rdr.interface.takeDelimiterExclusive('\n');
        if (line_result) |line| {
            state = updateLineType(state, line, lang, loc_entry);
        } else |e| switch (e) {
            error.EndOfStream => return,
            // Line exceeds buffer — classify conservatively as code and skip
            // to the next newline so processing continues for the rest of the file.
            error.StreamTooLong => {
                loc_entry.codes += 1;
                _ = rdr.interface.discardDelimiterInclusive('\n') catch return;
            },
            else => {
                std.log.err("Error reading file {s}: {any}", .{ rel_path, e });
                return e;
            },
        }
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

fn trimWhitespace(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
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

        try populateLoc(&loc_map, dir, basename, lang);
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
