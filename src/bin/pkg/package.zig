const std = @import("std");
const manifest = @import("./Manifest.zig");
const MultihashFunction = manifest.MultihashFunction;
const multihash_function = manifest.multihash_function;
const multihash_hex_digest_len = manifest.multihash_hex_digest_len;

pub const Hash = struct {
    /// Maximum size of a package hash. Unused bytes at the end are
    /// filled with zeroes.
    bytes: [max_len]u8,

    pub const Algo = std.crypto.hash.sha2.Sha256;
    pub const Digest = [Algo.digest_length]u8;

    /// Example: "nnnn-vvvv-hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
    pub const max_len = 32 + 1 + 32 + 1 + (32 + 32 + 200) / 6;

    pub fn fromSlice(s: []const u8) Hash {
        var result: Hash = undefined;
        @memcpy(result.bytes[0..s.len], s);
        @memset(result.bytes[s.len..], 0);
        return result;
    }

    pub fn toSlice(ph: *const Hash) []const u8 {
        var end: usize = ph.bytes.len;
        while (true) {
            end -= 1;
            if (ph.bytes[end] != 0) return ph.bytes[0 .. end + 1];
        }
    }

    pub fn eql(a: *const Hash, b: *const Hash) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    /// Distinguishes whether the legacy multihash format is being stored here.
    pub fn isOld(h: *const Hash) bool {
        if (h.bytes.len < 2) return false;
        const their_multihash_func = std.fmt.parseInt(u8, h.bytes[0..2], 16) catch return false;
        if (@as(MultihashFunction, @enumFromInt(their_multihash_func)) != multihash_function) return false;
        if (h.toSlice().len != multihash_hex_digest_len) return false;
        return std.mem.indexOfScalar(u8, &h.bytes, '-') == null;
    }

    test isOld {
        const h: Hash = .fromSlice("1220138f4aba0c01e66b68ed9e1e1e74614c06e4743d88bc58af4f1c3dd0aae5fea7");
        try std.testing.expect(h.isOld());
    }

    /// Produces "$name-$semver-$hashplus".
    /// * name is the name field from build.zig.zon, asserted to be at most 32
    ///   bytes and assumed be a valid zig identifier
    /// * semver is the version field from build.zig.zon, asserted to be at
    ///   most 32 bytes
    /// * hashplus is the following 33-byte array, base64 encoded using -_ to make
    ///   it filesystem safe:
    ///   - (4 bytes) LE u32 Package ID
    ///   - (4 bytes) LE u32 total decompressed size in bytes, overflow saturated
    ///   - (25 bytes) truncated SHA-256 digest of hashed files of the package
    pub fn init(digest: Digest, name: []const u8, ver: []const u8, id: u32, size: u32) Hash {
        var result: Hash = undefined;
        var buf: std.ArrayListUnmanaged(u8) = .initBuffer(&result.bytes);
        buf.appendSliceAssumeCapacity(name);
        buf.appendAssumeCapacity('-');
        buf.appendSliceAssumeCapacity(ver);
        buf.appendAssumeCapacity('-');
        var hashplus: [33]u8 = undefined;
        std.mem.writeInt(u32, hashplus[0..4], id, .little);
        std.mem.writeInt(u32, hashplus[4..8], size, .little);
        hashplus[8..].* = digest[0..25].*;
        _ = std.base64.url_safe_no_pad.Encoder.encode(buf.addManyAsArrayAssumeCapacity(44), &hashplus);
        @memset(buf.unusedCapacitySlice(), 0);
        return result;
    }

    /// Produces a unique hash based on the path provided. The result should
    /// not be user-visible.
    pub fn initPath(sub_path: []const u8, is_global: bool) Hash {
        var result: Hash = .{ .bytes = @splat(0) };
        var i: usize = 0;
        if (is_global) {
            result.bytes[0] = '/';
            i += 1;
        }
        if (i + sub_path.len <= result.bytes.len) {
            @memcpy(result.bytes[i..][0..sub_path.len], sub_path);
            return result;
        }
        var bin_digest: [Algo.digest_length]u8 = undefined;
        Algo.hash(sub_path, &bin_digest, .{});
        _ = std.fmt.bufPrint(result.bytes[i..], "{}", .{std.fmt.fmtSliceHexLower(&bin_digest)}) catch unreachable;
        return result;
    }
};
