const std = @import("std");
const curl = @import("curl");
const simargs = @import("simargs");
const util = @import("util.zig");
const Manifest = @import("./pkg/Manifest.zig");
const builtin = @import("builtin");
const fs = std.fs;
const ascii = std.ascii;
const log = std.log;
const mem = std.mem;
const Allocator = mem.Allocator;
const print = std.debug.print;
const Child = std.process.Child;
const ArrayList = std.ArrayList;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const opt = try simargs.parse(
        allocator,
        struct {
            help: bool = false,
            verbose: bool = false,
            debug_hash: bool = false,
            tmp_dir: []const u8 = "/tmp",

            pub const __shorts__ = .{
                .verbose = .v,
                .debug_hash = .d,
                .help = .h,
            };
            pub const __messages__ = .{
                .tmp_dir = "Temp directory for uncompress package",
                .debug_hash = "Print hash for each file",
                .help = "Show help",
            };
        },
        "[package-dir or url]",
        util.get_build_info(),
    );

    if (opt.positional_args.len == 0) {
        const stdout = std.io.getStdOut();
        try opt.printHelp(stdout.writer());
        return;
    }
    const url_or_path = opt.positional_args[0];
    const cache_dir = try resolveGlobalCacheDir(allocator);
    const fetcher = Fetcher.init(
        allocator,
        opt.args.tmp_dir,
        opt.args.verbose,
        opt.args.debug_hash,
        cache_dir,
    );

    if (std.mem.startsWith(u8, url_or_path, "http")) {
        try fetcher.handleHTTP(url_or_path);
    } else {
        // it's a directory
        try fetcher.handleDir(url_or_path);
    }
}

const Fetcher = struct {
    allocator: Allocator,
    tmp_dir: []const u8,
    verbose: bool,
    debug_hash: bool,
    cache_dir: []const u8,

    fn init(allocator: Allocator, tmp_dir: []const u8, verbose: bool, debug_hash: bool, cache_dir: []const u8) Fetcher {
        return Fetcher{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .verbose = verbose,
            .debug_hash = debug_hash,
            .cache_dir = cache_dir,
        };
    }

    fn calcHash(self: Fetcher, dir: []const u8) anyerror!Manifest.MultiHashHexDigest {
        const manifest = try loadManifest(self.allocator, dir);
        if (self.verbose) {
            log.info("manifest = {any}", .{manifest});
        }

        const filter: Filter = .{
            .include_paths = if (manifest) |m| m.paths else .{},
        };
        const actual_hash = try computeHash(
            self.allocator,
            dir,
            filter,
            self.debug_hash,
        );
        if (manifest) |m| {
            var it = m.dependencies.iterator();
            while (it.next()) |entry| {
                const dep = entry.value_ptr;
                switch (dep.location) {
                    .url => |pkg_url| {
                        if (dep.hash) |hash| {
                            const u = try std.fmt.allocPrintZ(self.allocator, "{s}", .{pkg_url});
                            _ = try self.cachePackageFromUrl(u, hash);
                        }
                    },
                    else => {},
                }
            }
        }

        return Manifest.hexDigest(actual_hash);
    }

    fn handleDir(self: Fetcher, path: [:0]const u8) !void {
        const hash = try self.calcHash(path);
        log.info("{s}", .{hash});
    }

    fn handleHTTP(self: Fetcher, url: [:0]const u8) !void {
        const hash = try self.cachePackageFromUrl(url, null);
        log.info("{s}", .{hash});
    }

    fn cachePackageFromUrl(
        self: Fetcher,
        url: [:0]const u8,
        expected_hash: ?[]const u8,
    ) anyerror!Manifest.MultiHashHexDigest {
        log.info("Fetch {s}...", .{url});
        const rand_int = std.crypto.random.int(u64);
        const tmp_dir = try std.fmt.allocPrint(self.allocator, "{s}{s}zigfetch-{s}", .{
            self.tmp_dir,
            fs.path.sep_str,
            Manifest.hex64(rand_int),
        });
        try fetchPackage(self.allocator, url, tmp_dir, self.verbose);
        const actual_hash = try self.calcHash(tmp_dir);
        if (expected_hash) |expected| {
            if (!std.mem.eql(u8, expected, &actual_hash)) {
                log.err("Hash incorrect for {s}, expected:{s}, actual:{s}", .{
                    url, expected, actual_hash,
                });
                return error.HashNotExpected;
            }
        }
        try moveToCache(self.allocator, tmp_dir, self.cache_dir, actual_hash);

        return actual_hash;
    }
};

