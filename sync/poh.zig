const std = @import("std");
const types = @import("types");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Proof of History state.
/// Maintains a running SHA-256 hash chain that proves time has passed.
pub const PoH = struct {
    hash: types.Hash,
    tick_count: u64,

    pub fn init(genesis_hash: types.Hash) PoH {
        return .{ .hash = genesis_hash, .tick_count = 0 };
    }

    /// Advance by one tick: hash = SHA256(hash)
    pub fn tick(self: *PoH) types.Hash {
        var h: [32]u8 = undefined;
        Sha256.hash(&self.hash.bytes, &h, .{});
        self.hash = .{ .bytes = h };
        self.tick_count += 1;
        return self.hash;
    }

    /// Record an event: hash = SHA256(hash ++ data)
    /// This "mixes in" external data at a precise point in the chain.
    pub fn record(self: *PoH, data: types.Hash) types.Hash {
        var sha = Sha256.init(.{});
        sha.update(&self.hash.bytes);
        sha.update(&data.bytes);
        var h: [32]u8 = undefined;
        sha.final(&h);
        self.hash = .{ .bytes = h };
        return self.hash;
    }
};

test "tick chain is deterministic" {
    var p1 = PoH.init(types.Hash.ZERO);
    var p2 = PoH.init(types.Hash.ZERO);
    const h1 = p1.tick();
    const h2 = p2.tick();
    try std.testing.expectEqualSlices(u8, &h1.bytes, &h2.bytes);
    try std.testing.expectEqual(@as(u64, 1), p1.tick_count);
}

test "consecutive ticks differ" {
    var p = PoH.init(types.Hash.ZERO);
    const h1 = p.tick();
    const h2 = p.tick();
    try std.testing.expect(!std.mem.eql(u8, &h1.bytes, &h2.bytes));
    try std.testing.expectEqual(@as(u64, 2), p.tick_count);
}

test "record differs from tick" {
    var p_tick = PoH.init(types.Hash.ZERO);
    var p_rec = PoH.init(types.Hash.ZERO);
    const event = types.Hash{ .bytes = [_]u8{0xAB} ** 32 };
    const tick_hash = p_tick.tick();
    const rec_hash = p_rec.record(event);
    try std.testing.expect(!std.mem.eql(u8, &tick_hash.bytes, &rec_hash.bytes));
}
