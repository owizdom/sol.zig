// WAL: crash-safe write-ahead log for the pure-Zig account store.
//
// Record format (little-endian):
//   [4]  magic  = 0x57_41_4C_47  ("WALG")
//   [1]  kind   = 0 (put) | 1 (delete) | 2 (checkpoint)
//   [4]  key_len
//   [4]  val_len  (0 for delete)
//   [key_len]  key bytes
//   [val_len]  value bytes
//   [4]  crc32  over all preceding bytes of this record
//
// On boot, replay() reads the entire log and invokes a callback for each
// put/delete entry, allowing the caller to rebuild the in-memory index.
// After compaction the WAL is truncated via checkpoint().
const std = @import("std");

/// Read exactly buf.len bytes; returns how many bytes were actually read.
/// Returns an error only if the underlying read itself fails.
fn readFull(file: std.fs.File, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try file.read(buf[total..]);
        if (n == 0) break;
        total += n;
    }
    return total;
}

const MAGIC:     u32 = 0x474C_4157; // "WALG" LE
const KIND_PUT:  u8  = 0;
const KIND_DEL:  u8  = 1;
const KIND_CKPT: u8  = 2;

pub const WAL = struct {
    file:      std.fs.File,
    allocator: std.mem.Allocator,

    pub fn open(path: []const u8, allocator: std.mem.Allocator) !WAL {
        const file = try std.fs.cwd().createFile(path, .{
            .read      = true,
            .truncate  = false,
        });
        // Seek to end for appending.
        try file.seekFromEnd(0);
        return WAL{ .file = file, .allocator = allocator };
    }

    pub fn deinit(self: *WAL) void {
        self.file.close();
    }

    /// Append a put record and fsync.
    pub fn put(self: *WAL, key: []const u8, value: []const u8) !void {
        var buf = try self.allocator.alloc(u8, 4 + 1 + 4 + 4 + key.len + value.len + 4);
        defer self.allocator.free(buf);
        var off: usize = 0;
        std.mem.writeInt(u32, buf[off..][0..4], MAGIC, .little); off += 4;
        buf[off] = KIND_PUT; off += 1;
        std.mem.writeInt(u32, buf[off..][0..4], @intCast(key.len), .little); off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], @intCast(value.len), .little); off += 4;
        @memcpy(buf[off..off + key.len], key); off += key.len;
        @memcpy(buf[off..off + value.len], value); off += value.len;
        const crc = crc32(buf[0..off]);
        std.mem.writeInt(u32, buf[off..][0..4], crc, .little);
        try self.file.writeAll(buf);
        try self.file.sync();
    }

    /// Append a delete record and fsync.
    pub fn delete(self: *WAL, key: []const u8) !void {
        var buf = try self.allocator.alloc(u8, 4 + 1 + 4 + 4 + key.len + 4);
        defer self.allocator.free(buf);
        var off: usize = 0;
        std.mem.writeInt(u32, buf[off..][0..4], MAGIC, .little); off += 4;
        buf[off] = KIND_DEL; off += 1;
        std.mem.writeInt(u32, buf[off..][0..4], @intCast(key.len), .little); off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], 0, .little); off += 4;
        @memcpy(buf[off..off + key.len], key); off += key.len;
        const crc = crc32(buf[0..off]);
        std.mem.writeInt(u32, buf[off..][0..4], crc, .little);
        try self.file.writeAll(buf);
        try self.file.sync();
    }

    /// Replay the WAL from the beginning, invoking callbacks for each valid record.
    /// `put_cb`    is called for each put record with (key, value) slices.
    /// `delete_cb` is called for each delete record with the key slice.
    /// Corrupted or truncated records at the tail are silently ignored.
    pub fn replay(
        self: *WAL,
        ctx: anytype,
        put_cb:    fn (@TypeOf(ctx), []const u8, []const u8) anyerror!void,
        delete_cb: fn (@TypeOf(ctx), []const u8)             anyerror!void,
    ) !void {
        try self.file.seekTo(0);

        while (true) {
            // Read header (4+1+4+4 = 13 bytes).
            var hdr: [13]u8 = undefined;
            const n = readFull(self.file, &hdr) catch break;
            if (n < 13) break;

            const magic    = std.mem.readInt(u32, hdr[0..4],  .little);
            const kind     = hdr[4];
            const key_len  = std.mem.readInt(u32, hdr[5..9],  .little);
            const val_len  = std.mem.readInt(u32, hdr[9..13], .little);

            if (magic != MAGIC) break; // corrupt tail

            const payload_len = @as(usize, key_len) + @as(usize, val_len);
            const payload = try self.allocator.alloc(u8, payload_len + 4);
            defer self.allocator.free(payload);

            const m = readFull(self.file, payload) catch break;
            if (m < payload_len + 4) break;

            // Verify CRC.
            const stored_crc = std.mem.readInt(u32, payload[payload_len..][0..4], .little);
            const check_buf = try self.allocator.alloc(u8, 13 + payload_len);
            defer self.allocator.free(check_buf);
            @memcpy(check_buf[0..13], &hdr);
            @memcpy(check_buf[13..13 + payload_len], payload[0..payload_len]);
            const computed_crc = crc32(check_buf);
            if (computed_crc != stored_crc) break; // corrupt tail

            const key   = payload[0..key_len];
            const value = payload[key_len..payload_len];

            switch (kind) {
                KIND_PUT  => try put_cb(ctx, key, value),
                KIND_DEL  => try delete_cb(ctx, key),
                KIND_CKPT => {}, // checkpoint marker — skip
                else      => break,
            }
        }

        // Seek back to end for future appends.
        try self.file.seekFromEnd(0);
    }

    /// Write a checkpoint marker and truncate the file to just that marker.
    /// Call after all data has been flushed to segment files.
    pub fn checkpoint(self: *WAL) !void {
        try self.file.seekTo(0);
        var buf: [4 + 1 + 4 + 4 + 4]u8 = undefined;
        var off: usize = 0;
        std.mem.writeInt(u32, buf[off..][0..4], MAGIC, .little); off += 4;
        buf[off] = KIND_CKPT; off += 1;
        std.mem.writeInt(u32, buf[off..][0..4], 0, .little); off += 4;
        std.mem.writeInt(u32, buf[off..][0..4], 0, .little); off += 4;
        const crc = crc32(buf[0..off]);
        std.mem.writeInt(u32, buf[off..][0..4], crc, .little); off += 4;
        try self.file.writeAll(buf[0..off]);
        try self.file.setEndPos(off);
        try self.file.sync();
    }
};

