// AccountsDB: slot-versioned account store.
// Supports RocksDB (PERSISTENT=true), HashMap (PERSISTENT=false), or
// the pure-Zig SegmentStore (SEGMENT_STORE=true — zero C dependencies).
const std = @import("std");
const types   = @import("types");
const rocksdb = @import("rocksdb");
const segment_store = @import("storage/segment");

// Backend selection:
//   SEGMENT_STORE=true  → pure-Zig WAL+segment files (recommended — zero C deps)
//   PERSISTENT=true     → RocksDB (requires librocksdb)
//   else                → in-memory HashMap
pub const SEGMENT_STORE = true;
pub const PERSISTENT    = false; // kept for reference — overridden by SEGMENT_STORE
const PERSISTENT_PATH   = "accounts_db";
const SEGMENT_PATH      = "accounts_seg";

const ACCOUNT_VALUE_FIXED_SIZE = 8 + 8 + 1 + 32 + 8; // lamports+rent+exec+owner+datalen

/// An account as stored in the DB (owns its data allocation).
pub const StoredAccount = struct {
    lamports:   types.Lamports,
    data:        []u8,            // heap-allocated; owned by AccountsDb
    owner:       types.Pubkey,
    executable:  bool,
    rent_epoch:  types.Epoch,
    write_slot:  types.Slot,
};

pub const ListedAccount = struct {
    key: types.Pubkey,
    account: StoredAccount,
};

/// Slot-indexed set of modified pubkeys (for snapshots / fork rollback).
pub const SlotDelta = std.array_list.Managed([32]u8);

