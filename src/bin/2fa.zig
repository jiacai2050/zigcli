//! 2fa - Two-factor authentication agent.
//! Zig port of https://github.com/rsc/2fa
//!
//! Usage:
//!   2fa --add [-7] [-8] [--hotp] name
//!   2fa --list
//!   2fa [--clip] [name]

const std = @import("std");
const builtin = @import("builtin");
const simargs = @import("simargs");
const util = @import("util.zig");
const mem = std.mem;
const fs = std.fs;
const testing = std.testing;

// The keychain file is stored in $HOME/.2fa.
const keychain_file_name = ".2fa";

/// A single key entry parsed from the keychain file.
const KeyEntry = struct {
    name: []const u8,
    is_hotp: bool,
    digits: u8,
    /// Base32-encoded secret (uppercase, no padding).
    secret: []const u8,
    /// Counter for HOTP; always 0 for TOTP.
    counter: u64,
};

pub fn main() !void {
    var gpa = util.Allocator.instance;
    defer gpa.deinit();
    const allocator = gpa.allocator();

    const opt = try simargs.parse(allocator, struct {
        add: ?[]const u8 = null,
        list: bool = false,
        clip: bool = false,
        /// Generate 7-digit codes.
        seven: bool = false,
        /// Generate 8-digit codes.
        eight: bool = false,
        hotp: bool = false,
        help: bool = false,
        version: bool = false,

        pub const __shorts__ = .{
            .add = .a,
            .list = .l,
            .clip = .c,
            .seven = .@"7",
            .eight = .@"8",
            .hotp = .t,
            .help = .h,
            .version = .v,
        };

        pub const __messages__ = .{
            .add = "Add a new key with the given name.",
            .list = "List all keys in the keychain.",
            .clip = "Copy the code to the system clipboard.",
            .seven = "Generate 7-digit codes (default: 6).",
            .eight = "Generate 8-digit codes (default: 6).",
            .hotp = "Use counter-based (HOTP) codes instead of time-based (TOTP).",
            .help = "Print help information.",
            .version = "Print version.",
        };
    }, .{
        .argument_prompt = "[name]",
        .version_string = util.get_build_info(),
    });
    defer opt.deinit();

    const digits: u8 = if (opt.options.eight) 8 else if (opt.options.seven) 7 else 6;
    const home_dir = try getHomeDir(allocator);
    defer allocator.free(home_dir);
    const keychain_path = try fs.path.join(allocator, &.{ home_dir, keychain_file_name });
    defer allocator.free(keychain_path);

    if (opt.options.add) |name| {
        // Add a new key.
        try addKey(keychain_path, name, digits, opt.options.hotp);
    } else if (opt.options.list) {
        // List all key names.
        try listKeys(allocator, keychain_path);
    } else {
        // Show code(s).
        const lookup_name: ?[]const u8 = if (opt.positional_arguments.len > 0)
            opt.positional_arguments[0]
        else
            null;
        try showCodes(allocator, keychain_path, lookup_name, opt.options.clip);
    }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// Prompts for a secret, then appends a new key entry to the keychain file.
fn addKey(
    keychain_path: []const u8,
    name: []const u8,
    digits: u8,
    is_hotp: bool,
) !void {
    // Validate name: must not contain spaces.
    if (mem.indexOfScalar(u8, name, ' ') != null) {
        std.debug.print("error: key name must not contain spaces\n", .{});
        return error.InvalidKeyName;
    }

    // Read secret from stdin.
    const stderr = std.fs.File.stderr();
    try stderr.writeAll("2fa key for ");
    try stderr.writeAll(name);
    try stderr.writeAll(": ");

    var secret_buf: [128]u8 = undefined;
    const raw_secret = try readLine(&secret_buf);
    if (raw_secret.len == 0) {
        std.debug.print("error: empty secret\n", .{});
        return error.EmptySecret;
    }

    // Uppercase and strip spaces/padding.
    var cleaned_buf: [128]u8 = undefined;
    const cleaned = cleanSecret(raw_secret, &cleaned_buf);
    if (cleaned.len == 0) {
        std.debug.print("error: invalid secret\n", .{});
        return error.InvalidSecret;
    }

    // Validate that it is valid base32.
    var decode_buf: [80]u8 = undefined;
    _ = base32Decode(cleaned, &decode_buf) catch {
        std.debug.print("error: secret is not valid base32\n", .{});
        return error.InvalidSecret;
    };

    // Build the type string, e.g. "totp", "7totp", "8hotp".
    const type_str = keyTypeString(digits, is_hotp);

    // Open / create the keychain file and append a line.
    const file = try fs.cwd().createFile(keychain_path, .{
        .truncate = false,
        .exclusive = false,
    });
    defer file.close();
    try file.seekFromEnd(0);
    var line_buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&line_buf);
    const w = fbs.writer();
    try w.print("{s} {s} {s}\n", .{ name, type_str, cleaned });
    try file.writeAll(fbs.getWritten());
}

