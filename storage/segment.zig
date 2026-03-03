// SegmentStore: pure Zig disk-backed account store.
//
// Architecture:
//   - WAL (storage/wal.zig)    — crash-safe write-ahead log, fsynced on every write
//   - Segments                 — append-only flat files (up to SEGMENT_SIZE bytes each)
//   - In-memory index          — HashMap(Pubkey → Pointer{seg_id, offset, len})
//
// On startup, the WAL is replayed to rebuild the index (crash recovery).
// Compaction merges old segments and checkpoints the WAL.
//
// This is the zero-C-dependency replacement for librocksdb.
const std = @import("std");
const WAL = @import("wal.zig").WAL;

const SEGMENT_SIZE: usize  = 64 * 1024 * 1024; // 64 MB per segment file
const VALUE_HDR_SIZE: usize = 4 + 4;            // key_len(4) + val_len(4)

pub const Pointer = struct {
    seg_id: u32,
    offset: u32,
    len:    u32, // length of value bytes only
};

const Segment = struct {
    id:     u32,
    file:   std.fs.File,
    size:   usize, // bytes written so far

    fn init(id: u32, path: []const u8) !Segment {
        const f = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false });
        const stat = try f.stat();
        return Segment{ .id = id, .file = f, .size = stat.size };
    }

    fn deinit(self: *Segment) void {
        self.file.close();
    }

    fn isFull(self: *const Segment) bool {
        return self.size >= SEGMENT_SIZE;
    }

    /// Append a value blob and return the byte offset where it starts.
    fn append(self: *Segment, data: []const u8) !usize {
        const offset = self.size;
        try self.file.seekTo(offset);
        try self.file.writeAll(data);
        self.size += data.len;
        return offset;
    }

    /// Read `len` bytes starting at `offset`.
    fn readAt(self: *Segment, offset: usize, len: usize, allocator: std.mem.Allocator) ![]u8 {
        const buf = try allocator.alloc(u8, len);
        errdefer allocator.free(buf);
        _ = try self.file.pread(buf, offset);
        return buf;
    }
};

pub const SegmentStore = struct {
    allocator:  std.mem.Allocator,
    dir:        []const u8,           // directory for segment files + WAL
    wal:        WAL,
    segments:   std.ArrayList(Segment),
    index:      std.AutoHashMap([32]u8, Pointer), // pubkey → disk location
    mu:         std.Thread.Mutex,
    compact_mu: std.Thread.Mutex,

    /// Open (or create) a SegmentStore rooted at `dir`.
    pub fn open(dir: []const u8, allocator: std.mem.Allocator) !SegmentStore {
        try std.fs.cwd().makePath(dir);

        const wal_path = try std.fs.path.join(allocator, &.{ dir, "wal.log" });
        defer allocator.free(wal_path);

        var store = SegmentStore{
            .allocator  = allocator,
            .dir        = try allocator.dupe(u8, dir),
            .wal        = try WAL.open(wal_path, allocator),
            .segments   = .empty,
            .index      = std.AutoHashMap([32]u8, Pointer).init(allocator),
            .mu         = .{},
            .compact_mu = .{},
        };

        // Replay WAL to rebuild index.
        try store.wal.replay(&store, replayPut, replayDelete);

        return store;
    }

    pub fn deinit(self: *SegmentStore) void {
        self.wal.deinit();
        for (self.segments.items) |*seg| seg.deinit();
        self.segments.deinit(self.allocator);
        self.index.deinit();
        self.allocator.free(self.dir);
    }

    // ── Public API (same shape as RocksDb) ──────────────────────────────────

    pub fn put(self: *SegmentStore, key: [32]u8, value: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        // 1. Write to WAL first (crash safety).
        try self.wal.put(&key, value);

        // 2. Write to segment file.
        const ptr = try self.appendToSegment(key, value);

        // 3. Update in-memory index.
        try self.index.put(key, ptr);
    }

    pub fn get(self: *SegmentStore, key: [32]u8, allocator: std.mem.Allocator) !?[]u8 {
        self.mu.lock();
        defer self.mu.unlock();

        const ptr = self.index.get(key) orelse return null;
        const seg = self.segmentById(ptr.seg_id) orelse return null;
        return try seg.readAt(ptr.offset, ptr.len, allocator);
    }

    pub fn delete(self: *SegmentStore, key: [32]u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        try self.wal.delete(&key);
        _ = self.index.remove(key);
        // The segment data becomes garbage-collected at the next compaction.
    }

    /// Compact: rewrite live entries to a fresh segment, checkpoint WAL.
    pub fn compact(self: *SegmentStore) !void {
        self.compact_mu.lock();
        defer self.compact_mu.unlock();

        // Snapshot index under lock.
        self.mu.lock();
        var snap = try self.allocator.alloc(struct { key: [32]u8, ptr: Pointer }, self.index.count());
        defer self.allocator.free(snap);
        var snap_idx: usize = 0;
        {
            var it = self.index.iterator();
            while (it.next()) |entry| {
                snap[snap_idx] = .{ .key = entry.key_ptr.*, .ptr = entry.value_ptr.* };
                snap_idx += 1;
            }
        }
        self.mu.unlock();

        // Rewrite live entries to a new segment.
        const new_seg_id = @as(u32, @intCast(self.segments.items.len));
        const new_path = try self.segmentPath(new_seg_id);
        defer self.allocator.free(new_path);
        var new_seg = try Segment.init(new_seg_id, new_path);

        var new_index = std.AutoHashMap([32]u8, Pointer).init(self.allocator);
        for (snap[0..snap_idx]) |entry| {
            const seg = self.segmentById(entry.ptr.seg_id) orelse continue;
            const value = seg.readAt(entry.ptr.offset, entry.ptr.len, self.allocator) catch continue;
            defer self.allocator.free(value);
            const offset = try new_seg.append(value);
            try new_index.put(entry.key, .{
                .seg_id = new_seg_id,
                .offset = @intCast(offset),
                .len    = entry.ptr.len,
            });
        }

        // Atomically swap in new segment + index.
        self.mu.lock();
        defer self.mu.unlock();

        // Close and remove old segments.
        for (self.segments.items) |*seg| {
            const old_path = self.segmentPath(seg.id) catch continue;
            defer self.allocator.free(old_path);
            seg.deinit();
            std.fs.cwd().deleteFile(old_path) catch {};
        }
        self.segments.clearRetainingCapacity();
        try self.segments.append(self.allocator, new_seg);

        self.index.deinit();
        self.index = new_index;

        // Checkpoint WAL: truncate to just the checkpoint marker.
        try self.wal.checkpoint();
    }

    // ── Iterator ────────────────────────────────────────────────────────────

    pub const Iterator = struct {
        store:   *SegmentStore,
        keys:    [][32]u8,
        pos:     usize,
        alloc:   std.mem.Allocator,

        pub fn deinit(self: *Iterator) void {
            self.alloc.free(self.keys);
        }

        pub fn next(self: *Iterator) ?[32]u8 {
            if (self.pos >= self.keys.len) return null;
            const k = self.keys[self.pos];
            self.pos += 1;
            return k;
        }
    };

    pub fn iterator(self: *SegmentStore) !Iterator {
        self.mu.lock();
        defer self.mu.unlock();
        var keys = try self.allocator.alloc([32]u8, self.index.count());
        var i: usize = 0;
        var it = self.index.keyIterator();
        while (it.next()) |k| {
            keys[i] = k.*;
            i += 1;
        }
        return Iterator{ .store = self, .keys = keys, .pos = 0, .alloc = self.allocator };
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    fn currentSegment(self: *SegmentStore) !*Segment {
        if (self.segments.items.len > 0) {
            const last = &self.segments.items[self.segments.items.len - 1];
            if (!last.isFull()) return last;
        }
        // Create a new segment.
        const id = @as(u32, @intCast(self.segments.items.len));
        const path = try self.segmentPath(id);
        defer self.allocator.free(path);
        const seg = try Segment.init(id, path);
        try self.segments.append(self.allocator, seg);
        return &self.segments.items[self.segments.items.len - 1];
    }

    fn appendToSegment(self: *SegmentStore, key: [32]u8, value: []const u8) !Pointer {
        _ = key;
        const seg = try self.currentSegment();
        const offset = try seg.append(value);
        return Pointer{
            .seg_id = seg.id,
            .offset = @intCast(offset),
            .len    = @intCast(value.len),
        };
    }

    fn segmentById(self: *SegmentStore, id: u32) ?*Segment {
        for (self.segments.items) |*seg| {
            if (seg.id == id) return seg;
        }
        return null;
    }

    fn segmentPath(self: *SegmentStore, id: u32) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/seg_{d:0>6}.dat", .{ self.dir, id });
    }

    // WAL replay callbacks (called with *SegmentStore as ctx).
    fn replayPut(self: *SegmentStore, key: []const u8, value: []const u8) !void {
        if (key.len != 32) return;
        // Write value to a segment, update index.
        const ptr = try self.appendToSegment(key[0..32].*, value);
        try self.index.put(key[0..32].*, ptr);
    }

    fn replayDelete(self: *SegmentStore, key: []const u8) !void {
        if (key.len != 32) return;
        _ = self.index.remove(key[0..32].*);
    }
};

