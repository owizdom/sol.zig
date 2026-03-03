// Solana sysvars: well-known on-chain accounts that expose cluster state.
const std = @import("std");
const types = @import("types");

// Comptime base58 decode -> [32]u8 (used to derive canonical sysvar IDs).
fn b58(comptime s: []const u8) [32]u8 {
    @setEvalBranchQuota(1_000_000);
    const alpha = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    var table = [_]u8{0xFF} ** 128;
    for (alpha, 0..) |c, i| table[c] = @intCast(i);

    // Decode base58 string into a big integer stored as LSB-first bytes.
    var buf = [_]u32{0} ** 48;
    var len: usize = 0;
    for (s) |c| {
        var carry: u32 = table[c];
        var j: usize = 0;
        while (j < len or carry > 0) : (j += 1) {
            carry += buf[j] * 58;
            buf[j] = carry % 256;
            carry /= 256;
        }
        len = j;
    }

    // Convert LSB-first buf -> big-endian [32]u8.
    var out = [_]u8{0} ** 32;
    var i: usize = 0;
    while (i < len and i < 32) : (i += 1) {
        out[31 - i] = @intCast(buf[i]);
    }
    return out;
}

// ── Canonical sysvar pubkeys ──────────────────────────────────────────────────

pub const CLOCK_ID: types.Pubkey = .{
    .bytes = b58("SysvarC1ock11111111111111111111111111111111"),
};
pub const RENT_ID: types.Pubkey = .{
    .bytes = b58("SysvarRent111111111111111111111111111111111"),
};
pub const SLOT_HASHES_ID: types.Pubkey = .{
    .bytes = b58("SysvarS1otHashes111111111111111111111111111"),
};
pub const EPOCH_SCHEDULE_ID: types.Pubkey = .{
    .bytes = b58("SysvarEpochSchedu1e111111111111111111111111"),
};
pub const STAKE_HISTORY_ID: types.Pubkey = .{
    .bytes = b58("SysvarStakeHistory1111111111111111111111111"),
};
pub const INSTRUCTIONS_ID: types.Pubkey = .{
    .bytes = b58("Sysvar1nstructions1111111111111111111111111"),
};

// ── Sysvar data structures ────────────────────────────────────────────────────

/// SysvarClock — current cluster time.
pub const Clock = struct {
    slot: types.Slot,
    epoch_start_timestamp: i64,
    epoch: types.Epoch,
    leader_schedule_epoch: types.Epoch,
    unix_timestamp: i64,

    pub const SIZE: usize = 40;

    pub fn serialize(self: Clock, buf: *[SIZE]u8) void {
        std.mem.writeInt(u64, buf[0..8],   self.slot, .little);
        std.mem.writeInt(i64, buf[8..16],  self.epoch_start_timestamp, .little);
        std.mem.writeInt(u64, buf[16..24], self.epoch, .little);
        std.mem.writeInt(u64, buf[24..32], self.leader_schedule_epoch, .little);
        std.mem.writeInt(i64, buf[32..40], self.unix_timestamp, .little);
    }

    pub fn deserialize(buf: *const [SIZE]u8) Clock {
        return .{
            .slot                  = std.mem.readInt(u64, buf[0..8],   .little),
            .epoch_start_timestamp = std.mem.readInt(i64, buf[8..16],  .little),
            .epoch                 = std.mem.readInt(u64, buf[16..24], .little),
            .leader_schedule_epoch = std.mem.readInt(u64, buf[24..32], .little),
            .unix_timestamp        = std.mem.readInt(i64, buf[32..40], .little),
        };
    }
};

