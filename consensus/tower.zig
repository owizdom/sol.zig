const std = @import("std");
const types = @import("types");
const vote_mod = @import("consensus/vote");

pub const Vote = struct {
    slot: types.Slot,
};

pub const Tower = struct {
    allocator: std.mem.Allocator,
    node_id: types.Pubkey,
    min_lockout_slots: usize,
    last_vote_slot: types.Slot,
    vote_state: vote_mod.VoteState,

    pub fn init(allocator: std.mem.Allocator, node_id: types.Pubkey, min_lockout_slots: usize) Tower {
        return .{
            .allocator = allocator,
            .node_id = node_id,
            .min_lockout_slots = min_lockout_slots,
            .last_vote_slot = 0,
            .vote_state = vote_mod.VoteState.init(allocator),
        };
    }

    pub fn deinit(self: *Tower) void {
        self.vote_state.deinit();
    }

    /// Apply a new vote and return the slot that became rooted, if any.
    pub fn recordVote(self: *Tower, slot: types.Slot) !?types.Slot {
        const root = try self.vote_state.processVote(slot);
        self.last_vote_slot = slot;
        return root;
    }

    pub fn shouldVote(self: *const Tower, slot: types.Slot, slot_stake: u64, total_stake: u64) bool {
        if (slot <= self.last_vote_slot) return false;
        if (!self.vote_state.canVote(slot)) return false;

        const threshold_depth = self.min_lockout_slots;
        if (threshold_depth > 0 and self.vote_state.votes.items.len >= threshold_depth) {
            if (total_stake == 0) return false;

            const threshold_vote = self.vote_state.votes.items[self.vote_state.votes.items.len - threshold_depth];
            if (threshold_vote.confirmation_count < threshold_depth) return false;
            if (slot_stake * 100 / total_stake < 67) return false;
        }

        return true;
    }

    pub fn canSwitch(_: *const Tower, old_fork_stake: u64, total_stake: u64) bool {
        if (total_stake == 0) return false;
        return old_fork_stake * 100 / total_stake <= 38;
    }
};

test "tower canVote blocks locked slots" {
    var tower = Tower.init(std.testing.allocator, .{ .bytes = [_]u8{1} ** 32 }, 2);
    defer tower.deinit();

    _ = try tower.recordVote(1);
    _ = try tower.recordVote(2);

    try std.testing.expect(!tower.shouldVote(3, 100, 200));
}

test "tower recordVote roots stale votes" {
    var tower = Tower.init(std.testing.allocator, .{ .bytes = [_]u8{2} ** 32 }, 3);
    defer tower.deinit();

    var i: usize = 1;
    var root: ?types.Slot = null;
    while (i <= vote_mod.MAX_LOCKOUT_HISTORY + 1) : (i += 1) {
        root = try tower.recordVote(i);
    }

    try std.testing.expect(root != null);
    try std.testing.expectEqual(@as(types.Slot, 1), root.?);
}

test "tower recordVote rejects duplicate slot" {
    var tower = Tower.init(std.testing.allocator, .{ .bytes = [_]u8{7} ** 32 }, 2);
    defer tower.deinit();

    _ = try tower.recordVote(10);
    try std.testing.expectError(error.DuplicateVote, tower.recordVote(10));
}

test "tower canSwitch threshold check" {
    var tower = Tower.init(std.testing.allocator, .{ .bytes = [_]u8{3} ** 32 }, 2);
    defer tower.deinit();

    try std.testing.expect(tower.canSwitch(20, 50));
    try std.testing.expect(!tower.canSwitch(39, 100));
}