pub const AccountsDb = struct {
    allocator:   std.mem.Allocator,
    seg:         if (SEGMENT_STORE) segment_store.SegmentStore else void,
    rdb:         if (!SEGMENT_STORE and PERSISTENT) rocksdb.RocksDb else void,
    mem:         if (!SEGMENT_STORE and !PERSISTENT) std.AutoHashMap([32]u8, StoredAccount) else void,
    slot_deltas: std.AutoHashMap(types.Slot, SlotDelta),
    mu:          std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) AccountsDb {
        return .{
            .allocator   = allocator,
            .seg         = if (SEGMENT_STORE)
                (segment_store.SegmentStore.open(SEGMENT_PATH, allocator) catch @panic("SegmentStore.open failed"))
            else
                {},
            .rdb         = if (!SEGMENT_STORE and PERSISTENT)
                (rocksdb.RocksDb.open(PERSISTENT_PATH) catch @panic("RocksDb.open failed"))
            else
                {},
            .mem         = if (!SEGMENT_STORE and !PERSISTENT)
                std.AutoHashMap([32]u8, StoredAccount).init(allocator)
            else
                {},
            .slot_deltas = std.AutoHashMap(types.Slot, SlotDelta).init(allocator),
            .mu          = .{},
        };
    }

    pub fn deinit(self: *AccountsDb) void {
        if (SEGMENT_STORE) {
            self.seg.deinit();
        } else if (PERSISTENT) {
            self.rdb.close();
        } else {
            var it = self.mem.iterator();
            while (it.next()) |entry| self.allocator.free(entry.value_ptr.data);
            self.mem.deinit();
        }

        var dit = self.slot_deltas.iterator();
        while (dit.next()) |entry| entry.value_ptr.deinit();
        self.slot_deltas.deinit();
    }

    fn recordSlotMeta(self: *AccountsDb, slot: types.Slot, pubkey: types.Pubkey) !void {
        if (SEGMENT_STORE) return; // segment store doesn't use CF-keyed slot meta
        if (!PERSISTENT) return;
        var slot_key = try self.allocator.alloc(u8, 8 + 32);
        std.mem.writeInt(u64, slot_key[0..8], slot, .little);
        @memcpy(slot_key[8..], &pubkey.bytes);
        defer self.allocator.free(slot_key);
        try self.rdb.putInCF(self.rdb.slot_meta_cf, slot_key, &.{});
    }

    // ── Getters ─────────────────────────────────────────────────────────────

    pub fn get(self: *AccountsDb, pubkey: types.Pubkey) ?StoredAccount {
        self.mu.lock();
        defer self.mu.unlock();

        if (SEGMENT_STORE) {
            const raw = self.seg.get(pubkey.bytes, self.allocator) catch null orelse return null;
            defer self.allocator.free(raw);
            return decodeAccountValue(raw, self.allocator) catch null;
        } else if (PERSISTENT) {
            const raw = self.rdb.get(pubkey.bytes[0..], self.allocator) catch null orelse return null;
            defer self.allocator.free(raw);
            return decodeAccountValue(raw, self.allocator) catch null;
        } else {
            const entry = self.mem.get(pubkey.bytes) orelse return null;
            return entry;
        }
    }

    pub fn getPtr(self: *AccountsDb, pubkey: types.Pubkey) ?*StoredAccount {
        if (SEGMENT_STORE or PERSISTENT) return null;
        return self.mem.getPtr(pubkey.bytes);
    }

    pub fn getLamports(self: *const AccountsDb, pubkey: types.Pubkey) u64 {
        const self_mut: *AccountsDb = @constCast(self);
        self_mut.mu.lock();
        defer self_mut.mu.unlock();

        if (SEGMENT_STORE) {
            const raw = self_mut.seg.get(pubkey.bytes, self_mut.allocator) catch null orelse return 0;
            defer self_mut.allocator.free(raw);
            const acct = decodeAccountValue(raw, self_mut.allocator) catch return 0;
            defer self_mut.allocator.free(acct.data);
            return acct.lamports;
        } else if (PERSISTENT) {
            if (self_mut.rdb.get(pubkey.bytes[0..], self_mut.allocator) catch null) |raw| {
                defer self_mut.allocator.free(raw);
                const acct = decodeAccountValue(raw, self_mut.allocator) catch return 0;
                defer self_mut.allocator.free(acct.data);
                return acct.lamports;
            }
            return 0;
        } else {
            const a = self_mut.mem.get(pubkey.bytes) orelse return 0;
            return a.lamports;
        }
    }

    // ── Setters ─────────────────────────────────────────────────────────────

    /// Store an account, copying `data`. Overwrites any existing entry.
    pub fn store(
        self:   *AccountsDb,
        pubkey: types.Pubkey,
        lamports:   u64,
        data:        []const u8,
        owner:       types.Pubkey,
        executable:  bool,
        rent_epoch:  types.Epoch,
        slot:        types.Slot,
    ) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (SEGMENT_STORE) {
            const encoded = try encodeAccountValue(self.allocator, lamports, data, owner, executable, rent_epoch);
            defer self.allocator.free(encoded);
            try self.seg.put(pubkey.bytes, encoded);
        } else if (PERSISTENT) {
            const encoded = try encodeAccountValue(self.allocator, lamports, data, owner, executable, rent_epoch);
            defer self.allocator.free(encoded);
            try self.rdb.put(pubkey.bytes[0..], encoded);
            try self.recordSlotMeta(slot, pubkey);
        } else {
            const data_copy = try self.allocator.dupe(u8, data);
            if (self.mem.getPtr(pubkey.bytes)) |existing| {
                self.allocator.free(existing.data);
            }
            try self.mem.put(pubkey.bytes, .{
                .lamports   = lamports,
                .data        = data_copy,
                .owner       = owner,
                .executable  = executable,
                .rent_epoch  = rent_epoch,
                .write_slot  = slot,
            });
        }

        // Track the delta.
        const res = try self.slot_deltas.getOrPut(slot);
        if (!res.found_existing) res.value_ptr.* = SlotDelta.init(self.allocator);
        try res.value_ptr.append(pubkey.bytes);
    }

    /// Delete an account.
    pub fn delete(self: *AccountsDb, pubkey: types.Pubkey, slot: types.Slot) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (SEGMENT_STORE) {
            try self.seg.delete(pubkey.bytes);
        } else if (PERSISTENT) {
            try self.rdb.delete(pubkey.bytes[0..]);
            try self.recordSlotMeta(slot, pubkey);
        } else {
            if (self.mem.fetchRemove(pubkey.bytes)) |kv| {
                self.allocator.free(kv.value.data);
            }
        }

        const res = try self.slot_deltas.getOrPut(slot);
        if (!res.found_existing) res.value_ptr.* = SlotDelta.init(self.allocator);
        try res.value_ptr.append(pubkey.bytes);
    }

    // ── Lamport helpers ──────────────────────────────────────────────────────

    pub fn creditLamports(self: *AccountsDb, pubkey: types.Pubkey, amount: u64, slot: types.Slot) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (SEGMENT_STORE) {
            var lamports: u64 = 0;
            var owner      = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
            var executable = false;
            var rent_epoch: types.Epoch = 0;
            var value_data = try self.allocator.dupe(u8, &.{});

            if (try self.seg.get(pubkey.bytes, self.allocator)) |raw| {
                defer self.allocator.free(raw);
                const decoded = try decodeAccountValue(raw, self.allocator);
                defer self.allocator.free(decoded.data);
                lamports   = decoded.lamports;
                owner      = decoded.owner;
                executable = decoded.executable;
                rent_epoch = decoded.rent_epoch;
                self.allocator.free(value_data);
                value_data = try self.allocator.dupe(u8, decoded.data);
            }

            const new_lamps = lamports +| amount;
            const encoded = try encodeAccountValue(self.allocator, new_lamps, value_data, owner, executable, rent_epoch);
            self.allocator.free(value_data);
            defer self.allocator.free(encoded);
            try self.seg.put(pubkey.bytes, encoded);
        } else if (PERSISTENT) {
            var lamports: u64 = 0;
            var owner      = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
            var executable = false;
            var rent_epoch: types.Epoch = 0;
            var value_data = try self.allocator.dupe(u8, &.{});

            if (try self.rdb.get(&pubkey.bytes, self.allocator)) |raw| {
                defer self.allocator.free(raw);
                const decoded = try decodeAccountValue(raw, self.allocator);
                defer self.allocator.free(decoded.data);
                lamports   = decoded.lamports;
                owner      = decoded.owner;
                executable = decoded.executable;
                rent_epoch = decoded.rent_epoch;
                self.allocator.free(value_data);
                value_data = try self.allocator.dupe(u8, decoded.data);
            }

            const new_lamps = lamports +| amount;
            const encoded = try encodeAccountValue(self.allocator, new_lamps, value_data, owner, executable, rent_epoch);
            self.allocator.free(value_data);
            defer self.allocator.free(encoded);
            try self.rdb.put(&pubkey.bytes, encoded);
            try self.recordSlotMeta(slot, pubkey);
        } else {
            const res = try self.mem.getOrPut(pubkey.bytes);
            if (!res.found_existing) {
                res.value_ptr.* = .{
                    .lamports   = 0,
                    .data        = try self.allocator.dupe(u8, &.{}),
                    .owner       = types.Pubkey{ .bytes = [_]u8{0} ** 32 },
                    .executable  = false,
                    .rent_epoch  = 0,
                    .write_slot  = slot,
                };
            }
            res.value_ptr.lamports = res.value_ptr.lamports +| amount;
            res.value_ptr.write_slot = slot;
        }
    }

    pub fn debitLamports(self: *AccountsDb, pubkey: types.Pubkey, amount: u64, slot: types.Slot) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (SEGMENT_STORE) {
            const raw = try self.seg.get(pubkey.bytes, self.allocator) orelse return error.AccountNotFound;
            defer self.allocator.free(raw);
            const decoded = try decodeAccountValue(raw, self.allocator);
            defer self.allocator.free(decoded.data);
            if (decoded.lamports < amount) return error.InsufficientFunds;
            const new_lamps = decoded.lamports -| amount;
            const encoded = try encodeAccountValue(self.allocator, new_lamps, decoded.data, decoded.owner, decoded.executable, decoded.rent_epoch);
            defer self.allocator.free(encoded);
            try self.seg.put(pubkey.bytes, encoded);
        } else if (PERSISTENT) {
            const raw = try self.rdb.get(pubkey.bytes[0..], self.allocator) orelse return error.AccountNotFound;
            defer self.allocator.free(raw);
            const decoded = try decodeAccountValue(raw, self.allocator);
            defer self.allocator.free(decoded.data);
            if (decoded.lamports < amount) return error.InsufficientFunds;
            const new_lamps = decoded.lamports -| amount;
            const encoded = try encodeAccountValue(self.allocator, new_lamps, decoded.data, decoded.owner, decoded.executable, decoded.rent_epoch);
            defer self.allocator.free(encoded);
            try self.rdb.put(pubkey.bytes[0..], encoded);
            try self.recordSlotMeta(slot, pubkey);
        } else {
            const entry = self.mem.getPtr(pubkey.bytes) orelse return error.AccountNotFound;
            if (entry.lamports < amount) return error.InsufficientFunds;
            entry.lamports -= amount;
            entry.write_slot = slot;
        }
    }

    // ── Hash ─────────────────────────────────────────────────────────────────

    /// Compute a hash over all accounts (deterministic given the same state).
    pub fn hash(self: *AccountsDb) types.Hash {
        self.mu.lock();
        defer self.mu.unlock();

        var acc = [_]u8{0} ** 32;

        if (SEGMENT_STORE) {
            var iter = self.seg.iterator() catch return .{ .bytes = acc };
            defer iter.deinit();
            while (iter.next()) |key| {
                const raw = self.seg.get(key, self.allocator) catch continue orelse continue;
                defer self.allocator.free(raw);
                var pair_hash = std.crypto.hash.sha2.Sha256.init(.{});
                pair_hash.update(&key);
                pair_hash.update(raw);
                var pair_buf: [32]u8 = undefined;
                pair_hash.final(&pair_buf);
                for (acc, 0..) |_, i| acc[i] ^= pair_buf[i];
            }
        } else if (PERSISTENT) {
            var iter = self.rdb.accountIterator();
            defer iter.deinit();
            iter.seekToFirst();
            while (iter.valid()) : (iter.next()) {
                const key   = iter.key()   orelse break;
                const value = iter.value() orelse break;
                var pair_hash = std.crypto.hash.sha2.Sha256.init(.{});
                pair_hash.update(key);
                pair_hash.update(value);
                var pair_buf: [32]u8 = undefined;
                pair_hash.final(&pair_buf);
                for (acc, 0..) |_, i| acc[i] ^= pair_buf[i];
            }
        } else {
            var it = self.mem.iterator();
            while (it.next()) |entry| {
                const acct = entry.value_ptr;
                const encoded = encodeAccountValue(self.allocator, acct.lamports, acct.data, acct.owner, acct.executable, acct.rent_epoch) catch continue;
                defer self.allocator.free(encoded);
                var pair_hash = std.crypto.hash.sha2.Sha256.init(.{});
                pair_hash.update(&entry.key_ptr.*);
                pair_hash.update(encoded);
                var pair_buf: [32]u8 = undefined;
                pair_hash.final(&pair_buf);
                for (acc, 0..) |_, i| acc[i] ^= pair_buf[i];
            }
        }
        return .{ .bytes = acc };
    }

    /// Return pubkeys modified in a given slot.
    pub fn slotDelta(self: *AccountsDb, slot: types.Slot) ?[]const [32]u8 {
        const d = self.slot_deltas.get(slot) orelse return null;
        return d.items;
    }

    /// Return a snapshot of all accounts for read-only queries.
    pub fn listAccounts(self: *AccountsDb, allocator: std.mem.Allocator) ![]ListedAccount {
        var out = std.array_list.Managed(ListedAccount).init(allocator);
        errdefer {
            for (out.items) |*item| allocator.free(item.account.data);
            out.deinit();
        }

        self.mu.lock();
        defer self.mu.unlock();

        if (SEGMENT_STORE) {
            var iter = try self.seg.iterator();
            defer iter.deinit();
            while (iter.next()) |key| {
                const raw = self.seg.get(key, allocator) catch continue orelse continue;
                defer allocator.free(raw);
                const acct = decodeAccountValue(raw, allocator) catch continue;
                try out.append(.{
                    .key     = .{ .bytes = key },
                    .account = acct,
                });
            }
        } else if (PERSISTENT) {
            var iter = self.rdb.accountIterator();
            defer iter.deinit();
            iter.seekToFirst();
            while (iter.valid()) : (iter.next()) {
                const key   = iter.key()   orelse continue;
                const value = iter.value() orelse continue;
                if (key.len != 32) continue;
                const acct = decodeAccountValue(value, self.allocator) catch continue;
                try out.append(.{
                    .key = .{ .bytes = key[0..32].* },
                    .account = acct,
                });
            }
        } else {
            var it = self.mem.iterator();
            while (it.next()) |entry| {
                const account_copy = try self.allocator.dupe(u8, entry.value_ptr.data);
                try out.append(.{
                    .key = .{ .bytes = entry.key_ptr.* },
                    .account = .{
                        .lamports   = entry.value_ptr.lamports,
                        .data        = account_copy,
                        .owner       = entry.value_ptr.owner,
                        .executable  = entry.value_ptr.executable,
                        .rent_epoch  = entry.value_ptr.rent_epoch,
                        .write_slot  = entry.value_ptr.write_slot,
                    },
                });
            }
        }

        return out.toOwnedSlice();
    }

    pub fn freeListedAccounts(
        allocator: std.mem.Allocator,
        listed: []ListedAccount,
    ) void {
        for (listed) |*entry| allocator.free(entry.account.data);
        allocator.free(listed);
    }
};