fn moveToCache(allocator: Allocator, src_dir: []const u8, cache_dir: []const u8, hex: Manifest.MultiHashHexDigest) !void {
    const dst = try std.fmt.allocPrint(allocator, "{s}/p/{s}", .{ cache_dir, hex });

    _ = fs.openDirAbsolute(dst, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            return fs.renameAbsolute(src_dir, dst);
        },
        else => return err,
    };
    log.info("Dir({s}) already exists, skip copy...", .{dst});
    fs.deleteTreeAbsolute(src_dir) catch |e| {
        log.err("Delete dir({s}) failed, err:{any}", .{ src_dir, e });
    };
}

fn fetchPackage(allocator: Allocator, url: [:0]const u8, out_dir: []const u8, verbose: bool) !void {
    const easy = try curl.Easy.init(allocator, .{});
    try easy.setFollowLocation(true);
    try easy.setVerbose(verbose);
    defer easy.deinit();

    const resp = try easy.get(url);
    defer resp.deinit();

    if (resp.status_code >= 400) {
        log.err("Failed to fetch {s}: {d}\n", .{ url, resp.status_code });
        return error.BadFetch;
    }
    const buffer = resp.body.?;
    const header = try resp.getHeader("content-type");
    if (header) |h| {
        const mime_type = h.get();
        if (ascii.eqlIgnoreCase(mime_type, "application/gzip") or
            ascii.eqlIgnoreCase(mime_type, "application/x-gzip") or
            ascii.eqlIgnoreCase(mime_type, "application/tar+gzip"))
        {
            // tar.gz
            try untar(allocator, out_dir, buffer.items);
        } else if (ascii.eqlIgnoreCase(mime_type, "application/zip")) {
            // zip
            try unzip(allocator, out_dir, buffer.items);
        } else {
            log.err("Unknown mime type:{s}", .{mime_type});
            return error.UnsupportedType;
        }
    } else {
        return error.NoContentTypeHeader;
    }
}

