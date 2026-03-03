const std = @import("std");
const types = @import("types");
const keypair = @import("keypair");
const accounts_db = @import("accounts_db");
const bank_mod = @import("bank");
const blockstore_mod = @import("blockstore");
const fork_choice = @import("consensus/fork_choice");
const schedule = @import("consensus/schedule");
const tower = @import("consensus/tower");
const gossip = @import("net/gossip");
const replay = @import("replay");
const rpc = @import("rpc");
const transaction = @import("transaction");
const metrics_server = @import("metrics_server");
const metrics = @import("metrics");
const tpu_quic = @import("net/tpu_quic");
const tls_cert = @import("net/tls_cert");
const snapshot_mod = @import("snapshot");

pub const Validator = struct {
    allocator: std.mem.Allocator,
    identity: keypair.KeyPair,

    db: accounts_db.AccountsDb,
    bank: bank_mod.Bank,
    blockstore: blockstore_mod.BlockStore,
    schedule: schedule.Schedule,
    graph: fork_choice.ForkGraph,
    tower: tower.Tower,
    leader_snapshot: ?schedule.LeaderScheduleSnapshot,
    leader_schedule: ?[]usize,

    replay: replay.ReplayStage,

    gossip_node: ?gossip.GossipNode,
    rpc_server: ?rpc.RpcServer,
    rpc_thread: ?std.Thread,
    gossip_thread: ?std.Thread,
    metrics_server: ?metrics_server.MetricsServer,
    metrics_thread: ?std.Thread,
    tpu_server: ?tpu_quic.TpuQuicServer,
    tpu_cert_bundle: ?tls_cert.CertBundle,
    snapshot_dir: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, identity: keypair.KeyPair) !*Validator {
        var self = try allocator.create(Validator);

        self.* = .{
            .allocator = allocator,
            .identity = identity,
            .db = accounts_db.AccountsDb.init(allocator),
            .bank = undefined,
            .blockstore = blockstore_mod.BlockStore.init(allocator),
            .schedule = schedule.Schedule.init(),
            .graph = fork_choice.ForkGraph.init(allocator),
            .tower = tower.Tower.init(allocator, identity.publicKey(), 5),
            .leader_snapshot = null,
            .leader_schedule = null,
            .replay = undefined,
            .gossip_node = null,
            .rpc_server = null,
            .rpc_thread = null,
            .gossip_thread = null,
            .metrics_server = null,
            .metrics_thread = null,
            .tpu_server = null,
            .tpu_cert_bundle = null,
            .snapshot_dir = null,
        };

        self.bank = try bank_mod.Bank.init(allocator, 0, &self.db, types.Hash.ZERO);
        self.replay = replay.ReplayStage.init(
            allocator,
            &self.bank,
            &self.blockstore,
            &self.graph,
            &self.tower,
            null,
        );

        try self.graph.addNode(0, null, types.Hash.ZERO);
        try self.refreshLeaderSchedule(0);
        try self.seedBank();

        return self;
    }

    fn seedBank(self: *Validator) !void {
        const system_id = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
        const vote_seed_data = try self.allocator.alloc(u8, 200);
        defer self.allocator.free(vote_seed_data);
        @memset(vote_seed_data, 0);

        try self.db.store(system_id, 1_000_000_000_000, &.{}, system_id, false, 0, 0);
        try self.db.store(self.identity.publicKey(), 1_000_000_000, vote_seed_data, system_id, false, 0, 0);
        // Pre-seed an extra funded vote account for identity-based vote tests.
    }

    pub fn deinit(self: *Validator) void {
        self.stopServices();

        self.replay.deinit();
        self.tower.deinit();
        self.graph.deinit();
        self.blockstore.deinit();
        self.bank.deinit();
        if (self.leader_snapshot) |snapshot| schedule.freeLeaderScheduleSnapshot(&snapshot, self.allocator);
        if (self.leader_schedule) |schedule_data| self.allocator.free(schedule_data);
        self.db.deinit();
        if (self.snapshot_dir) |snapshot_dir| self.allocator.free(snapshot_dir);
        self.allocator.destroy(self);
    }

    pub fn setSnapshotDir(self: *Validator, path: []const u8) !void {
        if (self.snapshot_dir) |snapshot_dir| self.allocator.free(snapshot_dir);
        self.snapshot_dir = try self.allocator.dupe(u8, path);
    }

    fn maybeLoadSnapshot(self: *Validator) void {
        const dir = self.snapshot_dir orelse return;
        const loaded_slot = snapshot_mod.loadSnapshot(&self.db, dir, self.allocator) catch |err| {
            if (err == snapshot_mod.SnapshotError.NotFound) return;
            return;
        };

        // Keep bank/bookkeeping aligned with replayed slot to avoid inconsistent slot assumptions.
        if (loaded_slot != self.bank.slot) {
            self.bank.slot = loaded_slot;
            self.bank.epoch = self.bank.epoch_schedule.epochForSlot(loaded_slot);
            if (self.bank.recent_blockhashes.items.len > 0) {
                self.bank.recent_blockhashes.deinit();
                self.bank.recent_blockhashes = std.array_list.Managed(types.Hash).init(self.allocator);
            }
            self.bank.recent_blockhashes.append(types.Hash.ZERO) catch {};
        }
        self.refreshLeaderSchedule(self.bank.epoch) catch {};
    }

    fn refreshLeaderSchedule(self: *Validator, epoch: types.Epoch) !void {
        const validators = [_]types.Pubkey{self.identity.publicKey()};
        const stakes = [_]types.Lamports{1_000_000_000};

        if (self.leader_snapshot) |snapshot| {
            if (snapshot.epoch == epoch) return;
            schedule.freeLeaderScheduleSnapshot(&snapshot, self.allocator);
            self.leader_snapshot = null;
        }

        if (self.leader_schedule) |existing| {
            self.allocator.free(existing);
            self.leader_schedule = null;
        }

        var new_snapshot = try schedule.captureLeaderScheduleSnapshot(epoch, &validators, &stakes, self.allocator);
        errdefer schedule.freeLeaderScheduleSnapshot(&new_snapshot, self.allocator);

        const new_schedule = try schedule.computeLeaderScheduleFromSnapshot(&new_snapshot, self.allocator);
        errdefer self.allocator.free(new_schedule);

        self.leader_snapshot = new_snapshot;
        self.leader_schedule = new_schedule;
    }

    pub fn startServices(self: *Validator, gossip_port: ?u16, rpc_port: ?u16, metrics_port: ?u16) !void {
        self.maybeLoadSnapshot();

        if (gossip_port) |port| {
            const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
            self.gossip_node = try gossip.GossipNode.init(self.allocator, self.identity, addr, 0);
            self.gossip_thread = try self.gossip_node.?.start();
        }

        if (rpc_port) |port| {
            const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
            self.rpc_server = try rpc.RpcServer.init(self.allocator, addr, &self.bank, self.identity.publicKey());
            self.rpc_thread = try self.rpc_server.?.start();
        }

        if (metrics_port) |port| {
            const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
            self.metrics_server = try metrics_server.MetricsServer.init(addr, &metrics.GLOBAL);
            self.metrics_thread = try self.metrics_server.?.start();
        }

        if (rpc_port) |rpc_p| {
            if (rpc_p != std.math.maxInt(u16)) {
                const tpu_port: u16 = @intCast(rpc_p + 1);
                const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, tpu_port);
        var cert = try tls_cert.generateSelfSigned(self.allocator, "/tmp/solana-in-zig-tpu");
        errdefer cert.deinit();
        self.tpu_cert_bundle = cert;
                self.tpu_server = try tpu_quic.TpuQuicServer.init(self.allocator, addr, &self.bank, cert.cert_path, cert.key_path);
                _ = try self.tpu_server.?.start();
            }
        }
    }

    pub fn stopServices(self: *Validator) void {
        if (self.rpc_server) |*server| {
            server.stop();
        }
        if (self.rpc_server) |*server| {
            for (&server.thread_pool) |*thread_slot| {
                if (thread_slot.*) |thread| {
                    thread.join();
                    thread_slot.* = null;
                }
            }
            self.rpc_thread = null;
        }

        if (self.rpc_server) |*server| {
            server.deinit();
            self.rpc_server = null;
        }

        if (self.gossip_node) |*node| {
            node.running.store(false, .release);
        }
        if (self.gossip_thread) |thread| {
            thread.join();
            self.gossip_thread = null;
        }

        if (self.gossip_node) |*node| {
            node.deinit();
            self.gossip_node = null;
        }

        if (self.metrics_server) |*server| {
            server.stop();
        }
        if (self.metrics_thread) |thread| {
            thread.join();
            self.metrics_thread = null;
        }
        if (self.metrics_server) |*server| {
            server.deinit();
            self.metrics_server = null;
        }

        if (self.tpu_server) |*server| {
            server.deinit();
            self.tpu_server = null;
        }
        if (self.tpu_cert_bundle) |*bundle| {
            bundle.deinit();
            self.tpu_cert_bundle = null;
        }
    }

    pub fn runSlots(self: *Validator, count: usize) !types.Hash {
        const before_epoch = self.bank.epoch;
        const result = try self.replay.replaySlots(count);
        if (self.bank.epoch != before_epoch) try self.refreshLeaderSchedule(self.bank.epoch);
        return result;
    }

    pub fn submit(self: *Validator, txs: []const transaction.Transaction) !replay.ReplayResult {
        const before_epoch = self.bank.epoch;
        const result = try self.replay.replaySlot(txs);
        if (self.bank.epoch != before_epoch) try self.refreshLeaderSchedule(self.bank.epoch);
        return result;
    }

    pub fn currentSlot(self: *const Validator) types.Slot {
        return self.bank.slot;
    }

    pub fn latestBlockhash(self: *const Validator) types.Hash {
        return self.bank.lastBlockhash();
    }

    pub fn balance(self: *const Validator, pk: types.Pubkey) types.Lamports {
        return self.db.getLamports(pk);
    }
};

