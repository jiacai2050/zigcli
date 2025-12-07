/// A module for parsing and matching .gitignore patterns.
/// This implementation follows the Git documentation for .gitignore patterns:
/// https://git-scm.com/docs/gitignore
const std = @import("std");
const Allocator = std.mem.Allocator;
const List = std.ArrayList;
const fs = std.fs;
const testing = std.testing;
const c = @cImport({
    @cInclude("fnmatch.h");
});

const PatternError = error{
    InvalidPattern,
};

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
        var p = std.mem.trim(u8, raw_pattern, &std.ascii.whitespace);
        var negation = false;
        if (p.len > 0 and p[0] == '!') {
            negation = true;
            p = p[1..];
        }

        // Special case: a single "/" is not a valid pattern for ignoring files, so we ignore it.
        if (std.mem.eql(u8, p, "/")) {
            return PatternError.InvalidPattern;
        }

        var anchored_to_root = false;
        if (p.len > 0 and p[0] == '/') {
            anchored_to_root = true;
        }

        var is_dir = false;
        if (p.len > 0 and p[p.len - 1] == '/') {
            is_dir = true;
            p = p[0 .. p.len - 1]; // Strip trailing slash for matching glob part
        }

        return Pattern{
            .allocator = allocator,
            .pattern = try allocator.dupe(u8, p),
            .negation = negation,
            .is_dir = is_dir,
            .anchored_to_root = anchored_to_root,
            .contains_slash = std.mem.indexOf(u8, p, "/") != null or std.mem.indexOf(u8, p, "**") != null,
        };
    }

    fn deinit(self: *Pattern) void {
        self.allocator.free(self.pattern);
    }

    /// Checks if a given path matches the pattern.
    /// The `path` is always relative to the repository root.
    fn matches(self: Pattern, path: []const u8, is_dir_path: bool) !bool {
        // Rule: If the pattern is for a directory, it cannot match a file.
        if (self.is_dir and !is_dir_path) {
            return false;
        }

        // The pattern string may have a leading slash from `Pattern.init` if it was anchored.
        var pattern_to_match = self.pattern;
        if (self.anchored_to_root) {
            // Path always comes without leading slash, so strip from pattern for comparison.
            pattern_to_match = self.pattern[1..];
        }

        if (self.anchored_to_root or self.contains_slash) {
            // Rule: If pattern starts with '/' OR contains a '/', it is matched against
            // the pathname relative to the repository root.
            return try matchPathSegments(pattern_to_match, path, self.allocator);
        } else {
            // Rule: If pattern does not contain a slash, it matches against the filename
            // or directory name component anywhere in the path.
            // Example: "foo" matches "bar/foo" or "foo".
            const c_pattern = try std.fmt.allocPrintSentinel(self.allocator, "{s}", .{pattern_to_match}, 0);
            defer self.allocator.free(c_pattern);

            var path_parts = std.mem.splitScalar(u8, path, '/');
            while (path_parts.next()) |part| {
                const c_path = try std.fmt.allocPrintSentinel(self.allocator, "{s}", .{part}, 0);
                defer self.allocator.free(c_path);
                if (c.fnmatch(c_pattern.ptr, c_path.ptr, c.FNM_PATHNAME) == 0) {
                    return true;
                }
            }
            return false;
        }
    }
};

/// Matches path segments using a recursive state machine.
/// Handles pattern segments, path segments, and `**` wildcard.
/// `pattern_full` and `path_full` are slices of segments (no leading/trailing '/').
/// This function uses iterators to represent current state in pattern and path.
fn matchPathSegments(pattern_full: []const u8, path_full: []const u8, allocator: Allocator) !bool {
    var pattern_it = std.mem.splitScalar(u8, pattern_full, '/');
    var path_it = std.mem.splitScalar(u8, path_full, '/');

    return try matchSegmentsRecursive(&pattern_it, &path_it, allocator);
}

