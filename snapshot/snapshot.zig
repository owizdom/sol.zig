const std = @import("std");
const types = @import("types");
const accounts_db = @import("accounts_db");

pub const FILE_MAGIC = "SOLSNAP1";
const SNAPSHOT_FORMAT_VERSION: u16 = 3;
const SNAPSHOT_FRAME_MAGIC = "SNP1";
const ZSTD_MAGIC = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd };

const SnapshotCompression = enum(u8) {
    none = 0,
    rle = 1,
    zstd = 2,
};

pub const SnapshotError = error{
    InvalidSnapshot,
    NotFound,
    CompressionUnavailable,
    CompressionFailed,
};

pub fn writeSnapshot(
    db: *accounts_db.AccountsDb,
    slot: types.Slot,
    dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const filename = try snapshotFileName(dir, slot, allocator);
    defer allocator.free(filename);

    const listed = try db.listAccounts(allocator);
    defer accounts_db.AccountsDb.freeListedAccounts(allocator, listed);

    var raw = std.array_list.Managed(u8).init(allocator);
    defer raw.deinit();
    const writer = raw.writer();

    try writer.writeAll(FILE_MAGIC);
    try writer.writeInt(u64, slot, .little);
    try writer.writeInt(u64, listed.len, .little);

    for (listed) |entry| {
        try writer.writeAll(&entry.key.bytes);
        try writer.writeInt(u64, entry.account.lamports, .little);
        try writer.writeInt(u64, entry.account.rent_epoch, .little);
        try writer.writeByte(if (entry.account.executable) 1 else 0);
        try writer.writeAll(&entry.account.owner.bytes);
        try writer.writeInt(u64, entry.account.data.len, .little);
        try writer.writeAll(entry.account.data);
    }

    const compressed = try compressPayload(raw.items, allocator);
    defer allocator.free(compressed);

    var file = try std.fs.cwd().createFile(filename, .{ .truncate = true });
    defer file.close();
    try file.writeAll(compressed);
}

pub fn loadSnapshot(
    db: *accounts_db.AccountsDb,
    path: []const u8,
    allocator: std.mem.Allocator,
) !types.Slot {
    const snapshot_path = try resolveSnapshotPath(path, allocator);
    defer allocator.free(snapshot_path);

    const compressed = try std.fs.cwd().readFileAlloc(allocator, snapshot_path, std.math.maxInt(usize));
    defer allocator.free(compressed);

    const contents = try decompressPayload(compressed, allocator);
    defer allocator.free(contents);

    if (contents.len < FILE_MAGIC.len + 8 + 8) return SnapshotError.InvalidSnapshot;

    var offset: usize = 0;
    if (!std.mem.eql(u8, contents[0..FILE_MAGIC.len], FILE_MAGIC)) return SnapshotError.InvalidSnapshot;
    offset += FILE_MAGIC.len;

    const slot = std.mem.readInt(u64, contents[offset..][0..8], .little);
    offset += 8;

    const account_count = std.mem.readInt(u64, contents[offset..][0..8], .little);
    offset += 8;

    var i: u64 = 0;
    while (i < account_count) : (i += 1) {
        if (offset + 32 + 8 + 8 + 1 + 32 + 8 > contents.len) return SnapshotError.InvalidSnapshot;

        var key: types.Pubkey = .{ .bytes = undefined };
        @memcpy(&key.bytes, contents[offset .. offset + 32]);
        offset += 32;

        const lamports = std.mem.readInt(u64, contents[offset..][0..8], .little);
        offset += 8;

        const rent_epoch = std.mem.readInt(u64, contents[offset..][0..8], .little);
        offset += 8;

        const executable = contents[offset] != 0;
        offset += 1;

        var owner: types.Pubkey = .{ .bytes = undefined };
        @memcpy(&owner.bytes, contents[offset .. offset + 32]);
        offset += 32;

        const data_len = std.mem.readInt(u64, contents[offset..][0..8], .little);
        offset += 8;

        const data_len_usize = @as(usize, data_len);
        if (offset + data_len_usize > contents.len) return SnapshotError.InvalidSnapshot;
        const data = contents[offset .. offset + data_len_usize];
        offset += data_len_usize;

        try db.store(key, lamports, data, owner, executable, rent_epoch, slot);
    }

    return slot;
}

// Keep existing fixture APIs intact for callers that still expect them.
pub fn writeFullSnapshot(
    db: *accounts_db.AccountsDb,
    slot: types.Slot,
    dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    try writeSnapshot(db, slot, dir, allocator);
}