/// SysvarRent — rent configuration.
pub const Rent = struct {
    lamports_per_byte_year: u64,
    exemption_threshold: f64, // years of rent for exemption
    burn_percent: u8,

    pub const DEFAULT: Rent = .{
        .lamports_per_byte_year = 3_480,
        .exemption_threshold    = 2.0,
        .burn_percent           = 50,
    };

    /// Minimum balance for rent exemption given data size in bytes.
    pub fn minimumBalance(self: Rent, data_len: usize) u64 {
        const bytes = @as(f64, @floatFromInt(128 + data_len));
        const years: f64 = self.exemption_threshold;
        const rate: f64 = @floatFromInt(self.lamports_per_byte_year);
        return @intFromFloat(bytes * years * rate);
    }

    pub const SIZE: usize = 17;

    pub fn serialize(self: Rent, buf: *[SIZE]u8) void {
        std.mem.writeInt(u64, buf[0..8], self.lamports_per_byte_year, .little);
        const bits = @as(u64, @bitCast(self.exemption_threshold));
        std.mem.writeInt(u64, buf[8..16], bits, .little);
        buf[16] = self.burn_percent;
    }
};

/// SysvarEpochSchedule — slot/epoch timing parameters.
pub const EpochSchedule = struct {
    slots_per_epoch: u64,
    leader_schedule_slot_offset: u64,
    warmup: bool,
    first_normal_epoch: u64,
    first_normal_slot: u64,

    pub const DEFAULT: EpochSchedule = .{
        .slots_per_epoch              = 432_000,
        .leader_schedule_slot_offset  = 432_000,
        .warmup                       = true,
        .first_normal_epoch           = 14,
        .first_normal_slot            = 524_256,
    };

    pub fn epochForSlot(self: EpochSchedule, slot: types.Slot) types.Epoch {
        if (!self.warmup or slot >= self.first_normal_slot) {
            return (slot - self.first_normal_slot) / self.slots_per_epoch + self.first_normal_epoch;
        }
        // During warmup, epochs are shorter
        var epoch: types.Epoch = 0;
        var first_slot: u64 = 0;
        var len: u64 = self.slots_per_epoch >> 16;
        while (first_slot + len <= slot) {
            first_slot += len;
            epoch += 1;
            if (len < self.slots_per_epoch) len *= 2;
        }
        return epoch;
    }

    pub fn slotsInEpoch(self: EpochSchedule, epoch: types.Epoch) u64 {
        if (!self.warmup or epoch >= self.first_normal_epoch) {
            return self.slots_per_epoch;
        }
        return self.slots_per_epoch >> @intCast(self.first_normal_epoch - epoch);
    }

    pub fn firstSlotInEpoch(self: EpochSchedule, epoch: types.Epoch) u64 {
        if (!self.warmup or epoch >= self.first_normal_epoch) {
            return (epoch - self.first_normal_epoch) * self.slots_per_epoch + self.first_normal_slot;
        }
        var slot: u64 = 0;
        var e: u64 = 0;
        while (e < epoch) : (e += 1) slot += self.slotsInEpoch(e);
        return slot;
    }
};

/// SlotHashes sysvar — last 512 slot hashes (slot, hash) pairs.
pub const SlotHashes = struct {
    entries: std.array_list.Managed(SlotHash),

    pub const SlotHash = struct { slot: types.Slot, hash: types.Hash };

    pub fn init(allocator: std.mem.Allocator) SlotHashes {
        return .{ .entries = std.array_list.Managed(SlotHash).init(allocator) };
    }

    pub fn deinit(self: *SlotHashes) void {
        self.entries.deinit();
    }

    pub fn add(self: *SlotHashes, slot: types.Slot, hash: types.Hash) !void {
        try self.entries.insert(0, .{ .slot = slot, .hash = hash });
        if (self.entries.items.len > 512) _ = self.entries.pop();
    }

    pub fn get(self: *const SlotHashes, slot: types.Slot) ?types.Hash {
        for (self.entries.items) |e| {
            if (e.slot == slot) return e.hash;
        }
        return null;
    }
};

test "rent minimum balance" {
    const rent = Rent.DEFAULT;
    const bal = rent.minimumBalance(0);
    try std.testing.expect(bal > 0);
    // More data = more rent
    try std.testing.expect(rent.minimumBalance(100) > rent.minimumBalance(0));
}

test "epoch schedule" {
    const es = EpochSchedule.DEFAULT;
    try std.testing.expectEqual(@as(u64, 432_000), es.slotsInEpoch(100));
}
