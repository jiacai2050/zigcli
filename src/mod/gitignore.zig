/// A module for parsing and matching .gitignore patterns.
/// This implementation follows the Git documentation for .gitignore patterns:
/// https://git-scm.com/docs/gitignore
const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayList;
const fs = std.fs;
const testing = std.testing;

const PatternError = error{
    InvalidPattern,
};

/// Matches a glob pattern against text. Supports:
/// - `*` matches any sequence of chars except `/`
/// - `?` matches any single char except `/`
/// - `[abc]`, `[a-z]`, `[!abc]`, `[^abc]` character classes
/// - `\x` escape next character (literal match)
fn globMatch(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    // For backtracking on `*`
    var star_pi: usize = 0;
    var star_ti: usize = 0;
    var has_star = false;

    while (ti < text.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];
            switch (pc) {
                '\\' => {
                    // Escaped character: match literally
                    if (pi + 1 < pattern.len and ti < text.len) {
                        if (pattern[pi + 1] == text[ti]) {
                            pi += 2;
                            ti += 1;
                            continue;
                        }
                    }
                },
                '?' => {
                    if (ti < text.len and text[ti] != '/') {
                        pi += 1;
                        ti += 1;
                        continue;
                    }
                },
                '*' => {
                    // Record star position for backtracking
                    star_pi = pi + 1;
                    star_ti = ti;
                    has_star = true;
                    pi += 1;
                    continue;
                },
                '[' => {
                    if (ti < text.len and text[ti] != '/') {
                        if (matchCharClass(pattern, pi, text[ti])) |new_pi| {
                            pi = new_pi;
                            ti += 1;
                            continue;
                        }
                    }
                },
                else => {
                    if (ti < text.len and pc == text[ti]) {
                        pi += 1;
                        ti += 1;
                        continue;
                    }
                },
            }
        }

        // Current position didn't match — try backtracking to last `*`
        if (has_star and star_ti < text.len) {
            // `*` must not match `/`
            if (text[star_ti] == '/') {
                return false;
            }
            star_ti += 1;
            pi = star_pi;
            ti = star_ti;
            continue;
        }

        return false;
    }

    return true;
}

/// Try to match a character class at pattern[pi] (which is '[').
/// Returns the new pattern index past the ']' on match, or null on no match.
fn matchCharClass(pattern: []const u8, start_pi: usize, ch: u8) ?usize {
    var pi = start_pi + 1; // skip '['
    if (pi >= pattern.len) return null;

    var negate = false;
    if (pattern[pi] == '!' or pattern[pi] == '^') {
        negate = true;
        pi += 1;
    }

    // Handle ']' as first char in class (literal)
    var matched = false;
    var first = true;
    while (pi < pattern.len) {
        const c = pattern[pi];
        if (c == ']' and !first) {
            // End of class
            return if (matched != negate) pi + 1 else null;
        }
        first = false;

        // Check for range: a-z
        if (pi + 2 < pattern.len and pattern[pi + 1] == '-' and pattern[pi + 2] != ']') {
            const lo = c;
            const hi = pattern[pi + 2];
            if (ch >= lo and ch <= hi) {
                matched = true;
            }
            pi += 3;
        } else {
            if (c == ch) {
                matched = true;
            }
            pi += 1;
        }
    }
    // No closing ']' found — treat as no match
    return null;
}

