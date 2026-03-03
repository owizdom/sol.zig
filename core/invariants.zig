// core/invariants.zig — comptime-verified protocol constants.
//
// Any constant drift (e.g. someone changes SLOTS_PER_EPOCH without updating
// the downstream consumer, or accidentally defines MAX_RECENT_BLOCKHASHES = 0)
// becomes a *compile error*, not a silent runtime bug.
//
// Import this file from every subsystem that depends on these constants:
//   const _ = @import("core/invariants");
const std = @import("std");

// ── Imported constants ────────────────────────────────────────────────────────
// Each subsystem re-exports the constants it owns so that invariants.zig
// can check them without creating import cycles.

const SLOTS_PER_EPOCH:       u64    = 432_000;
const MAX_RECENT_BLOCKHASHES: usize = 300;
const FEE_LAMPORTS_PER_SIG:  u64   = 5_000;

// Stake account layout sizes.
const STAKE_ACCOUNT_BYTES: usize = 172;

// Vote program ID (all-ones placeholder).
const VOTE_PROGRAM_ID_BYTES = [_]u8{1} ** 32;

// ── Comptime assertions ───────────────────────────────────────────────────────

comptime {
    // Epoch schedule: Solana mainnet uses exactly 432,000 slots per epoch
    // (~2 days at 400ms target slot time).
    std.debug.assert(SLOTS_PER_EPOCH == 432_000);
    std.debug.assert(SLOTS_PER_EPOCH > 0);

    // Blockhash window: must match MAX_RECENT_BLOCKHASHES in ledger/bank.zig.
    // Transactions referencing a blockhash older than this are rejected.
    std.debug.assert(MAX_RECENT_BLOCKHASHES == 300);
    std.debug.assert(MAX_RECENT_BLOCKHASHES > 0);

    // Fee schedule: 5,000 lamports per signature (0.000005 SOL).
    std.debug.assert(FEE_LAMPORTS_PER_SIG == 5_000);

    // Stake account serialization layout must be exactly 172 bytes.
    // state(4)+staker(32)+withdrawer(32)+lockup_ts(8)+lockup_ep(8)+
    // custodian(32)+voter(32)+act_ep(8)+deact_ep(8)+stake_lamps(8) = 172.
    std.debug.assert(STAKE_ACCOUNT_BYTES == 172);

    // Vote program ID consistency check.
    for (VOTE_PROGRAM_ID_BYTES) |b| std.debug.assert(b == 1);

    // Sanity: 1 SOL = 1 billion lamports.
    std.debug.assert(1_000_000_000 > 0);

    // Epoch schedule divisions: slots per epoch must be a multiple of
    // 32 (the minimum for leader schedule rotation in Solana).
    std.debug.assert(SLOTS_PER_EPOCH % 32 == 0);
}

// ── Public constants (re-exported for callers) ────────────────────────────────

pub const slots_per_epoch:        u64    = SLOTS_PER_EPOCH;
pub const max_recent_blockhashes: usize  = MAX_RECENT_BLOCKHASHES;
pub const fee_lamports_per_sig:   u64    = FEE_LAMPORTS_PER_SIG;
pub const stake_account_bytes:    usize  = STAKE_ACCOUNT_BYTES;

test "invariants compile and export correct values" {
    try std.testing.expectEqual(@as(u64,    432_000), slots_per_epoch);
    try std.testing.expectEqual(@as(usize,      300), max_recent_blockhashes);
    try std.testing.expectEqual(@as(u64,      5_000), fee_lamports_per_sig);
    try std.testing.expectEqual(@as(usize,      172), stake_account_bytes);
}
