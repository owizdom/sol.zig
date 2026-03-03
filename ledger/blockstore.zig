const std = @import("std");
const types = @import("types");
const shred = @import("net/shred");
const snapshot = @import("snapshot");

pub const MAX_LEDGER_SLOTS: types.Slot = 432_000;

pub const StoredBlock = struct {
    slot: types.Slot,
    parent_slot: types.Slot,
    hash: types.Hash,
    parent_hash: ?types.Hash,
    payload: []const u8,
};

pub const Error = error{SlotMismatch};

pub const BlockStore = struct {
    allocator: std.mem.Allocator,
    by_slot: std.AutoHashMap(types.Slot, StoredBlock),
    ordered_slots: std.array_list.Managed(types.Slot),
    mu: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) BlockStore {
        return .{
            .allocator = allocator,
            .by_slot = std.AutoHashMap(types.Slot, StoredBlock).init(allocator),
            .ordered_slots = std.array_list.Managed(types.Slot).init(allocator),
            .mu = .{},
        };
    }

    pub fn deinit(self: *BlockStore) void {
        var it = self.by_slot.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.payload);
        }
        self.by_slot.deinit();
        self.ordered_slots.deinit();
    }

    pub fn size(self: *BlockStore) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.by_slot.count();
    }

    pub fn has(self: *BlockStore, slot: types.Slot) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.by_slot.get(slot) != null;
    }

    pub fn put(
        self: *BlockStore,
        slot: types.Slot,
        parent_slot: types.Slot,
        hash: types.Hash,
        parent_hash: ?types.Hash,
        payload: []const u8,
    ) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.by_slot.fetchRemove(slot)) |old| {
            self.allocator.free(old.value.payload);
        } else {
            try self.ordered_slots.append(slot);
            self.sortOrderedSlots();
        }

        const compressed = try compressPayload(payload, self.allocator);
        defer self.allocator.free(compressed);

        const payload_copy = try self.allocator.dupe(u8, compressed);
        try self.by_slot.put(slot, .{
            .slot = slot,
            .parent_slot = parent_slot,
            .hash = hash,
            .parent_hash = parent_hash,
            .payload = payload_copy,
        });
    }

    /// Collect all payloads from shreds into one block and store under the shred slot.
    pub fn putShreds(
        self: *BlockStore,
        shreds: []const shred.Shred,
        parent_slot: types.Slot,
        hash: types.Hash,
        parent_hash: ?types.Hash,
    ) !void {
        if (shreds.len == 0) return;

        const slot = shreds[0].slot();
        for (shreds) |s| {
            if (s.slot() != slot) return error.SlotMismatch;
        }

        var payload = std.array_list.Managed(u8).init(self.allocator);
        defer payload.deinit();

        for (shreds) |s| {
            try payload.appendSlice(s.payload());
        }

        try self.put(slot, parent_slot, hash, parent_hash, payload.items);
    }

    pub fn get(self: *BlockStore, slot: types.Slot) ?StoredBlock {
        self.mu.lock();
        defer self.mu.unlock();
        const block = self.by_slot.get(slot) orelse return null;
        return block;
    }

    /// Latest slot currently stored, if any.
    pub fn latestSlot(self: *BlockStore) ?types.Slot {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.ordered_slots.items.len == 0) return null;

        var current: types.Slot = self.ordered_slots.items[0];
        for (self.ordered_slots.items[1..]) |s| {
            if (s > current) current = s;
        }
        return current;
    }

    /// Remove blocks older than `slot - MAX_LEDGER_SLOTS`.
    pub fn pruneOlderThan(self: *BlockStore, slot: types.Slot) void {
        self.mu.lock();
        defer self.mu.unlock();

        const cutoff = if (slot <= MAX_LEDGER_SLOTS) 0 else slot - MAX_LEDGER_SLOTS;

        var next = std.array_list.Managed(types.Slot).init(self.allocator);
        defer next.deinit();

        for (self.ordered_slots.items) |s| {
            if (s >= cutoff) {
                next.append(s) catch unreachable;
            } else if (self.by_slot.fetchRemove(s)) |entry| {
                self.allocator.free(entry.value.payload);
            }
        }

        self.ordered_slots.deinit();
        self.ordered_slots = next;
    }

    fn sortOrderedSlots(self: *BlockStore) void {
        std.mem.sort(types.Slot, self.ordered_slots.items, {}, struct {
            fn lt(_: void, a: types.Slot, b: types.Slot) bool {
                return a < b;
            }
        }.lt);
    }
};

fn compressPayload(payload: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return try snapshot.compressPayload(payload, allocator);
}

fn decompressPayload(payload: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return try snapshot.decompressPayload(payload, allocator);
}

test "blockstore put/get/prune" {
    var bs = BlockStore.init(std.testing.allocator);
    defer bs.deinit();

    const h1 = types.Hash{ .bytes = [_]u8{0x11} ** 32 };
    try bs.put(1, 0, h1, null, &[_]u8{1, 2, 3});
    try bs.put(2, 1, h1, h1, &[_]u8{4, 5, 6});

    const got = bs.get(1).?;
    try std.testing.expectEqual(@as(types.Slot, 1), got.slot);
    const raw_payload = try decompressPayload(got.payload, std.testing.allocator);
    defer std.testing.allocator.free(raw_payload);
    try std.testing.expectEqual(@as(usize, 3), raw_payload.len);

    try std.testing.expectEqual(@as(usize, 2), bs.size());
    bs.pruneOlderThan(2);
    try std.testing.expect(!bs.has(1));
    try std.testing.expect(bs.has(2));
}