test "validator initializes with genesis values" {
    const identity = keypair.KeyPair.generate();
    var v = try Validator.init(std.testing.allocator, identity);
    defer v.deinit();

    const system_pk = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    try std.testing.expect(v.balance(system_pk) > 0);
    const start_slot = v.currentSlot();
    _ = try v.runSlots(2);
    try std.testing.expect(v.currentSlot() > start_slot);
}

fn makeTransferTx(
    signer: keypair.KeyPair,
    from: types.Pubkey,
    to: types.Pubkey,
    recent_bh: types.Hash,
    amount: u64,
) !transaction.Transaction {
    var ix_data: [12]u8 = undefined;
    std.mem.writeInt(u32, ix_data[0..4], 2, .little);
    std.mem.writeInt(u64, ix_data[4..12], amount, .little);

    const system_program = types.Pubkey{ .bytes = [_]u8{0} ** 32 };

    const ix = transaction.CompiledInstruction{
        .program_id_index = 2,
        .accounts = &[_]u8{ 0, 1 },
        .data = &ix_data,
    };
    var unsigned_tx = transaction.Transaction{
        .signatures = &[_]types.Signature{.{ .bytes = [_]u8{0} ** 64 }},
        .message = .{
            .header = .{
                .num_required_signatures = 1,
                .num_readonly_signed_accounts = 0,
                .num_readonly_unsigned_accounts = 1,
            },
            .account_keys = &[_]types.Pubkey{ from, to, system_program },
            .recent_blockhash = recent_bh,
            .instructions = &[_]transaction.CompiledInstruction{ix},
        },
    };
    var buf: [8192]u8 = undefined;
    const msg = try unsigned_tx.messageBytes(&buf);
    const sig = try signer.sign(msg);
    return .{
        .signatures = &[_]types.Signature{sig},
        .message = unsigned_tx.message,
    };
}

