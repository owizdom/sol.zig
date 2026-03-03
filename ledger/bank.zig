// Bank: the transaction-processing unit for a single slot.
// Wraps AccountsDB, applies fee schedule, runs the runtime, commits changes.
const std = @import("std");
const types       = @import("types");
const transaction = @import("transaction");
const accounts_db = @import("accounts_db");
const keypair     = @import("keypair");
const sysvar      = @import("sysvar");
const runtime     = @import("runtime");
const metrics     = @import("metrics");
const bpf_loader = @import("programs/bpf_loader");
const stake_prog  = @import("programs/stake/stake");

const VOTE_PROGRAM_ID: types.Pubkey = .{ .bytes = [_]u8{1} ** 32 };

pub const FEE_LAMPORTS_PER_SIG: u64 = 5_000;
pub const MAX_RECENT_BLOCKHASHES: usize = 300;

// ── Inflation schedule (Solana mainnet parameters) ───────────────────────────
// initial_rate = 8%, terminal_rate = 1.5%, taper = 15%/year
// rate(year) = max(terminal, initial * (1 - taper)^year)
// Epochs per year ≈ 182 (432_000 slots * ~400ms ≈ 2 days/epoch → ~182/year)
const INFLATION_INITIAL_RATE: f64  = 0.08;
const INFLATION_TERMINAL_RATE: f64 = 0.015;
const INFLATION_TAPER: f64         = 0.15;
const EPOCHS_PER_YEAR: f64         = 182.0;
// Default total supply ≈ 500 million SOL in lamports
const DEFAULT_TOTAL_SUPPLY: u64    = 500_000_000 * 1_000_000_000;

fn epochInflationRate(epoch: types.Epoch) f64 {
    const years = @as(f64, @floatFromInt(epoch)) / EPOCHS_PER_YEAR;
    const rate  = INFLATION_INITIAL_RATE * std.math.pow(f64, 1.0 - INFLATION_TAPER, years);
    return @max(rate, INFLATION_TERMINAL_RATE);
}

fn epochReward(epoch: types.Epoch, total_supply: u64) u64 {
    const rate   = epochInflationRate(epoch);
    const supply = @as(f64, @floatFromInt(total_supply));
    const annual = supply * rate;
    const per_epoch = annual / EPOCHS_PER_YEAR;
    return @as(u64, @intFromFloat(@max(per_epoch, 0.0)));
}

pub const TransactionStatus = enum { ok, err };

pub const TransactionResult = struct {
    status:        TransactionStatus,
    err:           ?anyerror,
    fee:           types.Lamports,
    compute_units: u64,
};

