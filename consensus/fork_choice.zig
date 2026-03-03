const std = @import("std");
const types = @import("types");

pub const ForkNode = struct {
    slot: types.Slot,
    parent: ?types.Slot,
    hash: types.Hash,
    children: std.array_list.Managed(types.Slot),

    pub fn init(allocator: std.mem.Allocator, slot: types.Slot, parent: ?types.Slot, hash: types.Hash) ForkNode {
        return .{
            .slot = slot,
            .parent = parent,
            .hash = hash,
            .children = std.array_list.Managed(types.Slot).init(allocator),
        };
    }

    pub fn deinit(self: *ForkNode) void {
        self.children.deinit();
    }
};

pub const ForkGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMap(types.Slot, ForkNode),
    vote_weight: std.AutoHashMap(types.Slot, u64),

    pub fn init(allocator: std.mem.Allocator) ForkGraph {
        var g = ForkGraph{
            .allocator = allocator,
            .nodes = std.AutoHashMap(types.Slot, ForkNode).init(allocator),
            .vote_weight = std.AutoHashMap(types.Slot, u64).init(allocator),
        };
        // Genesis root node.
        g.nodes.put(0, ForkNode.init(allocator, 0, null, types.Hash.ZERO)) catch {};
        return g;
    }

    pub fn deinit(self: *ForkGraph) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |n| {
            n.deinit();
        }
        self.nodes.deinit();
        self.vote_weight.deinit();
    }

    pub fn addNode(self: *ForkGraph, slot: types.Slot, parent_slot: ?types.Slot, hash: types.Hash) !void {
        const parent = parent_slot;
        if (!self.nodes.contains(slot)) {
            try self.nodes.put(slot, ForkNode.init(self.allocator, slot, parent, hash));
            if (parent) |p| {
                if (self.nodes.getPtr(p)) |parent_node| {
                    try parent_node.children.append(slot);
                }
            }
        }
    }

    pub fn heaviestFork(self: *const ForkGraph, root: types.Slot) types.Slot {
        if (!self.nodes.contains(root)) return 0;

        const root_node = self.nodes.get(root) orelse return root;
        var best_slot = root_node.slot;
        var best_weight = self.stakeFor(root_node.slot);

        var stack = std.array_list.Managed(types.Slot).init(self.allocator);
        defer stack.deinit();
        for (root_node.children.items) |child| stack.append(child) catch {};

        while (stack.items.len > 0) {
            const current = stack.pop();
            if (self.nodes.get(current)) |n| {
                const score = self.stakeFor(n.slot);
                if (score > best_weight or (score == best_weight and n.slot > best_slot)) {
                    best_weight = score;
                    best_slot = n.slot;
                }
                for (n.children.items) |child| stack.append(child) catch {};
            }
        }

        return best_slot;
    }

    pub fn recordVote(self: *ForkGraph, slot: types.Slot, stake: u64) !void {
        var current: ?types.Slot = slot;
        while (current) |s| {
            const g = try self.vote_weight.getOrPut(s);
            const next = if (g.found_existing) g.value_ptr.* +| stake else stake;
            g.value_ptr.* = next;

            const node = self.nodes.get(s) orelse break;
            current = node.parent;
        }
    }

    fn stakeFor(self: *const ForkGraph, slot: types.Slot) u64 {
        return self.vote_weight.get(slot) orelse 0;
    }
};

pub const VoteAggregator = struct {
    allocator: std.mem.Allocator,
    graph: *ForkGraph,
    voter_slot: std.AutoHashMap([32]u8, types.Slot),
    voter_stake: std.AutoHashMap([32]u8, u64),

    pub fn init(allocator: std.mem.Allocator, graph: *ForkGraph) VoteAggregator {
        return .{
            .allocator = allocator,
            .graph = graph,
            .voter_slot = std.AutoHashMap([32]u8, types.Slot).init(allocator),
            .voter_stake = std.AutoHashMap([32]u8, u64).init(allocator),
        };
    }

    pub fn deinit(self: *VoteAggregator) void {
        self.voter_slot.deinit();
        self.voter_stake.deinit();
    }

    pub fn addVote(self: *VoteAggregator, voter: types.Pubkey, slot: types.Slot, stake: u64) !void {
        if (self.voter_stake.get(voter.bytes)) |old_stake| {
            if (self.voter_slot.get(voter.bytes)) |old_slot| {
                const remove = old_stake;
                var current: ?types.Slot = old_slot;
                while (current) |s| {
                    const g = self.graph.vote_weight.getPtr(s) orelse break;
                    g.* = g.* -| remove;
                    const node = self.graph.nodes.get(s) orelse break;
                    current = node.parent;
                }
            }
        }

        _ = self.voter_slot.put(voter.bytes, slot) catch {};
        _ = self.voter_stake.put(voter.bytes, stake) catch {};
        try self.graph.recordVote(slot, stake);
    }

    pub fn stakeFor(self: *const VoteAggregator, slot: types.Slot) u64 {
        return self.graph.stakeFor(slot);
    }
};