/// Represents a single pattern from a .gitignore file.
const Pattern = struct {
    allocator: Allocator,
    pattern: []const u8,
    /// If true, the pattern is a negation (starts with !).
    negation: bool,
    /// If true, the pattern only matches directories (ends with /).
    is_dir: bool,
    /// If true, the pattern is anchored to the repository root (starts with /).
    anchored_to_root: bool,
    /// If true, the pattern contains one or more slashes, meaning it's matched relative to repo root.
    contains_slash: bool,

    fn init(allocator: Allocator, raw_pattern: []const u8) !Pattern {
        var p = raw_pattern;

        // Strip trailing whitespace, but preserve escaped trailing spaces (\ )
        while (p.len > 0 and std.ascii.isWhitespace(p[p.len - 1])) {
            // Check if the space is escaped
            if (p.len >= 2 and p[p.len - 2] == '\\' and p[p.len - 1] == ' ') {
                break;
            }
            p = p[0 .. p.len - 1];
        }

        // Strip leading whitespace
        while (p.len > 0 and std.ascii.isWhitespace(p[0])) {
            p = p[1..];
        }

        if (p.len == 0) return PatternError.InvalidPattern;

        // Handle negation: `!` at start (but `\!` is literal `!`)
        var negation = false;
        if (p[0] == '!') {
            negation = true;
            p = p[1..];
        } else if (p.len >= 2 and p[0] == '\\' and p[1] == '!') {
            // \! → literal !, strip the backslash
            p = p[1..];
        }

        // Handle \# at start → literal #
        if (p.len >= 2 and p[0] == '\\' and p[1] == '#') {
            p = p[1..];
        }

        if (p.len == 0) return PatternError.InvalidPattern;

        // Special case: a single "/" is not a valid pattern
        if (std.mem.eql(u8, p, "/")) {
            return PatternError.InvalidPattern;
        }

        // Leading /
        var anchored_to_root = false;
        if (p[0] == '/') {
            anchored_to_root = true;
            p = p[1..];
        }

        // Trailing /
        var is_dir = false;
        if (p.len > 0 and p[p.len - 1] == '/') {
            is_dir = true;
            p = p[0 .. p.len - 1];
        }

        if (p.len == 0) return PatternError.InvalidPattern;

        // contains_slash: check for `/` in the pattern AFTER stripping leading/trailing `/`
        const contains_slash = std.mem.indexOfScalar(u8, p, '/') != null;

        return Pattern{
            .allocator = allocator,
            .pattern = try allocator.dupe(u8, p),
            .negation = negation,
            .is_dir = is_dir,
            .anchored_to_root = anchored_to_root,
            .contains_slash = contains_slash,
        };
    }

    fn deinit(self: *Pattern) void {
        self.allocator.free(self.pattern);
    }

    /// Checks if a given path matches the pattern.
    /// The `path` is always relative to the repository root.
    pub fn matches(self: Pattern, path: []const u8, is_dir_path: bool) bool {
        if (self.is_dir and !is_dir_path) {
            return false;
        }

        if (self.anchored_to_root or self.contains_slash) {
            return matchPathSegments(self.pattern, path);
        } else {
            // Match against each path component
            var path_parts = std.mem.splitScalar(u8, path, '/');
            while (path_parts.next()) |part| {
                if (globMatch(self.pattern, part)) {
                    return true;
                }
            }
            return false;
        }
    }
};

/// Matches path segments using a recursive approach.
/// Handles `**` wildcard that matches zero or more directories.
fn matchPathSegments(pattern_full: []const u8, path_full: []const u8) bool {
    var pattern_it = std.mem.splitScalar(u8, pattern_full, '/');
    var path_it = std.mem.splitScalar(u8, path_full, '/');
    return matchSegmentsRecursive(&pattern_it, &path_it);
}

fn matchSegmentsRecursive(
    pattern_it: *std.mem.SplitIterator(u8, .scalar),
    path_it: *std.mem.SplitIterator(u8, .scalar),
) bool {
    const p_peek = pattern_it.peek();
    const pa_peek = path_it.peek();

    // Base Case 1: Pattern exhausted — prefix match (correct gitignore behavior)
    if (p_peek == null) {
        return true;
    }

    // Base Case 2: Path exhausted, but pattern is not.
    // Match only if remaining pattern is all `**`.
    if (pa_peek == null) {
        if (!std.mem.eql(u8, p_peek.?, "**")) {
            return false;
        }
        _ = pattern_it.next();
        while (pattern_it.next()) |part| {
            if (!std.mem.eql(u8, part, "**")) {
                return false;
            }
        }
        return true;
    }

    const current_p_part = p_peek.?;
    const current_pa_part = pa_peek.?;

    if (std.mem.eql(u8, current_p_part, "**")) {
        var pattern_it_after_glob = pattern_it.*;
        _ = pattern_it_after_glob.next(); // Consume "**"

        var path_it_fork = path_it.*;
        while (true) {
            var pattern_it_copy = pattern_it_after_glob;
            if (matchSegmentsRecursive(&pattern_it_copy, &path_it_fork)) {
                return true;
            }
            if (path_it_fork.next() == null) {
                return false;
            }
        }
    } else {
        if (globMatch(current_p_part, current_pa_part)) {
            _ = pattern_it.next();
            _ = path_it.next();
            return matchSegmentsRecursive(pattern_it, path_it);
        }
    }

    return false;
}