fn encodeAccountValue(
    allocator: std.mem.Allocator,
    lamports: u64,
    data: []const u8,
    owner: types.Pubkey,
    executable: bool,
    rent_epoch: types.Epoch,
) ![]u8 {
    var output = try allocator.alloc(u8, ACCOUNT_VALUE_FIXED_SIZE + data.len);
    var i: usize = 0;

    writeU64Le(output[i .. i + 8], lamports);   i += 8;
    writeU64Le(output[i .. i + 8], rent_epoch); i += 8;
    output[i] = if (executable) 1 else 0;       i += 1;
    @memcpy(output[i .. i + 32], &owner.bytes); i += 32;
    writeU64Le(output[i .. i + 8], data.len);   i += 8;
    @memcpy(output[i..], data);
    return output;
}

fn decodeAccountValue(raw: []const u8, allocator: std.mem.Allocator) !StoredAccount {
    if (raw.len < ACCOUNT_VALUE_FIXED_SIZE) return error.AccountNotFound;

    var i: usize = 0;
    const lamports   = readU64Le(raw[i .. i + 8]); i += 8;
    const rent_epoch = readU64Le(raw[i .. i + 8]); i += 8;
    const executable = raw[i] != 0;                i += 1;

    var owner_bytes: [32]u8 = undefined;
    @memcpy(&owner_bytes, raw[i .. i + 32]); i += 32;

    const data_len       = readU64Le(raw[i .. i + 8]); i += 8;
    const data_len_usize = @as(usize, data_len);
    if (data_len_usize > raw.len - i) return error.AccountNotFound;

    return .{
        .lamports   = lamports,
        .data        = try allocator.dupe(u8, raw[i .. i + data_len_usize]),
        .owner       = .{ .bytes = owner_bytes },
        .executable  = executable,
        .rent_epoch  = rent_epoch,
        .write_slot  = 0,
    };
}