/// Lists the names of all keys stored in the keychain file.
fn listKeys(allocator: mem.Allocator, keychain_path: []const u8) !void {
    const entries = loadKeychain(allocator, keychain_path) catch |err| switch (err) {
        error.FileNotFound => {
            // Empty keychain is fine.
            return;
        },
        else => return err,
    };
    defer freeKeychain(allocator, entries);

    const stdout = std.fs.File.stdout();
    for (entries) |entry| {
        try stdout.writeAll(entry.name);
        try stdout.writeAll("\n");
    }
}

/// Prints (and optionally copies) TOTP/HOTP codes.
/// If `name` is non-null, only the code for that key is shown.
/// Otherwise all time-based (TOTP) keys are shown.
fn showCodes(
    allocator: mem.Allocator,
    keychain_path: []const u8,
    name: ?[]const u8,
    clip: bool,
) !void {
    const entries = loadKeychain(allocator, keychain_path) catch |err| switch (err) {
        error.FileNotFound => {
            if (name) |n| {
                std.debug.print("error: no key named '{s}'\n", .{n});
                return error.KeyNotFound;
            }
            return;
        },
        else => return err,
    };
    defer freeKeychain(allocator, entries);

    const stdout = std.fs.File.stdout();

    if (name) |lookup| {
        // Single key lookup.
        for (entries) |entry| {
            if (mem.eql(u8, entry.name, lookup)) {
                const code = try computeCode(entry);
                var code_str_buf: [9]u8 = undefined;
                const code_str = formatCode(code, entry.digits, &code_str_buf);
                try stdout.writeAll(code_str);
                try stdout.writeAll("\n");
                if (clip) {
                    try copyToClipboard(allocator, code_str);
                }

                // For HOTP, persist the incremented counter.
                if (entry.is_hotp) {
                    try saveIncrementedCounter(allocator, keychain_path, entries, entry.name);
                }
                return;
            }
        }
        std.debug.print("error: no key named '{s}'\n", .{lookup});
        return error.KeyNotFound;
    }

    // Show all TOTP keys.
    for (entries) |entry| {
        if (entry.is_hotp) continue;
        const code = try computeCode(entry);
        var code_str_buf: [9]u8 = undefined;
        const code_str = formatCode(code, entry.digits, &code_str_buf);
        try stdout.writeAll(code_str);
        try stdout.writeAll("\t");
        try stdout.writeAll(entry.name);
        try stdout.writeAll("\n");
    }
}

// ---------------------------------------------------------------------------
// Keychain file I/O
// ---------------------------------------------------------------------------

/// Loads all key entries from the keychain file.
/// Caller must free with `freeKeychain`.
fn loadKeychain(allocator: mem.Allocator, path: []const u8) ![]KeyEntry {
    const data = try fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(data);

    var entries: std.ArrayList(KeyEntry) = .empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.secret);
        }
        entries.deinit(allocator);
    }

    var lines = mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const entry = parseKeychainLine(allocator, line) catch {
            std.debug.print("warning: skipping malformed keychain line: {s}\n", .{line});
            continue;
        };
        try entries.append(allocator, entry);
    }

    return entries.toOwnedSlice(allocator);
}

/// Frees the memory allocated for a keychain entry slice.
fn freeKeychain(allocator: mem.Allocator, entries: []KeyEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        allocator.free(e.secret);
    }
    allocator.free(entries);
}

/// Parses a single keychain file line into a `KeyEntry`.
/// Line format: `name [7|8]totp|[7|8]hotp base32key [counter]`
fn parseKeychainLine(allocator: mem.Allocator, line: []const u8) !KeyEntry {
    var it = mem.splitScalar(u8, line, ' ');

    const name_raw = it.next() orelse return error.MalformedLine;
    const type_raw = it.next() orelse return error.MalformedLine;
    const secret_raw = it.next() orelse return error.MalformedLine;

    // Parse type string, e.g. "totp", "7totp", "8hotp".
    var digits: u8 = 6;
    var is_hotp = false;
    var type_str = type_raw;

    if (type_str.len > 0 and type_str[0] >= '0' and type_str[0] <= '9') {
        digits = type_str[0] - '0';
        type_str = type_str[1..];
    }
    if (mem.eql(u8, type_str, "hotp")) {
        is_hotp = true;
    } else if (!mem.eql(u8, type_str, "totp")) {
        return error.UnknownKeyType;
    }

    var counter: u64 = 0;
    if (it.next()) |counter_str| {
        counter = try std.fmt.parseInt(u64, counter_str, 10);
    }

    return .{
        .name = try allocator.dupe(u8, name_raw),
        .is_hotp = is_hotp,
        .digits = digits,
        .secret = try allocator.dupe(u8, secret_raw),
        .counter = counter,
    };
}