pub const Bank = struct {
    allocator:         std.mem.Allocator,
    slot:              types.Slot,
    epoch:             types.Epoch,
    db:                *accounts_db.AccountsDb,
    recent_blockhashes: std.array_list.Managed(types.Hash),
    epoch_schedule:    sysvar.EpochSchedule,
    rent:              sysvar.Rent,
    // Collected fees this slot (burned or distributed to validators).
    collected_fees:    types.Lamports,
    vote_credits:      std.AutoHashMap(types.Pubkey, u64),
    helper_features:   bpf_loader.HelperFeatures,
    // Total lamport supply — used for inflation schedule.
    total_supply:      u64,

    pub fn init(
        allocator:  std.mem.Allocator,
        slot:       types.Slot,
        db:         *accounts_db.AccountsDb,
        genesis_bh: types.Hash,
    ) !Bank {
        var b = Bank{
            .allocator          = allocator,
            .slot               = slot,
            .epoch              = 0,
            .db                 = db,
            .recent_blockhashes = std.array_list.Managed(types.Hash).init(allocator),
            .epoch_schedule     = sysvar.EpochSchedule.DEFAULT,
            .rent               = sysvar.Rent.DEFAULT,
            .collected_fees     = 0,
            .vote_credits       = std.AutoHashMap(types.Pubkey, u64).init(allocator),
            .helper_features    = bpf_loader.DefaultHelperFeatures,
            .total_supply       = DEFAULT_TOTAL_SUPPLY,
        };
        b.epoch = b.epoch_schedule.epochForSlot(slot);
        try b.recent_blockhashes.append(genesis_bh);
        return b;
    }

    pub fn deinit(self: *Bank) void {
        self.recent_blockhashes.deinit();
        self.vote_credits.deinit();
    }

    pub fn setHelperFeatures(self: *Bank, features: bpf_loader.HelperFeatures) void {
        self.helper_features = features;
    }

    // ── Blockhash management ─────────────────────────────────────────────────

    pub fn lastBlockhash(self: *const Bank) types.Hash {
        const items = self.recent_blockhashes.items;
        return items[items.len - 1];
    }

    pub fn isValidBlockhash(self: *const Bank, bh: types.Hash) bool {
        for (self.recent_blockhashes.items) |h| {
            if (std.mem.eql(u8, &h.bytes, &bh.bytes)) return true;
        }
        return false;
    }

    pub fn advanceSlot(self: *Bank, new_blockhash: types.Hash) !void {
        const prev_epoch = self.epoch;
        self.slot  += 1;
        self.epoch  = self.epoch_schedule.epochForSlot(self.slot);
        try self.recent_blockhashes.append(new_blockhash);
        // Trim to the last MAX_RECENT_BLOCKHASHES entries (≈ 300 slots / ~2 min window).
        if (self.recent_blockhashes.items.len > MAX_RECENT_BLOCKHASHES) {
            _ = self.recent_blockhashes.orderedRemove(0);
        }
        // Update Clock sysvar in AccountsDB.
        try self.updateClockSysvar();
        if (self.epoch != prev_epoch) {
            try self.advanceStakeEpochs();
            try self.settleEpochRewards();
        }
        try self.collectRent();
    }

    fn advanceStakeEpochs(self: *Bank) !void {
        const snapshot = try self.db.listAccounts(self.allocator);
        defer accounts_db.AccountsDb.freeListedAccounts(self.allocator, snapshot);

        for (snapshot) |*entry| {
            if (!std.mem.eql(u8, &entry.account.owner.bytes, &stake_prog.ID.bytes)) continue;
            if (entry.account.data.len < stake_prog.STAKE_ACCOUNT_BYTES) continue;

            const changed = stake_prog.applyEpochBoundaryTransitions(entry.account.data, self.epoch) catch |e| switch (e) {
                error.InvalidAccountData => false,
                else => return e,
            };
            if (!changed) continue;

            try self.db.store(
                entry.key,
                entry.account.lamports,
                entry.account.data,
                entry.account.owner,
                entry.account.executable,
                entry.account.rent_epoch,
                self.slot,
            );
        }
    }

    fn collectRent(self: *Bank) !void {
        const slots_per_epoch = self.epoch_schedule.slotsInEpoch(self.epoch);
        if (slots_per_epoch == 0) return;

        const snapshot = try self.db.listAccounts(self.allocator);
        defer accounts_db.AccountsDb.freeListedAccounts(self.allocator, snapshot);

        for (snapshot) |entry| {
            const rent_epoch = entry.account.rent_epoch;
            if (self.slot < rent_epoch) continue;

            const min_balance = self.rent.minimumBalance(entry.account.data.len);
            var next_lamports = entry.account.lamports;
            if (next_lamports < min_balance) {
                next_lamports = 0;
            }

            const account_data_bytes = entry.account.data.len;
            const rent_due_float = @as(f64, @floatFromInt(self.rent.lamports_per_byte_year))
                * @as(f64, @floatFromInt(account_data_bytes))
                / @as(f64, @floatFromInt(slots_per_epoch));
            const rent_due: u64 = if (rent_due_float < 1.0) 1 else @intFromFloat(rent_due_float);

            if (next_lamports > rent_due) next_lamports -= rent_due else next_lamports = 0;

            if (next_lamports == entry.account.lamports) continue;
            if (next_lamports == 0 and entry.account.data.len == 0) {
                try self.db.delete(entry.key, self.slot);
            } else {
                try self.db.store(
                    entry.key,
                    next_lamports,
                    entry.account.data,
                    entry.account.owner,
                    entry.account.executable,
                    entry.account.rent_epoch,
                    self.slot,
                );
            }
        }
    }

    // ── Sysvar updates ───────────────────────────────────────────────────────

    fn updateClockSysvar(self: *Bank) !void {
        const clock = sysvar.Clock{
            .slot                  = self.slot,
            .epoch_start_timestamp = 0,
            .epoch                 = self.epoch,
            .leader_schedule_epoch = self.epoch + 1,
            .unix_timestamp        = @intCast(std.time.timestamp()),
        };
        var buf: [sysvar.Clock.SIZE]u8 = undefined;
        clock.serialize(&buf);
        try self.db.store(
            sysvar.CLOCK_ID, 0, &buf,
            .{ .bytes = [_]u8{0} ** 32 }, // owned by system program
            false, self.epoch, self.slot,
        );
    }

    // ── Fee calculation ──────────────────────────────────────────────────────

    pub fn calcFee(self: *const Bank, num_signatures: usize) types.Lamports {
        _ = self;
        return FEE_LAMPORTS_PER_SIG * @as(u64, @intCast(num_signatures));
    }

    // ── Transaction processing ───────────────────────────────────────────────

    pub fn processTransaction(self: *Bank, tx: transaction.Transaction) !TransactionResult {
        const start_ns = std.time.nanoTimestamp();
        defer {
            const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - start_ns);
            _ = metrics.GLOBAL.tx_process_time_ns_sum.fetchAdd(elapsed_ns, .monotonic);
            _ = metrics.GLOBAL.tx_process_time_ns_count.fetchAdd(1, .monotonic);
        }

        const fee = self.calcFee(tx.signatures.len);
        const required_signatures = @as(usize, tx.message.header.num_required_signatures);

        if (tx.signatures.len < required_signatures or tx.message.account_keys.len < required_signatures) {
            return .{ .status = .err, .err = error.InvalidSignature, .fee = 0, .compute_units = 0 };
        }

        // 1. Validate recent blockhash.
        if (!self.isValidBlockhash(tx.message.recent_blockhash)) {
            return .{ .status = .err, .err = error.BlockhashNotFound, .fee = 0, .compute_units = 0 };
        }

        // 1.5 Verify required signatures.
        var sig_buf: [8192]u8 = undefined;
        const msg_bytes = tx.messageBytes(&sig_buf) catch {
            return .{
                .status = .err,
                .err = error.InvalidSignature,
                .fee = 0,
                .compute_units = 0,
            };
        };

        for (tx.signatures[0..required_signatures], 0..) |sig, i| {
            const signer = tx.message.account_keys[i];
            if (!keypair.verifySignature(signer, msg_bytes, sig)) {
                return .{ .status = .err, .err = error.InvalidSignature, .fee = 0, .compute_units = 0 };
            }
        }

        // 2. Fee payer must exist and have enough lamports.
        if (tx.message.account_keys.len == 0) {
            return .{ .status = .err, .err = error.NoAccounts, .fee = 0, .compute_units = 0 };
        }
        const fee_payer = tx.message.account_keys[0];

        // Check fee payer balance (without holding DB lock the whole time).
        const payer_bal = self.db.getLamports(fee_payer);
        if (payer_bal < fee) {
            return .{ .status = .err, .err = error.InsufficientFunds, .fee = 0, .compute_units = 0 };
        }

        // 3. Deduct fee.
        self.db.debitLamports(fee_payer, fee, self.slot) catch |e| {
            return .{ .status = .err, .err = e, .fee = 0, .compute_units = 0 };
        };
        self.collected_fees += fee;

        // 4. Load accounts.
        var la = runtime.loadAccounts(self.db, &tx.message, self.allocator) catch |e| {
            return .{ .status = .err, .err = e, .fee = fee, .compute_units = 0 };
        };
        defer la.deinit();

        // 5. Execute.
        var ctx = runtime.InvokeContext.init(
            self.db,
            self.slot,
            self.epoch,
            tx.message.recent_blockhash,
            self.allocator,
            self.helper_features,
        );
        const cu = runtime.executeTransaction(&ctx, &tx.message, &la) catch |e| {
            // On runtime error, fee is still charged but changes are discarded.
            return .{ .status = .err, .err = e, .fee = fee, .compute_units = ctx.compute_used };
        };

        // 6. Commit.
        runtime.commitAccounts(self.db, &la, self.slot) catch |e| {
            return .{ .status = .err, .err = e, .fee = fee, .compute_units = cu };
        };

        self.recordVoteCredits(tx);
        return .{ .status = .ok, .err = null, .fee = fee, .compute_units = cu };
    }

    // Return true if any stake account in the DB is actively delegated to vote_account.
    fn hasActiveStakeForVoteAccount(self: *Bank, vote_account: types.Pubkey) bool {
        const snapshot = self.db.listAccounts(self.allocator) catch return true;
        defer accounts_db.AccountsDb.freeListedAccounts(self.allocator, snapshot);
        const STATE_ACTIVE_VAL: u32 = @intFromEnum(stake_prog.StakeLifecycleState.active);
        for (snapshot) |entry| {
            if (!std.mem.eql(u8, &entry.account.owner.bytes, &stake_prog.ID.bytes)) continue;
            if (entry.account.data.len < stake_prog.STAKE_ACCOUNT_BYTES) continue;
            const s = std.mem.readInt(u32, entry.account.data[0..4], .little);
            if (s != STATE_ACTIVE_VAL) continue;
            // voter_pubkey is at offset 116 in the 172-byte layout.
            if (std.mem.eql(u8, entry.account.data[116..148], &vote_account.bytes)) return true;
        }
        return false;
    }

    fn recordVoteCredits(self: *Bank, tx: transaction.Transaction) void {
        for (tx.message.instructions) |ix| {
            if (@as(usize, ix.program_id_index) >= tx.message.account_keys.len) continue;
            if (ix.data.len < 4) continue;

            const program_id = tx.message.account_keys[ix.program_id_index];
            if (!std.mem.eql(u8, &program_id.bytes, &VOTE_PROGRAM_ID.bytes)) continue;

            const tag = std.mem.readInt(u32, ix.data[0..4], .little);
            if (tag != 1) continue;
            if (ix.accounts.len == 0) continue;

            const vote_account_index = ix.accounts[0];
            if (@as(usize, vote_account_index) >= tx.message.account_keys.len) continue;

            const vote_account = tx.message.account_keys[@as(usize, vote_account_index)];

            // Only credit votes backed by active stake.
            if (!self.hasActiveStakeForVoteAccount(vote_account)) continue;

            const result = self.vote_credits.getOrPut(vote_account) catch return;
            if (result.found_existing) {
                result.value_ptr.* +%= 1;
            } else {
                result.value_ptr.* = 1;
            }
        }
    }

    fn settleEpochRewards(self: *Bank) !void {
        const total_credits = sumVoteCredits(self.vote_credits);
        if (total_credits == 0) {
            self.collected_fees = 0;
            self.vote_credits.clearRetainingCapacity();
            return;
        }

        // Inflation-based reward pool: decay-adjusted issuance + collected fees.
        const inflation_reward = epochReward(self.epoch, self.total_supply);
        const reward_pool = self.collected_fees + inflation_reward;
        self.collected_fees = 0;
        self.total_supply +|= inflation_reward;

        var total_weight: u128 = 0;
        var weight_iter = self.vote_credits.iterator();
        while (weight_iter.next()) |entry| {
            const stake = self.voteStakeLamports(entry.key_ptr.*);
            total_weight += (@as(u128, entry.value_ptr.*) * @as(u128, stake));
        }

        if (total_weight == 0) {
            self.vote_credits.clearRetainingCapacity();
            return;
        }

        var distributed: u64 = 0;
        const reward_pool_128: u128 = reward_pool;
        var it = self.vote_credits.iterator();
        while (it.next()) |entry| {
            const stake = self.voteStakeLamports(entry.key_ptr.*);
            const raw_weight = @as(u128, entry.value_ptr.*) * @as(u128, stake);
            const weight_128 = (reward_pool_128 * raw_weight) / total_weight;
            const weight = if (weight_128 > std.math.maxInt(u64))
                std.math.maxInt(u64)
            else
                @as(u64, @intCast(weight_128));
            if (weight == 0) continue;
            distributed = distributed +% weight;
            self.db.creditLamports(entry.key_ptr.*, weight, self.slot) catch {};
        }

        const remainder = reward_pool -% distributed;
        if (remainder > 0) {
            var any = self.vote_credits.iterator();
            if (any.next()) |entry| {
                self.db.creditLamports(entry.key_ptr.*, remainder, self.slot) catch {};
            }
        }

        self.vote_credits.clearRetainingCapacity();
    }

    fn voteStakeLamports(self: *Bank, vote_account: types.Pubkey) u64 {
        const acct = self.db.get(vote_account) orelse return 1;
        return if (acct.lamports == 0) 1 else acct.lamports;
    }

    fn sumVoteCredits(map: std.AutoHashMap(types.Pubkey, u64)) u64 {
        var it = map.iterator();
        var total: u64 = 0;
        while (it.next()) |entry| {
            total +%= entry.value_ptr.*;
        }
        return total;
    }

    /// Build an epoch stake snapshot from active stake accounts in the DB.
    /// Returns validator pubkeys (voter_pubkeys) and their aggregated active stake.
    pub fn buildEpochStakeMap(self: *Bank, allocator: std.mem.Allocator) !struct {
        validators: []types.Pubkey,
        stakes: []u64,
    } {
        const snapshot = try self.db.listAccounts(allocator);
        defer accounts_db.AccountsDb.freeListedAccounts(allocator, snapshot);

        var validators = std.ArrayList(types.Pubkey).init(allocator);
        var stakes     = std.ArrayList(u64).init(allocator);
        errdefer {
            validators.deinit();
            stakes.deinit();
        }

        const STATE_ACTIVE_VAL: u32 = @intFromEnum(stake_prog.StakeLifecycleState.active);

        for (snapshot) |entry| {
            if (!std.mem.eql(u8, &entry.account.owner.bytes, &stake_prog.ID.bytes)) continue;
            if (entry.account.data.len < stake_prog.STAKE_ACCOUNT_BYTES) continue;
            const s = std.mem.readInt(u32, entry.account.data[0..4], .little);
            if (s != STATE_ACTIVE_VAL) continue;
            // voter_pubkey at offset 116 in the 172-byte layout.
            var voter: types.Pubkey = .{ .bytes = [_]u8{0} ** 32 };
            std.mem.copyForwards(u8, &voter.bytes, entry.account.data[116..148]);
            // Aggregate stake per voter.
            var found = false;
            for (validators.items, 0..) |v, i| {
                if (v.eql(voter)) {
                    stakes.items[i] +|= entry.account.lamports;
                    found = true;
                    break;
                }
            }
            if (!found) {
                try validators.append(voter);
                try stakes.append(entry.account.lamports);
            }
        }

        return .{
            .validators = try validators.toOwnedSlice(),
            .stakes     = try stakes.toOwnedSlice(),
        };
    }

    /// Process a batch of transactions, returning results for each.
    pub fn processTransactions(
        self:    *Bank,
        txns:    []const transaction.Transaction,
        results: []TransactionResult,
    ) !void {
        std.debug.assert(txns.len == results.len);
        for (txns, 0..) |tx, i| {
            results[i] = try self.processTransaction(tx);
        }
    }

    // ── Queries ──────────────────────────────────────────────────────────────

    pub fn getBalance(self: *Bank, pubkey: types.Pubkey) types.Lamports {
        return self.db.getLamports(pubkey);
    }
};