// CRC-32/ISO-HDLC (standard Ethernet CRC).
fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    for (data) |byte| {
        crc ^= byte;
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            if (crc & 1 != 0) {
                crc = (crc >> 1) ^ 0xEDB8_8320;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc ^ 0xFFFF_FFFF;
}

test "wal put/delete/replay round-trip" {
    const tmp_path = "/tmp/sol_wal_test.log";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var wal = try WAL.open(tmp_path, std.testing.allocator);
    defer wal.deinit();

    try wal.put("key1", "value1");
    try wal.put("key2", "value2value2");
    try wal.delete("key1");

    const Cb = struct {
        puts: usize = 0,
        dels: usize = 0,
        fn putCb(self: *@This(), k: []const u8, v: []const u8) !void {
            _ = k; _ = v; self.puts += 1;
        }
        fn delCb(self: *@This(), k: []const u8) !void {
            _ = k; self.dels += 1;
        }
    };
    var cb = Cb{};
    try wal.replay(&cb, Cb.putCb, Cb.delCb);
    try std.testing.expectEqual(@as(usize, 2), cb.puts);
    try std.testing.expectEqual(@as(usize, 1), cb.dels);
}

test "wal checkpoint truncates log" {
    const tmp_path = "/tmp/sol_wal_ckpt_test.log";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    var wal = try WAL.open(tmp_path, std.testing.allocator);
    defer wal.deinit();

    try wal.put("a", "b");
    try wal.put("c", "d");
    try wal.checkpoint();

    // After checkpoint, replay should see zero put/delete events.
    const Cb = struct {
        count: usize = 0,
        fn putCb(self: *@This(), k: []const u8, v: []const u8) !void {
            _ = k; _ = v; self.count += 1;
        }
        fn delCb(self: *@This(), k: []const u8) !void {
            _ = k; self.count += 1;
        }
    };
    var cb = Cb{};
    try wal.replay(&cb, Cb.putCb, Cb.delCb);
    try std.testing.expectEqual(@as(usize, 0), cb.count);
}