/// Returns the type string for a key (e.g. "totp", "7totp", "8hotp").
fn keyTypeString(digits: u8, is_hotp: bool) []const u8 {
    return switch (digits) {
        7 => if (is_hotp) "7hotp" else "7totp",
        8 => if (is_hotp) "8hotp" else "8totp",
        else => if (is_hotp) "hotp" else "totp",
    };
}

/// Rewrites the keychain file with the counter incremented for the named key.
fn saveIncrementedCounter(
    allocator: mem.Allocator,
    path: []const u8,
    entries: []const KeyEntry,
    name: []const u8,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    for (entries) |entry| {
        const type_str = keyTypeString(entry.digits, entry.is_hotp);
        if (entry.is_hotp and mem.eql(u8, entry.name, name)) {
            try buf.writer(allocator).print("{s} {s} {s} {d}\n", .{
                entry.name, type_str, entry.secret, entry.counter + 1,
            });
        } else if (entry.is_hotp) {
            try buf.writer(allocator).print("{s} {s} {s} {d}\n", .{
                entry.name, type_str, entry.secret, entry.counter,
            });
        } else {
            try buf.writer(allocator).print("{s} {s} {s}\n", .{
                entry.name, type_str, entry.secret,
            });
        }
    }

    try fs.cwd().writeFile(.{
        .sub_path = path,
        .data = buf.items,
    });
}

// ---------------------------------------------------------------------------
// OTP computation
// ---------------------------------------------------------------------------

/// Computes the current OTP for a key entry.
fn computeCode(entry: KeyEntry) !u32 {
    var decode_buf: [80]u8 = undefined;
    const key_bytes = base32Decode(entry.secret, &decode_buf) catch {
        std.debug.print("error: invalid base32 secret for key '{s}'\n", .{entry.name});
        return error.InvalidSecret;
    };

    if (entry.is_hotp) {
        return hotp(key_bytes, entry.counter, entry.digits);
    } else {
        const now: u64 = @intCast(std.time.timestamp());
        const counter = now / 30;
        return hotp(key_bytes, counter, entry.digits);
    }
}

/// Computes an HOTP code (RFC 4226).
fn hotp(key: []const u8, counter: u64, digits: u8) u32 {
    // Encode counter as 8 big-endian bytes.
    var counter_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &counter_bytes, counter, .big);

    // Compute HMAC-SHA1.
    var mac: [std.crypto.auth.hmac.HmacSha1.mac_length]u8 = undefined;
    std.crypto.auth.hmac.HmacSha1.create(&mac, &counter_bytes, key);

    // Dynamic truncation (RFC 4226 §5.3).
    const offset = mac[mac.len - 1] & 0x0f;
    const p: u32 = (@as(u32, mac[offset]) & 0x7f) << 24 |
        @as(u32, mac[offset + 1]) << 16 |
        @as(u32, mac[offset + 2]) << 8 |
        @as(u32, mac[offset + 3]);

    const moduli = [_]u32{ 1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000 };
    return p % moduli[digits];
}

// ---------------------------------------------------------------------------
// Base32 decoding (RFC 4648)
// ---------------------------------------------------------------------------

/// Decodes a base32-encoded string (A-Z, 2-7, case-insensitive, no padding
/// required) into `out_buf`.  Returns the decoded bytes as a slice of `out_buf`.
fn base32Decode(input: []const u8, out_buf: []u8) ![]u8 {
    var bit_buf: u32 = 0;
    var bit_count: u8 = 0;
    var out_len: usize = 0;

    for (input) |ch| {
        const val: u32 = switch (ch) {
            'A'...'Z' => ch - 'A',
            'a'...'z' => ch - 'a',
            '2'...'7' => ch - '2' + 26,
            '=' => continue, // padding
            else => return error.InvalidBase32Character,
        };
        bit_buf = (bit_buf << 5) | val;
        bit_count += 5;
        if (bit_count >= 8) {
            bit_count -= 8;
            if (out_len >= out_buf.len) return error.OutputBufferTooSmall;
            out_buf[out_len] = @intCast((bit_buf >> @intCast(bit_count)) & 0xff);
            out_len += 1;
        }
    }

    return out_buf[0..out_len];
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Formats `code` as a zero-padded decimal string of `digits` characters.
/// `buf` must be at least `digits` bytes long.
fn formatCode(code: u32, digits: u8, buf: []u8) []u8 {
    var v = code;
    var i: usize = digits;
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast('0' + v % 10);
        v /= 10;
    }
    return buf[0..digits];
}