pub fn writeIncrementalSnapshot(
    db: *accounts_db.AccountsDb,
    _: types.Slot,
    slot: types.Slot,
    dir: []const u8,
    allocator: std.mem.Allocator,
) !void {
    try writeSnapshot(db, slot, dir, allocator);
}

fn resolveSnapshotPath(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const stat = std.fs.cwd().statFile(input) catch {
        return SnapshotError.NotFound;
    };

    return switch (stat.kind) {
        .file => allocator.dupe(u8, input),
        .directory => latestSnapshotInDir(input, allocator),
        else => SnapshotError.InvalidSnapshot,
    };
}

fn snapshotFileName(dir: []const u8, slot: types.Slot, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/snapshot-{d}.bin.zst", .{ dir, slot });
}

fn latestSnapshotInDir(dir: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var directory = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer directory.close();

    var best_slot: ?types.Slot = null;
    var best_name: ?[]u8 = null;

    var iter = directory.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "snapshot-") or !std.mem.endsWith(u8, entry.name, ".bin.zst")) continue;

        const slot = parseSlotFromSnapshotName(entry.name) orelse continue;
        if (best_slot == null or slot > best_slot.?) {
            if (best_name) |old| allocator.free(old);
            best_slot = slot;
            best_name = try std.fs.path.join(allocator, &.{ dir, entry.name });
        }
    }

    return best_name orelse SnapshotError.NotFound;
}

fn parseSlotFromSnapshotName(name: []const u8) ?types.Slot {
    if (!std.mem.startsWith(u8, name, "snapshot-") or !std.mem.endsWith(u8, name, ".bin.zst")) return null;

    const body = name["snapshot-".len .. name.len - ".bin.zst".len];
    return std.fmt.parseInt(types.Slot, body, 10) catch null;
}

pub fn compressPayload(payload: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (payload.len > 0) {
        if (compressZstdRaw(payload, allocator)) |zstd_payload| {
            return zstd_payload;
        } else |_| {}
    }

    const rle_payload = try rleCompress(payload, allocator);
    defer allocator.free(rle_payload);
    const use_rle = rle_payload.len < payload.len;

    const payload_to_store = if (use_rle) rle_payload else payload;
    const codec = if (use_rle) SnapshotCompression.rle else SnapshotCompression.none;
    const expected_len: u64 = @intCast(payload.len);
    const payload_hash = snapshotPayloadHash(payload);

    var framed = std.array_list.Managed(u8).init(allocator);
    defer framed.deinit();

    try framed.appendSlice(SNAPSHOT_FRAME_MAGIC);
    var version_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &version_buf, SNAPSHOT_FORMAT_VERSION, .little);
    try framed.appendSlice(&version_buf);
    try framed.append(@intFromEnum(codec));
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, expected_len, .little);
    try framed.appendSlice(&len_buf);
    var hash_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &hash_buf, payload_hash, .little);
    try framed.appendSlice(&hash_buf);
    try framed.appendSlice(payload_to_store);

    return framed.toOwnedSlice();
}

pub fn decompressPayload(payload: []const u8, allocator: std.mem.Allocator) ![]u8 {
    if (payload.len >= SNAPSHOT_FRAME_MAGIC.len and std.mem.eql(u8, payload[0..SNAPSHOT_FRAME_MAGIC.len], SNAPSHOT_FRAME_MAGIC)) {
        const header = SNAPSHOT_FRAME_MAGIC.len;
        if (payload.len < header + 2 + 1 + 8 + 8) return SnapshotError.InvalidSnapshot;

        const version = std.mem.readInt(u16, payload[header..][0..2], .little);
        if (version != SNAPSHOT_FORMAT_VERSION) return SnapshotError.CompressionUnavailable;

        const codec = payload[header + 2];
        const expected_uncompressed = std.mem.readInt(u64, payload[header + 3 .. header + 11], .little);
        const expected_hash = std.mem.readInt(u64, payload[header + 11 .. header + 19], .little);
        const body = payload[header + 19 ..];
        const expected_uncompressed_usize = std.math.cast(usize, expected_uncompressed) orelse return SnapshotError.InvalidSnapshot;

        const decoded = switch (codec) {
            @intFromEnum(SnapshotCompression.none) => blk: {
                if (body.len != expected_uncompressed_usize) return SnapshotError.InvalidSnapshot;
                break :blk try allocator.dupe(u8, body);
            },
            @intFromEnum(SnapshotCompression.rle) => try rleDecompress(body, expected_uncompressed, allocator),
            else => return SnapshotError.InvalidSnapshot,
        };

        if (decoded.len != expected_uncompressed_usize) return SnapshotError.InvalidSnapshot;
        if (snapshotPayloadHash(decoded) != expected_hash) return SnapshotError.InvalidSnapshot;
        return decoded;
    }
    if (payload.len >= ZSTD_MAGIC.len and std.mem.eql(u8, payload[0..ZSTD_MAGIC.len], &ZSTD_MAGIC)) {
        if (try decodeLegacyFrame(payload, allocator)) |decoded| {
            return decoded;
        }
        return decompressZstd(payload, allocator);
    }

    return allocator.dupe(u8, payload);
}

