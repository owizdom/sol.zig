const std = @import("std");
const types = @import("types");
const sysvar = @import("sysvar");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Schedule = struct {
    _slots_per_epoch: u64,
    _leader_schedule_slot_offset: u64,

    pub fn init() Schedule {
        return .{
            ._slots_per_epoch = 432_000,
            ._leader_schedule_slot_offset = 432_000,
        };
    }

    pub fn slotsPerEpoch(self: *const Schedule) types.Slot {
        _ = self;
        return 432_000;
    }

    pub fn deinit(self: *Schedule) void {
        _ = self;
    }
};

pub const LeaderScheduleSnapshot = struct {
    epoch: types.Epoch,
    first_slot: types.Slot,
    slots_in_epoch: u64,
    validators: []types.Pubkey,
    stakes: []u64,
    cumulative_stakes: []u64,
    total_stake: u64,
};

pub fn captureLeaderScheduleSnapshot(
    epoch: types.Epoch,
    validators: []const types.Pubkey,
    stakes: []const u64,
    allocator: std.mem.Allocator,
) !LeaderScheduleSnapshot {
    const count = if (validators.len < stakes.len) validators.len else stakes.len;
    const es = sysvar.EpochSchedule.DEFAULT;

    var snapshot = LeaderScheduleSnapshot{
        .epoch = epoch,
        .first_slot = es.firstSlotInEpoch(epoch),
        .slots_in_epoch = es.slotsInEpoch(epoch),
        .validators = if (count == 0) &[_]types.Pubkey{} else try allocator.alloc(types.Pubkey, count),
        .stakes = if (count == 0) &[_]u64{} else try allocator.alloc(u64, count),
        .cumulative_stakes = if (count == 0) &[_]u64{} else try allocator.alloc(u64, count),
        .total_stake = 0,
    };

    if (count == 0) return snapshot;

    var total_stake: u128 = 0;
    for (0..count) |i| {
        snapshot.validators[i] = validators[i];
        snapshot.stakes[i] = stakes[i];
        total_stake +|= stakes[i];
        snapshot.cumulative_stakes[i] = if (total_stake > std.math.maxInt(u64))
            std.math.maxInt(u64)
        else
            @as(u64, @intCast(total_stake));
    }

    if (total_stake > std.math.maxInt(u64)) {
        snapshot.total_stake = std.math.maxInt(u64);
    } else {
        snapshot.total_stake = @intCast(total_stake);
    }

    return snapshot;
}

pub fn freeLeaderScheduleSnapshot(snapshot: *LeaderScheduleSnapshot, allocator: std.mem.Allocator) void {
    if (snapshot.validators.len > 0) allocator.free(snapshot.validators);
    if (snapshot.stakes.len > 0) allocator.free(snapshot.stakes);
    if (snapshot.cumulative_stakes.len > 0) allocator.free(snapshot.cumulative_stakes);
    snapshot.* = undefined;
}

pub fn computeLeaderScheduleFromSnapshot(
    snapshot: *const LeaderScheduleSnapshot,
    allocator: std.mem.Allocator,
) ![]usize {
    const count = snapshot.validators.len;
    const schedule_len = @as(usize, @intCast(snapshot.slots_in_epoch));
    var result = try allocator.alloc(usize, schedule_len);

    if (count == 0) return result;

    var slot = snapshot.first_slot;
    for (0..result.len) |i| {
        result[i] = leaderForSlotFromSnapshot(snapshot, slot).?;
        slot += 1;
    }

    return result;
}

pub fn leaderIndex(slot: types.Slot, node_count: usize) ?usize {
    if (node_count == 0) return null;

    var seed: [16]u8 = undefined;
    std.mem.writeInt(u64, seed[0..8], slot, .little);
    std.mem.writeInt(u64, seed[8..16], 0, .little);

    var sha = Sha256.init(.{});
    sha.update(&seed);

    var digest: [32]u8 = undefined;
    sha.final(&digest);

    const value = std.mem.readInt(u64, digest[0..8], .little);
    return @intCast(value % @as(u64, node_count));
}

pub fn computeLeaderSchedule(
    epoch: types.Epoch,
    validators: []const types.Pubkey,
    stakes: []const u64,
    allocator: std.mem.Allocator,
) ![]usize {
    var snapshot = try captureLeaderScheduleSnapshot(epoch, validators, stakes, allocator);
    defer freeLeaderScheduleSnapshot(&snapshot, allocator);
    return try computeLeaderScheduleFromSnapshot(&snapshot, allocator);
}

fn leaderForSlotFromSnapshot(snapshot: *const LeaderScheduleSnapshot, slot: types.Slot) ?usize {
    if (snapshot.validators.len == 0) return null;
    if (snapshot.total_stake == 0) return leaderIndex(slot, snapshot.validators.len);

    var seed: [16]u8 = undefined;
    std.mem.writeInt(u64, seed[0..8], snapshot.epoch, .little);
    std.mem.writeInt(u64, seed[8..16], slot, .little);

    var sha = Sha256.init(.{});
    sha.update(&seed);

    var digest: [32]u8 = undefined;
    sha.final(&digest);

    const roll = std.mem.readInt(u64, digest[0..8], .little);
    const marker = roll % snapshot.total_stake;
    return firstIndexAtOrAbove(snapshot.cumulative_stakes, marker);
}

fn firstIndexAtOrAbove(prefix: []const u64, target: u64) usize {
    for (prefix, 0..) |v, i| {
        if (target < v) return i;
    }
    return if (prefix.len == 0) 0 else prefix.len - 1;
}

test "leader snapshots freeze inputs for weighted scheduling" {
    const validators = [_]types.Pubkey{
        .{ .bytes = [_]u8{1} ** 32 },
        .{ .bytes = [_]u8{2} ** 32 },
        .{ .bytes = [_]u8{3} ** 32 },
    };
    var stakes = [_]types.Lamports{ 10, 30, 5 };

    var snapshot = try captureLeaderScheduleSnapshot(0, &validators, &stakes, std.testing.allocator);
    defer freeLeaderScheduleSnapshot(&snapshot, std.testing.allocator);

    stakes[1] = 1;
    const scheduled = try computeLeaderScheduleFromSnapshot(&snapshot, std.testing.allocator);
    defer std.testing.allocator.free(scheduled);
    try std.testing.expectEqual(@as(usize, 3), snapshot.validators.len);
    try std.testing.expectEqual(@as(types.Lamports, 30), snapshot.stakes[1]);
    try std.testing.expect( std.mem.eql(u8, &snapshot.validators[2].bytes, &[_]u8{3} ** 32) );
}

test "computeLeaderSchedule is deterministic and bounded" {
    const validators = [_]types.Pubkey{
        .{ .bytes = [_]u8{1} ** 32 },
        .{ .bytes = [_]u8{2} ** 32 },
        .{ .bytes = [_]u8{3} ** 32 },
    };
    const stakes = [_]types.Lamports{ 10, 30, 5 };

    const first = try computeLeaderSchedule(0, &validators, &stakes, std.testing.allocator);
    defer std.testing.allocator.free(first);
    const second = try computeLeaderSchedule(0, &validators, &stakes, std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqual(first.len, second.len);
    try std.testing.expectEqualSlices(usize, first, second);

    for (first) |validator_index| {
        try std.testing.expect(validator_index < validators.len);
    }

    const es = sysvar.EpochSchedule.DEFAULT;
    try std.testing.expectEqual(first.len, @as(usize, @intCast(es.slotsInEpoch(0))));
}