/// Returns the user's home directory as an allocated string.
fn getHomeDir(allocator: mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        return home;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |home| {
        return home;
    } else |_| {}
    return error.HomeNotFound;
}

/// Reads a single line from stdin into `buf` (without the trailing newline).
fn readLine(buf: []u8) ![]u8 {
    const stdin = std.fs.File.stdin();
    var len: usize = 0;
    while (len < buf.len) {
        var byte: [1]u8 = undefined;
        const n = try stdin.read(&byte);
        if (n == 0) break;
        if (byte[0] == '\n') break;
        if (byte[0] == '\r') continue;
        buf[len] = byte[0];
        len += 1;
    }
    return buf[0..len];
}

/// Strips spaces and padding from a base32 secret and uppercases it.
fn cleanSecret(input: []const u8, out: []u8) []u8 {
    var len: usize = 0;
    for (input) |ch| {
        if (ch == ' ' or ch == '=') continue;
        if (len >= out.len) break;
        out[len] = std.ascii.toUpper(ch);
        len += 1;
    }
    return out[0..len];
}

/// Copies text to the system clipboard (best-effort; no error on unsupported systems).
fn copyToClipboard(allocator: mem.Allocator, text: []const u8) !void {
    const argv: []const []const u8 = if (builtin.os.tag == .macos)
        &.{"pbcopy"}
    else
        &.{ "xclip", "-selection", "clipboard" };

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return; // clipboard tool may not be installed
    if (child.stdin) |stdin| {
        stdin.writeAll(text) catch {};
        stdin.close();
        child.stdin = null;
    }
    _ = child.wait() catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "base32 decode" {
    // RFC 4648 test vector: "foobar" encodes as "MZXW6YTBOI======".
    var buf: [16]u8 = undefined;
    const decoded = try base32Decode("MZXW6YTBOI======", &buf);
    try testing.expectEqualStrings("foobar", decoded);
}

test "base32 decode no padding" {
    var buf: [16]u8 = undefined;
    const decoded = try base32Decode("MZXW6YTBOI", &buf);
    try testing.expectEqualStrings("foobar", decoded);
}

test "base32 decode lowercase" {
    var buf: [16]u8 = undefined;
    const decoded = try base32Decode("mzxw6ytboi", &buf);
    try testing.expectEqualStrings("foobar", decoded);
}

test "hotp known value" {
    // RFC 4226 Appendix D test vectors using the secret "12345678901234567890".
    const secret = "12345678901234567890";
    // Counter 0 -> 755224
    try testing.expectEqual(@as(u32, 755224), hotp(secret, 0, 6));
    // Counter 1 -> 287082
    try testing.expectEqual(@as(u32, 287082), hotp(secret, 1, 6));
    // Counter 2 -> 359152
    try testing.expectEqual(@as(u32, 359152), hotp(secret, 2, 6));
}

test "format code" {
    var buf: [9]u8 = undefined;
    try testing.expectEqualStrings("755224", formatCode(755224, 6, &buf));
    try testing.expectEqualStrings("0000042", formatCode(42, 7, &buf));
}

test "clean secret" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("JBSWY3DPEHPK3PXP", cleanSecret("jbswy3dp ehpk3pxp", &buf));
}

test "parse keychain line totp" {
    const entry = try parseKeychainLine(testing.allocator, "github totp JBSWY3DPEHPK3PXP");
    defer {
        testing.allocator.free(entry.name);
        testing.allocator.free(entry.secret);
    }
    try testing.expectEqualStrings("github", entry.name);
    try testing.expectEqual(false, entry.is_hotp);
    try testing.expectEqual(@as(u8, 6), entry.digits);
    try testing.expectEqualStrings("JBSWY3DPEHPK3PXP", entry.secret);
    try testing.expectEqual(@as(u64, 0), entry.counter);
}

test "parse keychain line hotp with counter" {
    const entry = try parseKeychainLine(testing.allocator, "work 7hotp JBSWY3DPEHPK3PXP 42");
    defer {
        testing.allocator.free(entry.name);
        testing.allocator.free(entry.secret);
    }
    try testing.expectEqualStrings("work", entry.name);
    try testing.expectEqual(true, entry.is_hotp);
    try testing.expectEqual(@as(u8, 7), entry.digits);
    try testing.expectEqualStrings("JBSWY3DPEHPK3PXP", entry.secret);
    try testing.expectEqual(@as(u64, 42), entry.counter);
}

test "key type string" {
    try testing.expectEqualStrings("totp", keyTypeString(6, false));
    try testing.expectEqualStrings("hotp", keyTypeString(6, true));
    try testing.expectEqualStrings("7totp", keyTypeString(7, false));
    try testing.expectEqualStrings("8hotp", keyTypeString(8, true));
}