pub const Gitignore = struct {
    patterns: List(Pattern),
    allocator: Allocator,

    pub fn init(allocator: Allocator, content: []const u8) !Gitignore {
        var self = Gitignore{
            .patterns = .empty,
            .allocator = allocator,
        };

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            // Don't trim the line here — Pattern.init handles whitespace
            // (including escaped trailing spaces). We only need to check
            // for comments and blank lines on the trimmed version.
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;

            // Pass the original (untrimmed) line so Pattern.init can handle escaped trailing whitespace correctly.
            const pattern = Pattern.init(allocator, line) catch |e| switch (e) {
                PatternError.InvalidPattern => continue,
                else => return e,
            };
            try self.patterns.append(allocator, pattern);
        }

        return self;
    }

    pub fn deinit(self: *Gitignore) void {
        for (self.patterns.items) |*p| {
            p.deinit();
        }
        self.patterns.deinit(self.allocator);
    }

    /// Checks if a path should be ignored.
    /// The last matching pattern wins.
    pub fn shouldIgnore(self: *const Gitignore, path: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.patterns.items) |p| {
            if (p.matches(path, is_dir)) {
                ignored = !p.negation;
            }
        }
        return ignored;
    }
};

/// A stack of gitignore layers, one per directory level, enabling per-directory
/// .gitignore files with correct last-match-wins semantics across all layers.
pub const GitignoreStack = struct {
    layers: std.ArrayListUnmanaged(Layer),

    const Layer = struct {
        gi: Gitignore,
        /// Path of this layer's directory relative to the walk root. Empty string
        /// means the walk root itself. Owned (heap-allocated) when non-empty.
        rel_root: []const u8,
        owns_rel_root: bool,

        fn deinit(self: *Layer, allocator: Allocator) void {
            self.gi.deinit();
            if (self.owns_rel_root) allocator.free(self.rel_root);
        }
    };

    pub fn init() GitignoreStack {
        return .{ .layers = .empty };
    }

    pub fn deinit(self: *GitignoreStack, allocator: Allocator) void {
        for (self.layers.items) |*layer| layer.deinit(allocator);
        self.layers.deinit(allocator);
    }

    /// Try to read `.gitignore` from `dir` and push a new layer anchored at
    /// `rel_dir` (relative to the walk root; pass `""` for the root directory).
    /// Returns true if a layer was pushed, false if no `.gitignore` was found.
    /// The caller must call `pop()` for every true return when leaving the directory.
    pub fn tryPushDir(self: *GitignoreStack, dir: fs.Dir, rel_dir: []const u8, allocator: Allocator) !bool {
        const content = dir.readFileAlloc(allocator, ".gitignore", 1024 * 1024) catch |e| switch (e) {
            error.FileNotFound => return false,
            else => return false, // ignore unreadable .gitignore files
        };
        defer allocator.free(content);

        const gi = try Gitignore.init(allocator, content);
        const rel_root = if (rel_dir.len == 0) rel_dir else try allocator.dupe(u8, rel_dir);
        try self.layers.append(allocator, .{
            .gi = gi,
            .rel_root = rel_root,
            .owns_rel_root = rel_dir.len != 0,
        });
        return true;
    }

    /// Pop the most-recently-pushed layer. Only call when `tryPushDir` returned true.
    pub fn pop(self: *GitignoreStack, allocator: Allocator) void {
        var layer = self.layers.pop().?;
        layer.deinit(allocator);
    }

    /// Return true if `rel_path` (relative to the walk root) should be ignored.
    /// `is_dir` must reflect whether the path is a directory.
    /// Last-match-wins across all layers combined.
    pub fn shouldIgnore(self: *const GitignoreStack, rel_path: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.layers.items) |layer| {
            const local_path = if (layer.rel_root.len == 0)
                rel_path
            else blk: {
                const prefix = layer.rel_root;
                if (rel_path.len <= prefix.len) continue;
                if (!std.mem.startsWith(u8, rel_path, prefix)) continue;
                if (rel_path[prefix.len] != '/') continue;
                break :blk rel_path[prefix.len + 1 ..];
            };
            for (layer.gi.patterns.items) |p| {
                if (p.matches(local_path, is_dir)) {
                    ignored = !p.negation;
                }
            }
        }
        return ignored;
    }
};