test "validator processes transfer through replay and stores block" {
    const identity = keypair.KeyPair.generate();
    var v = try Validator.init(std.testing.allocator, identity);
    defer v.deinit();

    const recipient = types.Pubkey{ .bytes = [_]u8{0xAA} ** 32 };
    const amount: u64 = 42_000;
    const sender = identity.publicKey();

    const before_sender = v.balance(sender);
    const before_recipient = v.balance(recipient);

    const tx = try makeTransferTx(v.identity, sender, recipient, v.latestBlockhash(), amount);
    const result = try v.submit(&[_]transaction.Transaction{tx});

    try std.testing.expectEqual(@as(usize, 1), result.transactions_ok);
    try std.testing.expectEqual(@as(types.Slot, 1), result.slot);
    try std.testing.expectEqual(@as(u64, bank_mod.FEE_LAMPORTS_PER_SIG), result.fee);
    try std.testing.expect(v.blockstore.has(1));
    try std.testing.expectEqual(@as(types.Slot, 1), v.graph.heaviestFork(0));

    try std.testing.expectEqual(before_sender - amount - bank_mod.FEE_LAMPORTS_PER_SIG, v.balance(sender));
    try std.testing.expectEqual(before_recipient + amount, v.balance(recipient));
}

test "validator replay populates tower and gatekeeps vote decisions" {
    const identity = keypair.KeyPair.generate();
    var v = try Validator.init(std.testing.allocator, identity);
    defer v.deinit();

    _ = try v.runSlots(8);
    try std.testing.expectEqual(@as(usize, 8), v.tower.vote_state.votes.items.len);
    try std.testing.expectEqual(@as(types.Slot, 8), v.tower.last_vote_slot);

    try std.testing.expect(!v.tower.shouldVote(8, 90, 100));
    try std.testing.expect(!v.tower.shouldVote(9, 10, 100));
    try std.testing.expect(v.tower.shouldVote(9, 100, 100));

    const before_slot = v.currentSlot();
    const replay_result = try v.submit(&[_]transaction.Transaction{});
    try std.testing.expectEqual(@as(types.Slot, before_slot + 1), replay_result.slot);
    try std.testing.expectEqual(@as(types.Slot, 9), v.tower.last_vote_slot);
    try std.testing.expectEqual(@as(usize, 9), v.tower.vote_state.votes.items.len);
}

