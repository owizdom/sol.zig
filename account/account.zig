const std = @import("std");
const types = @import("types");

/// On-chain account state (mirrors the Solana AccountInfo layout).
pub const Account = struct {
    /// Balance in lamports (1 SOL = 1_000_000_000 lamports).
    lamports: types.Lamports,
    /// Raw data stored in the account.
    data: []const u8,
    /// Program that owns this account (controls writes to `data`).
    owner: types.Pubkey,
    /// True if this account holds a BPF program.
    executable: bool,
    /// Epoch at which the account will next owe rent (deprecated, always 0 on new accounts).
    rent_epoch: types.Epoch,
};

test "account default values" {
    const system_id = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    const acc = Account{
        .lamports = 1_000_000_000,
        .data = &[_]u8{},
        .owner = system_id,
        .executable = false,
        .rent_epoch = 0,
    };
    try std.testing.expectEqual(@as(u64, 1_000_000_000), acc.lamports);
    try std.testing.expectEqual(@as(usize, 0), acc.data.len);
    try std.testing.expect(!acc.executable);
    try std.testing.expect(acc.owner.eql(system_id));
}
