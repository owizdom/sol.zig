const std = @import("std");
const types = @import("types");
const accounts_db = @import("accounts_db");
const bank_mod = @import("bank");
const blockstore_mod = @import("blockstore");
const fork_choice = @import("consensus/fork_choice");
const tower = @import("consensus/tower");
const transaction = @import("transaction");
const metrics = @import("metrics");
const snapshot = @import("snapshot");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const ReplayResult = struct {
    slot: types.Slot,
    blockhash: types.Hash,
    transactions_ok: usize,
    transactions_failed: usize,
};

pub const ReplayStage = struct {
    allocator: std.mem.Allocator,
    bank: *bank_mod.Bank,
    blockstore: *blockstore_mod.BlockStore,
    graph: *fork_choice.ForkGraph,
    voting: ?*tower.Tower,
    last_blockhash: types.Hash,
    snapshot_dir: ?[]const u8,
    last_full_snapshot_slot: types.Slot,

    pub fn init(
        allocator: std.mem.Allocator,
        bank: *bank_mod.Bank,
        blockstore: *blockstore_mod.BlockStore,
        graph: *fork_choice.ForkGraph,
        voting: ?*tower.Tower,
        snapshot_dir: ?[]const u8,
    ) ReplayStage {
        return .{
            .allocator = allocator,
            .bank = bank,
            .blockstore = blockstore,
            .graph = graph,
            .voting = voting,
            .last_blockhash = bank.lastBlockhash(),
            .snapshot_dir = snapshot_dir,
            .last_full_snapshot_slot = 0,
        };
    }

    pub fn deinit(self: *ReplayStage) void {
        _ = self;
    }

    pub fn replaySlot(
        self: *ReplayStage,
        txs: []const transaction.Transaction,
    ) !ReplayResult {
        const start_ns = std.time.nanoTimestamp();
        const parent_slot = self.bank.slot;
        const parent_hash = self.bank.lastBlockhash();

        var txs_ok: usize = 0;
        var txs_fail: usize = 0;

        for (txs) |tx| {
            const res = self.bank.processTransaction(tx) catch |e| {
                _ = e;
                txs_fail += 1;
                _ = metrics.GLOBAL.transactions_processed.fetchAdd(1, .monotonic);
                _ = metrics.GLOBAL.transactions_failed.fetchAdd(1, .monotonic);
                continue;
            };
            _ = metrics.GLOBAL.transactions_processed.fetchAdd(1, .monotonic);
            if (res.status == .ok) {
                txs_ok += 1;
                _ = metrics.GLOBAL.transactions_ok.fetchAdd(1, .monotonic);
            } else {
                txs_fail += 1;
                _ = metrics.GLOBAL.transactions_failed.fetchAdd(1, .monotonic);
            }
        }

        // Derive a deterministic next blockhash from parent hash + slot.
        const next_slot = parent_slot + 1;
        const next_hash = deriveBlockhash(parent_hash, next_slot);
        try self.bank.advanceSlot(next_hash);

        // Small payload for observability.
        var payload_buf: [128]u8 = undefined;
        const payload = try std.fmt.bufPrint(
            &payload_buf,
            "slot={d} tx_ok={d} tx_fail={d}",
            .{ self.bank.slot, txs_ok, txs_fail },
        );

        try self.blockstore.put(self.bank.slot, parent_slot, next_hash, parent_hash, payload);
        try self.graph.addNode(self.bank.slot, parent_slot, next_hash);

        if (self.voting) |v| {
            _ = v.recordVote(self.bank.slot) catch {};
        }

        self.maybeWriteSnapshot();

        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        metrics.GLOBAL.current_slot.store(self.bank.slot, .release);
        _ = metrics.GLOBAL.slots_processed.fetchAdd(1, .monotonic);
        _ = metrics.GLOBAL.tx_process_time_ns_sum.fetchAdd(@as(u64, @intCast(elapsed_ns)), .monotonic);
        _ = metrics.GLOBAL.tx_process_time_ns_count.fetchAdd(1, .monotonic);

        self.last_blockhash = next_hash;
        return ReplayResult{
            .slot = self.bank.slot,
            .blockhash = next_hash,
            .transactions_ok = txs_ok,
            .transactions_failed = txs_fail,
        };
    }

    fn maybeWriteSnapshot(self: *ReplayStage) void {
        const dir = self.snapshot_dir orelse return;
        if (self.bank.slot == 0) return;

        if (self.bank.slot % 1000 == 0) {
            snapshot.writeFullSnapshot(self.bank.db, self.bank.slot, dir, self.allocator) catch return;
            self.last_full_snapshot_slot = self.bank.slot;
            return;
        }

        if (self.bank.slot % 100 == 0) {
            const base_slot: types.Slot = if (self.bank.slot < 100) 0 else self.bank.slot - 100;
            _ = self.last_full_snapshot_slot;
            snapshot.writeIncrementalSnapshot(self.bank.db, base_slot, self.bank.slot, dir, self.allocator) catch return;
        }
    }

    pub fn replaySlots(self: *ReplayStage, count: usize) !types.Hash {
        const empty = [_]transaction.Transaction{};

        var i: usize = 0;
        while (i < count) : (i += 1) {
            _ = try self.replaySlot(&empty);
        }

        return self.last_blockhash;
    }
};

fn deriveBlockhash(parent_hash: types.Hash, slot: types.Slot) types.Hash {
    var slot_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &slot_buf, slot, .little);

    var sha = Sha256.init(.{});
    sha.update(&parent_hash.bytes);
    sha.update(&slot_buf);

    var out: [32]u8 = undefined;
    sha.final(&out);
    return .{ .bytes = out };
}

test "replay slot advances bank" {
    var db = accounts_db.AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    var b = try bank_mod.Bank.init(std.testing.allocator, 0, &db, types.Hash.ZERO);
    defer b.deinit();

    var bs = blockstore_mod.BlockStore.init(std.testing.allocator);
    defer bs.deinit();

    var graph = fork_choice.ForkGraph.init(std.testing.allocator);
    defer graph.deinit();

    var rs = ReplayStage.init(std.testing.allocator, &b, &bs, &graph, null, null);

    const no_txs = [_]transaction.Transaction{};
    const result = try rs.replaySlot(&no_txs);
    try std.testing.expectEqual(@as(types.Slot, 1), result.slot);
}