test "validator fork-choice tracks vote weight under divergent forks" {
    const identity = keypair.KeyPair.generate();
    var v = try Validator.init(std.testing.allocator, identity);
    defer v.deinit();

    // Build diverging children from slot 0:
    // branch A: 0 -> 1 -> 2 -> 3
    // branch B: 0 -> 4 -> 5
    try v.graph.addNode(1, 0, types.Hash.ZERO);
    try v.graph.addNode(2, 1, types.Hash.ZERO);
    try v.graph.addNode(3, 2, types.Hash.ZERO);
    try v.graph.addNode(4, 0, types.Hash.ZERO);
    try v.graph.addNode(5, 4, types.Hash.ZERO);

    var aggregator = fork_choice.VoteAggregator.init(std.testing.allocator, &v.graph);
    defer aggregator.deinit();

    const voter_a = types.Pubkey{ .bytes = [_]u8{0xA1} ** 32 };
    const voter_b = types.Pubkey{ .bytes = [_]u8{0xB2} ** 32 };
    const voter_c = types.Pubkey{ .bytes = [_]u8{0xC3} ** 32 };

    try aggregator.addVote(voter_a, 3, 300);
    try aggregator.addVote(voter_b, 3, 100);
    try std.testing.expectEqual(@as(types.Slot, 3), v.graph.heaviestFork(0));

    try aggregator.addVote(voter_c, 5, 420);
    try std.testing.expectEqual(@as(types.Slot, 5), v.graph.heaviestFork(0));
    try std.testing.expectEqual(@as(u64, 400), aggregator.stakeFor(1));
    try std.testing.expectEqual(@as(u64, 420), aggregator.stakeFor(4));
}