test "bank advance slot updates slot" {
    var db = accounts_db.AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    var b = try Bank.init(std.testing.allocator, 0, &db, types.Hash.ZERO);
    defer b.deinit();

    const new_bh = types.Hash{ .bytes = [_]u8{0xAB} ** 32 };
    try b.advanceSlot(new_bh);
    try std.testing.expectEqual(@as(u64, 1), b.slot);
    try std.testing.expect(b.isValidBlockhash(new_bh));
    try std.testing.expect(b.isValidBlockhash(types.Hash.ZERO));
}

test "bank fee deduction" {
    var db = accounts_db.AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    const sender_kp = try keypair.KeyPair.fromSeed([_]u8{0x7} ** 32);
    const sender = sender_kp.publicKey();
    const receiver = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    const sys_id   = types.Pubkey{ .bytes = [_]u8{0} ** 32 };

    // Fund sender.
    try db.store(sender, 10_000_000, &.{}, sys_id, false, 0, 0);

    var b = try Bank.init(std.testing.allocator, 0, &db, types.Hash.ZERO);
    defer b.deinit();

    // Build a transfer tx.
    var ix_data: [12]u8 = undefined;
    std.mem.writeInt(u32, ix_data[0..4], 2, .little);           // transfer
    std.mem.writeInt(u64, ix_data[4..12], 1_000_000, .little);  // 1 SOL

    const ix = transaction.CompiledInstruction{
        .program_id_index = 2,
        .accounts         = @constCast(&[_]u8{ 0, 1 }),
        .data             = &ix_data,
    };

    var msg_tx = transaction.Transaction{
        .signatures = &[_]types.Signature{},
        .message = .{
            .header           = .{ .num_required_signatures = 1, .num_readonly_signed_accounts = 0, .num_readonly_unsigned_accounts = 1 },
            .account_keys     = @constCast(&[_]types.Pubkey{ sender, receiver, sys_id }),
            .recent_blockhash = types.Hash.ZERO,
            .instructions     = @constCast(&[_]transaction.CompiledInstruction{ix}),
        },
    };
    var msg_buf: [8192]u8 = undefined;
    const msg_bytes = try msg_tx.messageBytes(&msg_buf);
    const sig = try sender_kp.sign(msg_bytes);

    const tx = transaction.Transaction{
        .signatures = &[_]types.Signature{sig},
        .message = msg_tx.message,
    };

    const res = try b.processTransaction(tx);
    try std.testing.expectEqual(TransactionStatus.ok, res.status);
    try std.testing.expectEqual(@as(u64, FEE_LAMPORTS_PER_SIG), res.fee);
}

