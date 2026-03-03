const std = @import("std");
const types = @import("types");

pub const MAX_LOCKOUT_HISTORY: usize = 31;

pub const Error = error{
    DuplicateVote,
};

pub const Lockout = struct {
    slot: types.Slot,
    confirmation_count: u32,
};

pub const VoteState = struct {
    votes: std.array_list.Managed(Lockout),

    pub fn init(allocator: std.mem.Allocator) VoteState {
        return .{ .votes = std.array_list.Managed(Lockout).init(allocator) };
    }

    pub fn deinit(self: *VoteState) void {
        self.votes.deinit();
    }

    /// Apply a new vote and return the newly rooted slot, if any.
    pub fn processVote(self: *VoteState, slot: types.Slot) !?types.Slot {
        for (self.votes.items) |vote| {
            if (vote.slot == slot) return Error.DuplicateVote;
        }

        while (self.votes.items.len > 0) {
            const oldest = self.votes.items[0];
            const expiry = oldest.slot +% lockout_slots(oldest.confirmation_count);
            if (slot <= expiry) break;
            _ = self.votes.orderedRemove(0);
        }

        for (self.votes.items) |*vote| {
            vote.confirmation_count +|= 1;
        }

        try self.votes.append(.{
            .slot = slot,
            .confirmation_count = 1,
        });

        if (self.votes.items.len > MAX_LOCKOUT_HISTORY) {
            const root = self.votes.orderedRemove(0);
            return root.slot;
        }

        return null;
    }

    /// Return false if slot is still locked out by any active vote.
    pub fn canVote(self: *const VoteState, slot: types.Slot) bool {
        for (self.votes.items) |vote| {
            if (slot < vote.slot + lockout_slots(vote.confirmation_count)) {
                return false;
            }
        }
        return true;
    }
};

pub const SlotVote = struct { slot: types.Slot, stake: u64 };

pub fn lockout_slots(c: u32) u64 {
    return @as(u64, 1) << @min(c, 31);
}

test "vote state handles duplicate and lockout checks" {
    var state = VoteState.init(std.testing.allocator);
    defer state.deinit();

    try state.votes.append(.{ .slot = 1, .confirmation_count = 1 });
    try state.votes.append(.{ .slot = 5, .confirmation_count = 1 });
    try state.votes.append(.{ .slot = 8, .confirmation_count = 1 });

    try std.testing.expect(state.canVote(10));
    try std.testing.expect(!state.canVote(6));

    const duplicate = state.processVote(5);
    try std.testing.expectError(error.DuplicateVote, duplicate);
}

test "vote state rejects vote too soon by lockout window" {
    var state = VoteState.init(std.testing.allocator);
    defer state.deinit();

    _ = try state.processVote(10);
    _ = try state.processVote(12);

    _ = try state.processVote(14);
    const locked = state.canVote(15);
    try std.testing.expect(!locked);
}

test "vote state roots when history exceeds max" {
    var state = VoteState.init(std.testing.allocator);
    defer state.deinit();

    var root_slot: ?types.Slot = null;
    var i: usize = 0;
    i = 1;
    while (i <= MAX_LOCKOUT_HISTORY + 1) : (i += 1) {
        root_slot = try state.processVote(i);
    }

    try std.testing.expect(root_slot != null);
    try std.testing.expectEqual(@as(types.Slot, 1), root_slot.?);
}
