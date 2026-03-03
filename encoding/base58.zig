const std = @import("std");

const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

// Reverse lookup: ASCII char -> base58 digit (0xFF = invalid)
const DECODE_TABLE: [128]u8 = blk: {
    var t = [_]u8{0xFF} ** 128;
    for (ALPHABET, 0..) |c, i| t[c] = @intCast(i);
    break :blk t;
};

/// Encode `input` bytes as base58 into `out`.
/// `out` must be at least ceil(input.len * 1.37) bytes.
/// For a 32-byte pubkey: 44 bytes is enough.
/// Returns the encoded slice.
pub fn encode(input: []const u8, out: []u8) ![]u8 {
    // Count leading zero bytes -> become leading '1' chars
    var leading_zeros: usize = 0;
    for (input) |b| {
        if (b != 0) break;
        leading_zeros += 1;
    }

    // Accumulate base-58 digits in a scratch buffer (stored LSB-first)
    var digits = [_]u8{0} ** 128;
    var digits_len: usize = 0;

    for (input) |byte| {
        var carry: u32 = byte;
        var j: usize = 0;
        while (j < digits_len or carry != 0) : (j += 1) {
            carry += @as(u32, digits[j]) * 256;
            digits[j] = @intCast(carry % 58);
            carry /= 58;
        }
        digits_len = j;
    }

    const total = leading_zeros + digits_len;
    if (out.len < total) return error.BufferTooSmall;

    // Leading '1's
    @memset(out[0..leading_zeros], '1');

    // Digits in reverse order (MSB first)
    for (0..digits_len) |i| {
        out[leading_zeros + i] = ALPHABET[digits[digits_len - 1 - i]];
    }

    return out[0..total];
}

/// Decode a base58 string into `out`.
/// Returns the decoded slice.
pub fn decode(input: []const u8, out: []u8) ![]u8 {
    // Count leading '1's -> become zero bytes
    var leading_ones: usize = 0;
    for (input) |c| {
        if (c != '1') break;
        leading_ones += 1;
    }

    // Accumulate base-256 bytes in a scratch buffer (stored LSB-first)
    var buf = [_]u8{0} ** 128;
    var buf_len: usize = 0;

    for (input) |c| {
        if (c > 127) return error.InvalidCharacter;
        const digit = DECODE_TABLE[c];
        if (digit == 0xFF) return error.InvalidCharacter;
        var carry: u32 = digit;
        var j: usize = 0;
        while (j < buf_len or carry != 0) : (j += 1) {
            carry += @as(u32, buf[j]) * 58;
            buf[j] = @intCast(carry % 256);
            carry /= 256;
        }
        buf_len = j;
    }

    const total = leading_ones + buf_len;
    if (out.len < total) return error.BufferTooSmall;

    @memset(out[0..leading_ones], 0);

    for (0..buf_len) |i| {
        out[leading_ones + i] = buf[buf_len - 1 - i];
    }

    return out[0..total];
}

test "encode all-zeros" {
    const zeros = [_]u8{0} ** 32;
    var buf: [64]u8 = undefined;
    const enc = try encode(&zeros, &buf);
    // 32 zero bytes -> 32 leading '1' chars, nothing else
    try std.testing.expectEqual(@as(usize, 32), enc.len);
    for (enc) |c| try std.testing.expectEqual(@as(u8, '1'), c);
}

test "encode/decode roundtrip" {
    const data = [_]u8{ 0x00, 0x01, 0xAB, 0xFF };
    var enc_buf: [8]u8 = undefined;
    var dec_buf: [4]u8 = undefined;
    const enc = try encode(&data, &enc_buf);
    const dec = try decode(enc, &dec_buf);
    try std.testing.expectEqualSlices(u8, &data, dec);
}

test "encode/decode 32-byte pubkey roundtrip" {
    var pk: [32]u8 = undefined;
    for (&pk, 0..) |*b, i| b.* = @intCast(i);
    var enc_buf: [64]u8 = undefined;
    var dec_buf: [32]u8 = undefined;
    const enc = try encode(&pk, &enc_buf);
    try std.testing.expect(enc.len <= 44);
    const dec = try decode(enc, &dec_buf);
    try std.testing.expectEqualSlices(u8, &pk, dec);
}