fn decodeLegacyFrame(payload: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    if (payload.len < ZSTD_MAGIC.len + 2 + 1 + 8 + 8) return null;

    const header = ZSTD_MAGIC.len;
    const version = std.mem.readInt(u16, payload[header .. header + 2], .little);
    if (version > SNAPSHOT_FORMAT_VERSION or version == 0) return null;

    const codec = payload[header + 2];
    if (codec > @intFromEnum(SnapshotCompression.rle)) return null;

    const expected_uncompressed = std.mem.readInt(u64, payload[header + 3 .. header + 11], .little);
    const expected_hash = std.mem.readInt(u64, payload[header + 11 .. header + 19], .little);
    const body = payload[header + 19 ..];
    const expected_uncompressed_usize = std.math.cast(usize, expected_uncompressed) orelse return null;

    const decoded = switch (codec) {
        @intFromEnum(SnapshotCompression.none) => blk: {
            if (body.len != expected_uncompressed_usize) return null;
            break :blk try allocator.dupe(u8, body);
        },
        @intFromEnum(SnapshotCompression.rle) => blk: {
            const decoded_try = rleDecompress(body, expected_uncompressed, allocator) catch return null;
            break :blk decoded_try;
        },
        else => return null,
    };

    if (decoded.len != expected_uncompressed_usize) return null;
    if (snapshotPayloadHash(decoded) != expected_hash) {
        allocator.free(decoded);
        return null;
    }
    return decoded;
}

fn snapshotPayloadHash(payload: []const u8) u64 {
    return std.hash.Wyhash.hash(0, payload);
}

fn rleCompress(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    if (input.len == 0) {
        return out.toOwnedSlice();
    }

    var i: usize = 0;
    while (i < input.len) {
        // Detect short runs and emit a packed repeat token only for length >= 4.
        if (i + 3 < input.len and
            input[i] == input[i + 1] and
            input[i] == input[i + 2] and
            input[i] == input[i + 3])
        {
            var run: usize = 4;
            while (i + run < input.len and run < 128 and input[i + run] == input[i]) {
                run += 1;
            }

            try out.append(0x80 | @as(u8, @intCast(run - 1)));
            try out.append(input[i]);
            i += run;
            continue;
        }

        const lit_start = i;
        while (i < input.len) {
            if (i + 3 < input.len and
                input[i] == input[i + 1] and
                input[i] == input[i + 2] and
                input[i] == input[i + 3])
            {
                break;
            }
            i += 1;
            if (i - lit_start == 128) break;
        }

        var off = lit_start;
        while (off < i) {
            const chunk = @min(128, i - off);
            try out.append(@as(u8, @intCast(chunk - 1)));
            try out.appendSlice(input[off .. off + chunk]);
            off += chunk;
        }
    }

    return out.toOwnedSlice();
}

fn compressZstdRaw(input: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Pure-Zig stream writer for a valid, checksum-less zstd single-frame stream.
    // This avoids any external dependencies while keeping wire compatibility for readers.
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice(ZSTD_MAGIC[0..]);
    // Single-segment frame, 8-byte Frame_Content_Size, no dict, no checksum.
    // FHD bits: 7-6=11 (8-byte FCS), 5=1 (Single_Segment → no Window_Descriptor), 4-0=0.
    try out.append(0xE0);
    var fcs_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &fcs_buf, @as(u64, input.len), .little);
    try out.appendSlice(&fcs_buf);

    var remaining: usize = input.len;
    var in_off: usize = 0;
    const max_block_size: usize = 0x1F_FFFF; // 2^21 - 1

    while (remaining > 0) {
        const take = @min(remaining, max_block_size);
        const is_last = remaining == take;
        try writeZstdRawBlockHeader(&out, take, is_last);
        try out.appendSlice(input[in_off .. in_off + take]);
        remaining -= take;
        in_off += take;
    }
    if (input.len == 0) {
        // Single empty raw block.
        try writeZstdRawBlockHeader(&out, 0, true);
    }
    return out.toOwnedSlice();
}