test "GitignoreStack basic" {
    const allocator = std.testing.allocator;
    // Simulate a root .gitignore that ignores *.log and build/
    const root_content = "*.log\nbuild/\n";
    const root_gi = try Gitignore.init(allocator, root_content);
    var stack = GitignoreStack.init();
    defer stack.deinit(allocator);
    try stack.layers.append(allocator, .{ .gi = root_gi, .rel_root = "", .owns_rel_root = false });

    try std.testing.expect(stack.shouldIgnore("foo.log", false));
    try std.testing.expect(stack.shouldIgnore("build", true));
    try std.testing.expect(!stack.shouldIgnore("build", false));
    try std.testing.expect(!stack.shouldIgnore("foo.zig", false));

    // Simulate a sub-directory .gitignore at "src/" that negates *.log
    const sub_content = "!debug.log\n";
    const sub_gi = try Gitignore.init(allocator, sub_content);
    const sub_rel_root = try allocator.dupe(u8, "src");
    try stack.layers.append(allocator, .{ .gi = sub_gi, .rel_root = sub_rel_root, .owns_rel_root = true });

    // src/debug.log is negated by the sub-layer
    try std.testing.expect(!stack.shouldIgnore("src/debug.log", false));
    // src/other.log is still ignored by root layer (sub layer has no matching rule)
    try std.testing.expect(stack.shouldIgnore("src/other.log", false));
    // top-level foo.log unaffected by sub layer
    try std.testing.expect(stack.shouldIgnore("foo.log", false));

    stack.pop(allocator);
    // After pop, src/debug.log is ignored again
    try std.testing.expect(stack.shouldIgnore("src/debug.log", false));
}

test "gitignore parsing and matching" {
    const allocator = testing.allocator;
    const content =
        \\# This is a comment
        \\
        \\# Ignore all .a files
        \\*.a
        \\
        \\# But do not ignore lib.a, even if it's in a subdirectory
        \\!lib.a
        \\
        \\# Ignore the build/ directory
        \\build/
        \\
        \\# Ignore doc/notes.txt, but not doc/server/arch.txt
        \\doc/notes.txt
        \\
        \\# Ignore all .log files in the root
        \\/*.log
        \\
        \\# Ignore **/foo
        \\**/foo
        \\
        \\# Ignore bar/**/baz
        \\bar/**/baz
        \\
        \\# Ignore foo/bar and everything inside
        \\foo/bar
    ;

    var gitignore = try Gitignore.init(allocator, content);
    defer gitignore.deinit();

    // Test *.a
    try testing.expect(gitignore.shouldIgnore("test.a", false));
    try testing.expect(gitignore.shouldIgnore("src/test.a", false));

    // Test !lib.a
    try testing.expect(!gitignore.shouldIgnore("lib.a", false));
    try testing.expect(!gitignore.shouldIgnore("src/lib.a", false));

    // Test build/
    try testing.expect(gitignore.shouldIgnore("build", true));
    try testing.expect(gitignore.shouldIgnore("foo/build", true));
    try testing.expect(!gitignore.shouldIgnore("build", false));

    // Test doc/notes.txt
    try testing.expect(gitignore.shouldIgnore("doc/notes.txt", false));
    try testing.expect(!gitignore.shouldIgnore("doc/server/arch.txt", false));

    // Test /*.log
    try testing.expect(gitignore.shouldIgnore("test.log", false));
    try testing.expect(!gitignore.shouldIgnore("src/test.log", false));

    // Test **/foo
    try testing.expect(gitignore.shouldIgnore("foo", false));
    try testing.expect(gitignore.shouldIgnore("src/foo", false));

    // Test bar/**/baz
    try testing.expect(gitignore.shouldIgnore("bar/baz", false));
    try testing.expect(gitignore.shouldIgnore("bar/a/baz", false));
    try testing.expect(gitignore.shouldIgnore("bar/a/b/baz", false));

    // Test foo/bar matches foo/bar/123
    try testing.expect(gitignore.shouldIgnore("foo/bar/123", false));
}

test "invalid case, rule /" {
    const allocator = testing.allocator;

    const content =
        \\/
    ;
    var gitignore = try Gitignore.init(allocator, content);
    defer gitignore.deinit();
    try testing.expect(!gitignore.shouldIgnore("foo", false));
    try testing.expect(!gitignore.shouldIgnore("bar/baz", false));
}

test "escape sequences: \\! and \\#" {
    const allocator = testing.allocator;
    const content =
        \\# A file literally named !important
        \\\!important
        \\# A file literally named #config
        \\\#config
    ;
    var gitignore = try Gitignore.init(allocator, content);
    defer gitignore.deinit();

    try testing.expect(gitignore.shouldIgnore("!important", false));
    try testing.expect(!gitignore.shouldIgnore("important", false));
    try testing.expect(gitignore.shouldIgnore("#config", false));
    try testing.expect(!gitignore.shouldIgnore("config", false));
}