fn sendRpcRequest(
    allocator: std.mem.Allocator,
    port: u16,
    body: []const u8,
    override_len: ?usize,
) ![]u8 {
    const content_length = override_len orelse body.len;
    const req = try std.fmt.allocPrint(
        allocator,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ port, content_length, body },
    );
    defer allocator.free(req);

    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const os_addr = addr.any;
    try std.posix.connect(sock, &os_addr, addr.getOsSockLen());
    _ = try std.posix.send(sock, req, 0);

    var resp = std.array_list.Managed(u8).init(allocator);
    defer resp.deinit();

    while (true) {
        var buf: [1024]u8 = undefined;
        const n = try std.posix.recv(sock, &buf, 0);
        if (n == 0) break;
        try resp.appendSlice(buf[0..n]);
    }
    return try resp.toOwnedSlice();
}

test "validator rpc endpoint handles real-style requests" {
    const identity = keypair.KeyPair.generate();
    var v = try Validator.init(std.testing.allocator, identity);
    defer v.deinit();

    const rpc_port: u16 = 18890;
    try v.startServices(null, rpc_port, null);
    defer v.stopServices();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    const request_fixtures = [_]struct { name: []const u8, body: []const u8, expect_contains: []const u8 }{
        .{ .name = "getHealth", .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getHealth\"}", .expect_contains = "\"result\":\"ok\"" },
        .{ .name = "getSlot", .body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"getSlot\"}", .expect_contains = "\"result\":" },
        .{ .name = "getLatestBlockhash", .body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"getLatestBlockhash\"}", .expect_contains = "\"result\":\"" },
        .{ .name = "getBalance object params", .body = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"getBalance\",\"params\":{\"pubkey\":\"11111111111111111111111111111111\"}}", .expect_contains = "\"result\":" },
        .{ .name = "method not found", .body = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"unknownMethod\"}", .expect_contains = "\"error\":" },
    };

    for (request_fixtures) |fixture| {
        const resp = try sendRpcRequest(
            std.testing.allocator,
            rpc_port,
            fixture.body,
            null,
        );
        defer std.testing.allocator.free(resp);
        std.debug.print("fixture={s}\n{s}\n", .{ fixture.name, resp });
        try std.testing.expect(std.mem.indexOf(u8, resp, fixture.expect_contains) != null);
    }

    const malformed = try sendRpcRequest(
        std.testing.allocator,
        rpc_port,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"getHealth\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"getHealth\"}".len + 8,
    );
    defer std.testing.allocator.free(malformed);
    try std.testing.expect(std.mem.indexOf(u8, malformed, "\"error\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, malformed, "\"code\":-32600") != null);

    const bad_rpc = try sendRpcRequest(
        std.testing.allocator,
        rpc_port,
        "{\"jsonrpc\":\"1.0\",\"id\":4,\"method\":\"getHealth\"}",
        null,
    );
    defer std.testing.allocator.free(bad_rpc);
    try std.testing.expect(std.mem.indexOf(u8, bad_rpc, "\"error\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_rpc, "\"code\":-32600") != null);

    const bad_balance = try sendRpcRequest(
        std.testing.allocator,
        rpc_port,
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"getBalance\"}",
        null,
    );
    defer std.testing.allocator.free(bad_balance);
    try std.testing.expect(std.mem.indexOf(u8, bad_balance, "\"error\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_balance, "\"code\":-32602") != null);
}
