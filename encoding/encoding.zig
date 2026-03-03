const std = @import("std");

/// Encode `value` as Solana compact-u16 into `buf`.
/// Returns the number of bytes written (1, 2, or 3).
///
/// Encoding:
///   value < 0x0080  -> 1 byte
///   value < 0x4000  -> 2 bytes
///   otherwise       -> 3 bytes
pub fn writeCompactU16(value: u16, buf: []u8) usize {
    if (value < 0x80) {
        buf[0] = @intCast(value);
        return 1;
    } else if (value < 0x4000) {
        buf[0] = @intCast((value & 0x7F) | 0x80);
        buf[1] = @intCast(value >> 7);
        return 2;
    } else {
        buf[0] = @intCast((value & 0x7F) | 0x80);
        buf[1] = @intCast(((value >> 7) & 0x7F) | 0x80);
        buf[2] = @intCast(value >> 14);
        return 3;
    }
}

/// Decode a compact-u16 from `buf`.
/// Sets `*bytes_read` to the number of bytes consumed.
pub fn readCompactU16(buf: []const u8, bytes_read: *usize) !u16 {
    if (buf.len == 0) return error.EndOfBuffer;
    var result: u16 = 0;
    var shift: u8 = 0;
    var i: usize = 0;
    while (i < 3 and i < buf.len) : (i += 1) {
        const byte = buf[i];
        result |= @as(u16, byte & 0x7F) << @intCast(shift);
        if (byte & 0x80 == 0) {
            bytes_read.* = i + 1;
            return result;
        }
        shift += 7;
    }
    return error.InvalidEncoding;
}

test "compact-u16: single byte values" {
    var buf: [3]u8 = undefined;
    var n: usize = undefined;

    try std.testing.expectEqual(@as(usize, 1), writeCompactU16(0, &buf));
    try std.testing.expectEqual(@as(u16, 0), try readCompactU16(&buf, &n));
    try std.testing.expectEqual(@as(usize, 1), n);

    try std.testing.expectEqual(@as(usize, 1), writeCompactU16(127, &buf));
    try std.testing.expectEqual(@as(u16, 127), try readCompactU16(&buf, &n));
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "compact-u16: two byte values" {
    var buf: [3]u8 = undefined;
    var n: usize = undefined;

    try std.testing.expectEqual(@as(usize, 2), writeCompactU16(128, &buf));
    try std.testing.expectEqual(@as(u16, 128), try readCompactU16(&buf, &n));
    try std.testing.expectEqual(@as(usize, 2), n);

    try std.testing.expectEqual(@as(usize, 2), writeCompactU16(0x3FFF, &buf));
    try std.testing.expectEqual(@as(u16, 0x3FFF), try readCompactU16(&buf, &n));
}

test "compact-u16: three byte values" {
    var buf: [3]u8 = undefined;
    var n: usize = undefined;

    try std.testing.expectEqual(@as(usize, 3), writeCompactU16(0x4000, &buf));
    try std.testing.expectEqual(@as(u16, 0x4000), try readCompactU16(&buf, &n));
    try std.testing.expectEqual(@as(usize, 3), n);

    try std.testing.expectEqual(@as(usize, 3), writeCompactU16(0xFFFF, &buf));
    try std.testing.expectEqual(@as(u16, 0xFFFF), try readCompactU16(&buf, &n));
}