fn writeZstdRawBlockHeader(out: *std.array_list.Managed(u8), block_size: usize, last: bool) !void {
    if (block_size > 0x1F_FFFF) return SnapshotError.CompressionFailed;

    // Block header format (little-endian, 3 bytes):
    // bits[1..0]=block_type (00 = raw), bit[2]=reserved, bits[3..23]=size, bit24=last
    // In practice: raw block header is encoded as:
    // value = (block_size << 3) | (last ? 1 : 0)
    // where block_type for raw is 0.
    const block_len: u32 = @intCast(block_size);
    const header: u32 = (block_len << 3) | (if (last) @as(u32, 1) else 0);
    try out.append(@as(u8, @truncate(header)));
    try out.append(@as(u8, @truncate(header >> 8)));
    try out.append(@as(u8, @truncate(header >> 16)));
}

fn rleDecompress(body: []const u8, expected_len: u64, allocator: std.mem.Allocator) ![]u8 {
    var out = try allocator.alloc(u8, @as(usize, @intCast(expected_len)));
    errdefer allocator.free(out);

    var out_i: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        if (out_i >= out.len) return SnapshotError.InvalidSnapshot;

        const token = body[i];
        i += 1;
        if (i > body.len) return SnapshotError.InvalidSnapshot;

        const len = @as(usize, token & 0x7f) + 1;
        if (token & 0x80 != 0) {
            if (i >= body.len) return SnapshotError.InvalidSnapshot;
            const value = body[i];
            i += 1;
            if (out_i + len > out.len) return SnapshotError.InvalidSnapshot;
            const end = out_i + len;
            @memset(out[out_i..end], value);
            out_i = end;
            continue;
        }

        if (i + len > body.len) return SnapshotError.InvalidSnapshot;
        if (out_i + len > out.len) return SnapshotError.InvalidSnapshot;
        @memcpy(out[out_i .. out_i + len], body[i .. i + len]);
        out_i += len;
        i += len;
    }

    if (out_i != out.len) return SnapshotError.InvalidSnapshot;
    return out;
}

fn decompressZstd(payload: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var input: std.Io.Reader = .fixed(payload);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var zstd_stream: std.compress.zstd.Decompress = .init(&input, &.{}, .{});
    _ = try zstd_stream.reader.streamRemaining(&out.writer);
    if (zstd_stream.err != null) return SnapshotError.CompressionFailed;

    return out.toOwnedSlice();
}

test "snapshot write/load roundtrip" {
    var db = accounts_db.AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    const key = types.Pubkey{ .bytes = [_]u8{0xAA} ** 32 };
    const owner = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    try db.store(key, 12, &[_]u8{1, 2, 3, 4}, owner, false, 0, 1);

    const dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "/tmp/solana_snapshot_test_{d}",
        .{std.time.milliTimestamp()},
    );
    defer std.testing.allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};

    const slot: types.Slot = 77;
    try writeSnapshot(&db, slot, dir, std.testing.allocator);
    const snapshot_path = try snapshotFileName(dir, slot, std.testing.allocator);
    defer std.testing.allocator.free(snapshot_path);

    const snapshot_contents = try std.fs.cwd().readFileAlloc(
        std.testing.allocator,
        snapshot_path,
        std.math.maxInt(usize),
    );
    defer std.testing.allocator.free(snapshot_contents);

    if (snapshot_contents.len >= SNAPSHOT_FRAME_MAGIC.len and
        std.mem.eql(u8, snapshot_contents[0..SNAPSHOT_FRAME_MAGIC.len], SNAPSHOT_FRAME_MAGIC))
    {
        // legacy local frame format
    } else {
        try std.testing.expect(snapshot_contents.len >= ZSTD_MAGIC.len);
        try std.testing.expect(std.mem.eql(u8, snapshot_contents[0..ZSTD_MAGIC.len], ZSTD_MAGIC));
    }

    var loaded = accounts_db.AccountsDb.init(std.testing.allocator);
    defer loaded.deinit();
    const loaded_slot = try loadSnapshot(&loaded, dir, std.testing.allocator);
    try std.testing.expectEqual(slot, loaded_slot);
    const loaded_account = loaded.get(key).?;
    try std.testing.expectEqual(@as(u64, 12), loaded_account.lamports);
    try std.testing.expectEqualSlices(u8, &[_]u8{1, 2, 3, 4}, loaded_account.data);
}