fn writeU64Le(dst: []u8, value: u64) void {
    dst[0] = @intCast((value >>  0) & 0xff);
    dst[1] = @intCast((value >>  8) & 0xff);
    dst[2] = @intCast((value >> 16) & 0xff);
    dst[3] = @intCast((value >> 24) & 0xff);
    dst[4] = @intCast((value >> 32) & 0xff);
    dst[5] = @intCast((value >> 40) & 0xff);
    dst[6] = @intCast((value >> 48) & 0xff);
    dst[7] = @intCast((value >> 56) & 0xff);
}

fn readU64Le(raw: []const u8) u64 {
    return @as(u64, raw[0])
        | (@as(u64, raw[1]) << 8)
        | (@as(u64, raw[2]) << 16)
        | (@as(u64, raw[3]) << 24)
        | (@as(u64, raw[4]) << 32)
        | (@as(u64, raw[5]) << 40)
        | (@as(u64, raw[6]) << 48)
        | (@as(u64, raw[7]) << 56);
}

test "store and retrieve" {
    var db = AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    const pk    = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    const owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    try db.store(pk, 1_000_000, &[_]u8{}, owner, false, 0, 1);

    const got = db.get(pk).?;
    defer if (SEGMENT_STORE or PERSISTENT) {} else {};
    try std.testing.expectEqual(@as(u64, 1_000_000), got.lamports);
}

test "debit lamports" {
    var db = AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    const pk    = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    const owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    try db.store(pk, 5_000, &[_]u8{}, owner, false, 0, 1);
    try db.debitLamports(pk, 3_000, 1);
    try std.testing.expectEqual(@as(u64, 2_000), db.getLamports(pk));
}