test "character classes" {
    const allocator = testing.allocator;
    const content =
        \\[abc].txt
        \\[a-z]0.log
        \\[!0-9].dat
    ;
    var gitignore = try Gitignore.init(allocator, content);
    defer gitignore.deinit();

    // [abc].txt
    try testing.expect(gitignore.shouldIgnore("a.txt", false));
    try testing.expect(gitignore.shouldIgnore("b.txt", false));
    try testing.expect(gitignore.shouldIgnore("c.txt", false));
    try testing.expect(!gitignore.shouldIgnore("d.txt", false));

    // [a-z]0.log
    try testing.expect(gitignore.shouldIgnore("a0.log", false));
    try testing.expect(gitignore.shouldIgnore("z0.log", false));
    try testing.expect(!gitignore.shouldIgnore("A0.log", false));

    // [!0-9].dat
    try testing.expect(gitignore.shouldIgnore("a.dat", false));
    try testing.expect(!gitignore.shouldIgnore("5.dat", false));
}

test "trailing space with backslash escape" {
    const allocator = testing.allocator;
    // Pattern: "foo\ " (trailing space preserved by backslash escape)
    // We use ++ to build the string since multiline literals strip trailing whitespace
    const content = "foo\\ ";
    var gitignore = try Gitignore.init(allocator, content);
    defer gitignore.deinit();

    try testing.expect(gitignore.shouldIgnore("foo ", false));
    try testing.expect(!gitignore.shouldIgnore("foo", false));
}

test "? single-char wildcard" {
    const allocator = testing.allocator;
    const content =
        \\?.txt
        \\a?c
    ;
    var gitignore = try Gitignore.init(allocator, content);
    defer gitignore.deinit();

    try testing.expect(gitignore.shouldIgnore("a.txt", false));
    try testing.expect(gitignore.shouldIgnore("z.txt", false));
    try testing.expect(!gitignore.shouldIgnore("ab.txt", false));
    try testing.expect(!gitignore.shouldIgnore(".txt", false));

    try testing.expect(gitignore.shouldIgnore("abc", false));
    try testing.expect(gitignore.shouldIgnore("axc", false));
    try testing.expect(!gitignore.shouldIgnore("ac", false));
    try testing.expect(!gitignore.shouldIgnore("abbc", false));
}

test "a**.txt should not be treated as containing slash" {
    const allocator = testing.allocator;
    const content =
        \\a**.txt
    ;
    var gitignore = try Gitignore.init(allocator, content);
    defer gitignore.deinit();

    // a**.txt has no slash, so it matches against any path component
    try testing.expect(gitignore.shouldIgnore("a.txt", false));
    try testing.expect(gitignore.shouldIgnore("abc.txt", false));
    try testing.expect(gitignore.shouldIgnore("dir/a.txt", false));
    try testing.expect(gitignore.shouldIgnore("dir/abc.txt", false));
    try testing.expect(!gitignore.shouldIgnore("b.txt", false));
}

test "** edge cases" {
    const allocator = testing.allocator;
    const content =
        \\**/logs
        \\**/logs/**
        \\a/**/b
    ;
    var gitignore = try Gitignore.init(allocator, content);
    defer gitignore.deinit();

    // **/logs
    try testing.expect(gitignore.shouldIgnore("logs", false));
    try testing.expect(gitignore.shouldIgnore("foo/logs", false));
    try testing.expect(gitignore.shouldIgnore("foo/bar/logs", false));

    // **/logs/**
    try testing.expect(gitignore.shouldIgnore("logs/debug.log", false));
    try testing.expect(gitignore.shouldIgnore("foo/logs/debug.log", false));

    // a/**/b
    try testing.expect(gitignore.shouldIgnore("a/b", false));
    try testing.expect(gitignore.shouldIgnore("a/x/b", false));
    try testing.expect(gitignore.shouldIgnore("a/x/y/b", false));
    try testing.expect(!gitignore.shouldIgnore("b/a/b", false));
    try testing.expect(!gitignore.shouldIgnore("a/x/c", false));
}

test "globMatch basic" {
    // Literal
    try testing.expect(globMatch("abc", "abc"));
    try testing.expect(!globMatch("abc", "abd"));

    // Star
    try testing.expect(globMatch("*.txt", "foo.txt"));
    try testing.expect(globMatch("*.txt", ".txt"));
    try testing.expect(!globMatch("*.txt", "foo/bar.txt"));

    // Question mark
    try testing.expect(globMatch("?oo", "foo"));
    try testing.expect(!globMatch("?oo", "/oo"));

    // Char class
    try testing.expect(globMatch("[abc]", "a"));
    try testing.expect(!globMatch("[abc]", "d"));
    try testing.expect(globMatch("[a-z]", "m"));
    try testing.expect(!globMatch("[a-z]", "M"));
    try testing.expect(globMatch("[!0-9]", "a"));
    try testing.expect(!globMatch("[!0-9]", "5"));

    // Escape
    try testing.expect(globMatch("\\*", "*"));
    try testing.expect(!globMatch("\\*", "a"));
}