// Helper for matchPathSegments, using iterators for recursive matching
fn matchSegmentsRecursive(pattern_it: *std.mem.SplitIterator(u8, std.mem.DelimiterType.scalar), path_it: *std.mem.SplitIterator(u8, std.mem.DelimiterType.scalar), allocator: Allocator) !bool {
    const p_peek = pattern_it.peek();
    const pa_peek = path_it.peek();

    // Base Case 1: Pattern exhausted. This is a match because the pattern is a prefix of the path.
    // This also implicitly handles the case where both are exhausted.
    if (p_peek == null) {
        return true;
    }

    // Base Case 2: Path exhausted, but pattern is not.
    // This is a match only if the rest of the pattern consists of '**'.
    if (pa_peek == null) {
        if (!std.mem.eql(u8, p_peek.?, "**")) { // Check the currently peeked pattern part
            return false;
        }
        _ = pattern_it.next(); // Consume p_peek
        while (pattern_it.next()) |part| {
            if (!std.mem.eql(u8, part, "**")) {
                return false;
            }
        }
        return true;
    }

    // Process current segments
    const current_p_part = p_peek.?;
    const current_pa_part = pa_peek.?;

    if (std.mem.eql(u8, current_p_part, "**")) {
        // Handle "**" wildcard.
        var pattern_it_after_glob = pattern_it.*;
        _ = pattern_it_after_glob.next(); // Consume "**"

        // We now loop, trying to match the rest of the pattern (after "**")
        // against the rest of the path. On each iteration, we can either
        // match immediately (so "**" matches zero segments) or consume
        // one path segment and try again on the next iteration.
        var path_it_fork = path_it.*;
        while (true) {
            // Try to match pattern after "**" against the current sub-path.
            var pattern_it_copy = pattern_it_after_glob;
            if (try matchSegmentsRecursive(&pattern_it_copy, &path_it_fork, allocator)) {
                return true;
            }
            // If that failed, "**" needs to consume a segment.
            // If there are no more segments to consume, we've failed.
            if (path_it_fork.next() == null) {
                return false;
            }
        }
    } else { // Current pattern segment matches current path segment (via fnmatch)
        const matched_fnmatch = blk: {
            const c_pattern = try std.fmt.allocPrintSentinel(allocator, "{s}", .{current_p_part}, 0);
            defer allocator.free(c_pattern);
            const c_path = try std.fmt.allocPrintSentinel(allocator, "{s}", .{current_pa_part}, 0);
            defer allocator.free(c_path);
            if (c.fnmatch(c_pattern.ptr, c_path.ptr, c.FNM_PATHNAME) == 0) {
                break :blk true;
            }
            break :blk false;
        };
        if (matched_fnmatch) {
            // Consume both pattern and path parts, then recurse
            _ = pattern_it.next();
            _ = path_it.next();
            return matchSegmentsRecursive(pattern_it, path_it, allocator);
        }
    }

    return false; // Current segments do not match, and no "**" to handle
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
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue;
            }
            const pattern = Pattern.init(allocator, trimmed) catch |e| switch (e) {
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
    pub fn shouldIgnore(self: *const Gitignore, path: []const u8, is_dir: bool) !bool {
        var ignored = false;
        for (self.patterns.items) |p| {
            if (try p.matches(path, is_dir)) {
                ignored = !p.negation;
            }
        }
        return ignored;
    }
};

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

    // Test comments and blank lines (implicitly tested by not crashing)

    // Test *.a
    try testing.expect(try gitignore.shouldIgnore("test.a", false));
    try testing.expect(try gitignore.shouldIgnore("src/test.a", false));

    // Test !lib.a
    try testing.expect(!(try gitignore.shouldIgnore("lib.a", false)));
    try testing.expect(!(try gitignore.shouldIgnore("src/lib.a", false)));

    // Test build/
    try testing.expect(try gitignore.shouldIgnore("build", true));
    try testing.expect(try gitignore.shouldIgnore("foo/build", true));
    try testing.expect(!(try gitignore.shouldIgnore("build", false)));

    // Test doc/notes.txt
    try testing.expect(try gitignore.shouldIgnore("doc/notes.txt", false));
    try testing.expect(!(try gitignore.shouldIgnore("doc/server/arch.txt", false)));

    // Test /*.log
    try testing.expect(try gitignore.shouldIgnore("test.log", false));
    try testing.expect(!(try gitignore.shouldIgnore("src/test.log", false)));

    // Test **/foo
    try testing.expect(try gitignore.shouldIgnore("foo", false));
    try testing.expect(try gitignore.shouldIgnore("src/foo", false));

    // Test bar/**/baz
    try testing.expect(try gitignore.shouldIgnore("bar/baz", false));
    try testing.expect(try gitignore.shouldIgnore("bar/a/baz", false));
    try testing.expect(try gitignore.shouldIgnore("bar/a/b/baz", false));

    // Test foo/bar matches foo/bar/123
    try testing.expect(try gitignore.shouldIgnore("foo/bar/123", false));
}

test "invalid case, rule /" {
    const allocator = testing.allocator;

    // Test "/" is an invalid pattern and should not match anything.
    const content =
        \\/
    ;
    var gitignore = try Gitignore.init(allocator, content);
    defer gitignore.deinit();
    try testing.expect(!try gitignore.shouldIgnore("foo", false));
    try testing.expect(!try gitignore.shouldIgnore("bar/baz", false));
}