test "collect rent deletes underfunded accounts and debits funded ones" {
    var db = accounts_db.AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    const owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    const funded = types.Pubkey{ .bytes = [_]u8{3} ** 32 };
    const dust = types.Pubkey{ .bytes = [_]u8{4} ** 32 };

    try db.store(funded, 1_500_000, &[_]u8{}, owner, false, 0, 0);
    try db.store(dust, 10, &[_]u8{}, owner, false, 0, 0);

    var b = try Bank.init(std.testing.allocator, 0, &db, types.Hash.ZERO);
    defer b.deinit();

    try b.advanceSlot(types.Hash{ .bytes = [_]u8{1} ** 32 });

    const funded_after = b.getBalance(funded);
    const dust_after = b.getBalance(dust);

    try std.testing.expect(funded_after < 1_500_000);
    try std.testing.expectEqual(@as(u64, 0), dust_after);
}

test "epochInflationRate decays from initial to terminal" {
    const rate0 = epochInflationRate(0);
    const rate_mid = epochInflationRate(500);
    const rate_far = epochInflationRate(10_000);
    try std.testing.expect(rate0 > rate_mid);
    try std.testing.expect(rate_mid > INFLATION_TERMINAL_RATE - 0.001);
    try std.testing.expect(rate_far >= INFLATION_TERMINAL_RATE - 0.0001);
    try std.testing.expect(rate0 <= INFLATION_INITIAL_RATE + 0.001);
}
