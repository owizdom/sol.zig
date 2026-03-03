const std = @import("std");

pub const Pubkey = struct {
    bytes: [32]u8,

    pub fn eql(self: Pubkey, other: Pubkey) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

pub const Hash = struct {
    bytes: [32]u8,

    pub const ZERO: Hash = .{ .bytes = [_]u8{0} ** 32 };

    pub fn eql(self: Hash, other: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

pub const Signature = struct {
    bytes: [64]u8,
};

pub const Slot = u64;
pub const Epoch = u64;
pub const Lamports = u64;

/// Mutable reference to an account's fields passed to native programs.
pub const AccountRef = struct {
    key: Pubkey,
    lamports: *u64,
    data: *[]u8,
    owner: *Pubkey,
    executable: bool,
    is_signer: bool,
    is_writable: bool,
};

test "pubkey equality" {
    const a = Pubkey{ .bytes = [_]u8{1} ** 32 };
    const b = Pubkey{ .bytes = [_]u8{1} ** 32 };
    const c = Pubkey{ .bytes = [_]u8{2} ** 32 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "hash zero constant" {
    for (Hash.ZERO.bytes) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