test "segment store put/get/delete round-trip" {
    const dir = "/tmp/sol_seg_test";
    defer std.fs.cwd().deleteTree(dir) catch {};

    var store = try SegmentStore.open(dir, std.testing.allocator);
    defer store.deinit();

    const key = [_]u8{0x01} ** 32;
    const val = "hello, segment store";

    try store.put(key, val);

    const got = try store.get(key, std.testing.allocator);
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualSlices(u8, val, got.?);

    try store.delete(key);
    const gone = try store.get(key, std.testing.allocator);
    try std.testing.expect(gone == null);
}

test "segment store survives crash-replay" {
    const dir = "/tmp/sol_seg_crash_test";
    defer std.fs.cwd().deleteTree(dir) catch {};

    const key = [_]u8{0xAB} ** 32;
    const val = "crash-safe value";

    // Write and close.
    {
        var store = try SegmentStore.open(dir, std.testing.allocator);
        try store.put(key, val);
        store.deinit();
    }

    // Re-open and read back via WAL replay.
    {
        var store = try SegmentStore.open(dir, std.testing.allocator);
        defer store.deinit();
        const got = try store.get(key, std.testing.allocator);
        try std.testing.expect(got != null);
        defer std.testing.allocator.free(got.?);
        try std.testing.expectEqualSlices(u8, val, got.?);
    }
}

test "segment store compaction preserves live data" {
    const dir = "/tmp/sol_seg_compact_test";
    defer std.fs.cwd().deleteTree(dir) catch {};

    var store = try SegmentStore.open(dir, std.testing.allocator);
    defer store.deinit();

    const key1 = [_]u8{0x01} ** 32;
    const key2 = [_]u8{0x02} ** 32;

    try store.put(key1, "live");
    try store.put(key2, "dead");
    try store.delete(key2);
    try store.compact();

    const got1 = try store.get(key1, std.testing.allocator);
    try std.testing.expect(got1 != null);
    defer std.testing.allocator.free(got1.?);
    try std.testing.expectEqualSlices(u8, "live", got1.?);

    const got2 = try store.get(key2, std.testing.allocator);
    try std.testing.expect(got2 == null);
}