fn loadManifest(allocator: Allocator, dir: []const u8) !?Manifest {
    const pkg_dir = try fs.openDirAbsolute(dir, .{ .iterate = false });
    const file = pkg_dir.openFile(Manifest.basename, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const bytes = try file.readToEndAllocOptions(
        allocator,
        Manifest.max_bytes,
        null,
        1,
        0,
    );
    const ast = try std.zig.Ast.parse(allocator, bytes, .zon);
    const manifest = try Manifest.parse(allocator, ast, .{
        .allow_missing_paths_field = true,
    });
    return manifest;
}

fn unzip(allocator: Allocator, out_dir: []const u8, src: []const u8) !void {
    const rand_int = std.crypto.random.int(u64);
    const tmp_file = try std.fmt.allocPrint(allocator, "/tmp/tmpzip-{s}.zip", .{
        Manifest.hex64(rand_int),
    });
    const zip_file = try fs.createFileAbsolute(tmp_file, .{
        .exclusive = true,
        .read = true,
    });
    // defer fs.deleteFileAbsolute(tmp_file) catch {};
    try zip_file.writeAll(src);

    try fs.makeDirAbsolute(out_dir);
    const out = try fs.openDirAbsolute(out_dir, .{});
    std.zip.extract(out, zip_file.seekableStream(), .{
        .allow_backslashes = true,
    }) catch |err| {
        log.err(
            "zip extract failed: {s}",
            .{@errorName(err)},
        );
        return err;
    };
}

fn untar(allocator: Allocator, out_dir: []const u8, src: []const u8) !void {
    try fs.makeDirAbsolute(out_dir);

    const argv = [_][]const u8{
        "tar",
        "-xz",
        "--strip-components=1",
        "-C",
        out_dir,
    };
    return execShell(allocator, &argv, src);
}

fn execShell(allocator: Allocator, argv: []const []const u8, src: []const u8) !void {
    var child = Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    try child.spawn();

    const stdin = child.stdin.?;
    try stdin.writeAll(src);
    // Those following 2 lines are require to let tar exit, otherwise child process wait stdin forever!
    stdin.close();
    child.stdin = null;

    const term = try child.wait();
    switch (term) {
        .Exited => |rc| {
            if (rc == 0) {
                return;
            }
        },
        else => {},
    }
    log.err("Failed to exec shell, term:{any}", .{term});
    return error.ExecShell;
}

const Filter = struct {
    include_paths: std.StringArrayHashMapUnmanaged(void) = .{},

    /// sub_path is relative to the package root.
    pub fn includePath(self: Filter, sub_path: []const u8) bool {
        if (self.include_paths.count() == 0) return true;
        if (self.include_paths.contains("")) return true;
        if (self.include_paths.contains(".")) return true;
        if (self.include_paths.contains(sub_path)) return true;

        // Check if any included paths are parent directories of sub_path.
        var dirname = sub_path;
        while (std.fs.path.dirname(dirname)) |next_dirname| {
            if (self.include_paths.contains(next_dirname)) return true;
            dirname = next_dirname;
        }

        return false;
    }

    test includePath {
        const gpa = std.testing.allocator;
        var filter: Filter = .{};
        defer filter.include_paths.deinit(gpa);

        try filter.include_paths.put(gpa, "src", {});
        try std.testing.expect(filter.includePath("src/core/unix/SDL_poll.c"));
        try std.testing.expect(!filter.includePath(".gitignore"));
    }
};

fn computeHash(
    gpa: Allocator,
    root_dirname: []const u8,
    filter: Filter,
    debug_hash: bool,
) !Manifest.Digest {
    const root_dir = try fs.openDirAbsolute(root_dirname, .{ .iterate = true });

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{ .allocator = gpa });

    // Collect all files, recursively, then sort.
    var all_files = std.ArrayList(*HashedFile).init(gpa);
    defer all_files.deinit();

    var deleted_files = std.ArrayList(*DeletedFile).init(gpa);
    defer deleted_files.deinit();

    // Track directories which had any files deleted from them so that empty directories
    // can be deleted.
    var sus_dirs: std.StringArrayHashMapUnmanaged(void) = .{};
    defer sus_dirs.deinit(gpa);

    var walker = try root_dir.walk(gpa);
    defer walker.deinit();

    {
        // The final hash will be a hash of each file hashed independently. This
        // allows hashing in parallel.
        var wait_group: std.Thread.WaitGroup = .{};
        // `computeHash` is called from a worker thread so there must not be
        // any waiting without working or a deadlock could occur.
        defer thread_pool.waitAndWork(&wait_group);

        while (walker.next() catch |err| {
            log.err(
                "unable to walk temporary directory '{s}': {s}",
                .{ root_dirname, @errorName(err) },
            );
            return error.FetchFailed;
        }) |entry| {
            if (entry.kind == .directory) continue;

            const entry_pkg_path = stripRoot(entry.path, root_dirname);
            if (!filter.includePath(entry_pkg_path)) {
                // Delete instead of including in hash calculation.
                const fs_path = try gpa.dupe(u8, entry.path);

                // Also track the parent directory in case it becomes empty.
                if (fs.path.dirname(fs_path)) |parent|
                    try sus_dirs.put(gpa, parent, {});

                const deleted_file = try gpa.create(DeletedFile);
                deleted_file.* = .{
                    .fs_path = fs_path,
                    .failure = undefined, // to be populated by the worker
                };
                thread_pool.spawnWg(&wait_group, workerDeleteFile, .{ root_dir, deleted_file });
                try deleted_files.append(deleted_file);
                continue;
            }

            const kind: HashedFile.Kind = switch (entry.kind) {
                .directory => unreachable,
                .file => .file,
                .sym_link => .link,
                else => {
                    log.err(
                        "package contains '{s}' which has illegal file type '{s}'",
                        .{ entry.path, @tagName(entry.kind) },
                    );
                    return error.NotExpectedFileKind;
                },
            };

            // if (std.mem.eql(u8, entry_pkg_path, "build.zig"))
            //     f.has_build_zig = true;

            const fs_path = try gpa.dupe(u8, entry.path);
            const hashed_file = try gpa.create(HashedFile);
            hashed_file.* = .{
                .fs_path = fs_path,
                .normalized_path = try normalizePathAlloc(gpa, entry_pkg_path),
                .kind = kind,
                .hash = undefined, // to be populated by the worker
                .failure = undefined, // to be populated by the worker
            };
            thread_pool.spawnWg(&wait_group, workerHashFile, .{ root_dir, hashed_file });
            try all_files.append(hashed_file);
        }
    }

    {
        // Sort by length, descending, so that child directories get removed first.
        sus_dirs.sortUnstable(@as(struct {
            keys: []const []const u8,
            pub fn lessThan(ctx: @This(), a_index: usize, b_index: usize) bool {
                return ctx.keys[b_index].len < ctx.keys[a_index].len;
            }
        }, .{ .keys = sus_dirs.keys() }));

        // During this loop, more entries will be added, so we must loop by index.
        var i: usize = 0;
        while (i < sus_dirs.count()) : (i += 1) {
            const sus_dir = sus_dirs.keys()[i];
            root_dir.deleteDir(sus_dir) catch |err| switch (err) {
                error.DirNotEmpty => continue,
                error.FileNotFound => continue,
                else => |e| {
                    log.err(
                        "unable to delete empty directory '{s}': {s}",
                        .{ sus_dir, @errorName(e) },
                    );
                    return error.FetchFailed;
                },
            };
            if (fs.path.dirname(sus_dir)) |parent| {
                try sus_dirs.put(gpa, parent, {});
            }
        }
    }

    std.mem.sortUnstable(*HashedFile, all_files.items, {}, HashedFile.lessThan);

    var hasher = Manifest.Hash.init(.{});
    var any_failures = false;
    for (all_files.items) |hashed_file| {
        hashed_file.failure catch |err| {
            any_failures = true;
            log.err("unable to hash '{s}': {s}", .{
                hashed_file.fs_path, @errorName(err),
            });
        };
        hasher.update(&hashed_file.hash);
    }
    for (deleted_files.items) |deleted_file| {
        deleted_file.failure catch |err| {
            any_failures = true;
            log.err("failed to delete excluded path '{s}' from package: {s}", .{
                deleted_file.fs_path, @errorName(err),
            });
        };
    }

    if (any_failures) return error.FetchFailed;

    if (debug_hash) {
        // Print something to stdout that can be text diffed to figure out why
        // the package hash is different.
        dumpHashInfo(all_files.items) catch |err| {
            std.debug.print("unable to write to stdout: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
    }

    return hasher.finalResult();
}

const HashedFile = struct {
    fs_path: []const u8,
    normalized_path: []const u8,
    hash: Manifest.Digest,
    failure: Error!void,
    kind: Kind,

    const Error =
        fs.File.OpenError ||
        fs.File.ReadError ||
        fs.File.StatError ||
        fs.File.ChmodError ||
        fs.Dir.ReadLinkError;

    const Kind = enum { file, link };

    fn lessThan(context: void, lhs: *const HashedFile, rhs: *const HashedFile) bool {
        _ = context;
        return std.mem.lessThan(u8, lhs.normalized_path, rhs.normalized_path);
    }
};

const DeletedFile = struct {
    fs_path: []const u8,
    failure: Error!void,

    const Error =
        fs.Dir.DeleteFileError ||
        fs.Dir.DeleteDirError;
};

/// Strips root directory name from file system path.
fn stripRoot(fs_path: []const u8, root_dir: []const u8) []const u8 {
    if (root_dir.len == 0 or fs_path.len <= root_dir.len) return fs_path;

    if (std.mem.eql(u8, fs_path[0..root_dir.len], root_dir) and fs_path[root_dir.len] == fs.path.sep) {
        return fs_path[root_dir.len + 1 ..];
    }

    return fs_path;
}

fn workerHashFile(dir: fs.Dir, hashed_file: *HashedFile) void {
    hashed_file.failure = hashFileFallible(dir, hashed_file);
}

fn workerDeleteFile(dir: fs.Dir, deleted_file: *DeletedFile) void {
    deleted_file.failure = deleteFileFallible(dir, deleted_file);
}

fn hashFileFallible(dir: fs.Dir, hashed_file: *HashedFile) HashedFile.Error!void {
    var buf: [8000]u8 = undefined;
    var hasher = Manifest.Hash.init(.{});
    hasher.update(hashed_file.normalized_path);

    switch (hashed_file.kind) {
        .file => {
            var file = try dir.openFile(hashed_file.fs_path, .{});
            defer file.close();
            // Hard-coded false executable bit: https://github.com/ziglang/zig/issues/17463
            hasher.update(&.{ 0, 0 });
            var file_header: FileHeader = .{};
            while (true) {
                const bytes_read = try file.read(&buf);
                if (bytes_read == 0) break;
                hasher.update(buf[0..bytes_read]);
                file_header.update(buf[0..bytes_read]);
            }
            if (file_header.isExecutable()) {
                try setExecutable(file);
            }
        },
        .link => {
            const link_name = try dir.readLink(hashed_file.fs_path, &buf);
            if (fs.path.sep != canonical_sep) {
                // Package hashes are intended to be consistent across
                // platforms which means we must normalize path separators
                // inside symlinks.
                normalizePath(link_name);
            }
            hasher.update(link_name);
        },
    }
    hasher.final(&hashed_file.hash);
}

fn deleteFileFallible(dir: fs.Dir, deleted_file: *DeletedFile) DeletedFile.Error!void {
    try dir.deleteFile(deleted_file.fs_path);
}

fn setExecutable(file: fs.File) !void {
    if (!std.fs.has_executable_bit) return;

    const S = std.posix.S;
    const mode = fs.File.default_mode | S.IXUSR | S.IXGRP | S.IXOTH;
    try file.chmod(mode);
}

// Detects executable header: ELF magic header or shebang line.
const FileHeader = struct {
    const elf_magic = std.elf.MAGIC;
    const shebang = "#!";

    header: [@max(elf_magic.len, shebang.len)]u8 = undefined,
    bytes_read: usize = 0,

    pub fn update(self: *FileHeader, buf: []const u8) void {
        if (self.bytes_read >= self.header.len) return;
        const n = @min(self.header.len - self.bytes_read, buf.len);
        @memcpy(self.header[self.bytes_read..][0..n], buf[0..n]);
        self.bytes_read += n;
    }

    pub fn isExecutable(self: *FileHeader) bool {
        return std.mem.eql(u8, self.header[0..shebang.len], shebang) or
            std.mem.eql(u8, self.header[0..elf_magic.len], elf_magic);
    }
};

fn normalizePathAlloc(arena: Allocator, pkg_path: []const u8) ![]const u8 {
    const normalized = try arena.dupe(u8, pkg_path);
    if (fs.path.sep == canonical_sep) return normalized;
    normalizePath(normalized);
    return normalized;
}

const canonical_sep = fs.path.sep_posix;
const assert = std.debug.assert;

fn normalizePath(bytes: []u8) void {
    assert(fs.path.sep != canonical_sep);
    std.mem.replaceScalar(u8, bytes, fs.path.sep, canonical_sep);
}

fn dumpHashInfo(all_files: []const *const HashedFile) !void {
    const stdout = std.io.getStdOut();
    var bw = std.io.bufferedWriter(stdout.writer());
    const w = bw.writer();

    for (all_files) |hashed_file| {
        try w.print("{s}: {s}: {s}\n", .{
            @tagName(hashed_file.kind),
            std.fmt.fmtSliceHexLower(&hashed_file.hash),
            hashed_file.normalized_path,
        });
    }

    try bw.flush();
}

/// Caller owns returned memory.
pub fn resolveGlobalCacheDir(allocator: Allocator) ![]u8 {
    if (builtin.os.tag == .wasi)
        @compileError("on WASI the global cache dir must be resolved with preopens");

    if (try std.zig.EnvVar.ZIG_GLOBAL_CACHE_DIR.get(allocator)) |value| return value;

    const appname = "zig";

    if (builtin.os.tag != .windows) {
        if (std.zig.EnvVar.XDG_CACHE_HOME.getPosix()) |cache_root| {
            return fs.path.join(allocator, &[_][]const u8{ cache_root, appname });
        } else if (std.zig.EnvVar.HOME.getPosix()) |home| {
            return fs.path.join(allocator, &[_][]const u8{ home, ".cache", appname });
        }
    }

    return fs.getAppDataDir(allocator, appname);
}
