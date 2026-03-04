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
const snapshot_bootstrap = @import("snapshot/bootstrap");
const turbine_mod = @import("net/turbine");
const shred_mod   = @import("net/shred");

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
    turbine_receiver: ?turbine_mod.TurbineReceiver,
    turbine_thread:   ?std.Thread,
    tvu_running:      std.atomic.Value(bool),
    shreds_received:  std.atomic.Value(u64),
    tvu_port:         u16,

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
            .turbine_receiver = null,
            .turbine_thread   = null,
            .tvu_running      = std.atomic.Value(bool).init(false),
            .shreds_received  = std.atomic.Value(u64).init(0),
            .tvu_port         = 0,
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

    pub fn saveSnapshot(self: *Validator) void {
        const dir = self.snapshot_dir orelse return;
        snapshot_mod.writeSnapshot(&self.db, self.bank.slot, dir, self.allocator) catch |err| {
            std.debug.print("[warn] snapshot save slot {d}: {s}\n", .{ self.bank.slot, @errorName(err) });
            return;
        };
        std.debug.print("snapshot saved: slot {d} → {s}/\n", .{ self.bank.slot, dir });
    }

    pub fn deinit(self: *Validator) void {
        self.saveSnapshot();
        self.stopServices();

        self.replay.deinit();
        self.tower.deinit();
        self.graph.deinit();
        self.blockstore.deinit();
        self.bank.deinit();
        if (self.leader_snapshot) |*snapshot| schedule.freeLeaderScheduleSnapshot(snapshot, self.allocator);
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

    pub fn bootstrapFromDevnet(self: *Validator) void {
        const genesis = snapshot_bootstrap.fetchGenesisHash(self.allocator) catch |err| {
            std.debug.print("devnet bootstrap skipped (genesis): {}\n", .{err});
            return;
        };
        defer self.allocator.free(genesis);

        std.debug.print("devnet genesis hash: {s}\n", .{genesis});

        _ = snapshot_bootstrap.fetchCurrentSlot(self.allocator) catch |err| {
            std.debug.print("devnet bootstrap slot fetch skipped: {}\n", .{err});
        };

        self.maybeLoadSnapshot();

        if (self.bank.slot == 0) {
            if (self.snapshot_dir) |dir| {
                snapshot_mod.writeSnapshot(&self.db, 0, dir, self.allocator) catch {};
                std.debug.print("genesis snapshot written\n", .{});
            }
        }
    }

    pub fn seedGossipFromDevnet(self: *Validator) void {
        // Discover public IP and advertise it so devnet validators can reach us back.
        if (self.gossip_node) |*node| {
            if (snapshot_bootstrap.fetchPublicIp(self.allocator)) |ip_str| {
                defer self.allocator.free(ip_str);
                const port = node.my_info.gossip.getPort();
                if (snapshot_bootstrap.parseIpv4(ip_str, port)) |addr| {
                    node.setAdvertisedAddr(addr);
                    const ip4: [4]u8 = @bitCast(addr.in.sa.addr);
                    std.debug.print("gossip advertising: {d}.{d}.{d}.{d}:{d}\n",
                        .{ ip4[0], ip4[1], ip4[2], ip4[3], addr.getPort() });
                    if (self.tvu_port != 0) {
                        if (snapshot_bootstrap.parseIpv4(ip_str, self.tvu_port)) |tvu_addr| {
                            node.my_info.tvu = tvu_addr;
                        }
                    }
                } else {
                    std.debug.print("could not parse public IP: {s}\n", .{ip_str});
                }
            } else |err| {
                std.debug.print("public IP fetch failed ({s}), advertising bind addr\n", .{@errorName(err)});
            }
        }

        const peers = snapshot_bootstrap.fetchGossipPeers(self.allocator, 64) catch |err| {
            std.debug.print("devnet gossip bootstrap failed: {}\n", .{err});
            return;
        };
        defer peers.deinit();

        if (self.gossip_node) |*node| {
            node.seedPeers(peers.items);
            for (peers.items) |peer| {
                node.sendPullRequest(peer) catch {};
            }
        }
    }

    fn refreshLeaderSchedule(self: *Validator, epoch: types.Epoch) !void {
        const validators = [_]types.Pubkey{self.identity.publicKey()};
        const stakes = [_]types.Lamports{1_000_000_000};

        if (self.leader_snapshot) |*snapshot| {
            if (snapshot.epoch == epoch) return;
            schedule.freeLeaderScheduleSnapshot(snapshot, self.allocator);
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
        return self.startServicesInternal(gossip_port, rpc_port, metrics_port, false);
    }

    /// Strict mode is intended for real network runs (devnet/mainnet style participation).
    /// It fails fast on bind failures instead of silently disabling services.
    pub fn startServicesStrict(self: *Validator, gossip_port: ?u16, rpc_port: ?u16, metrics_port: ?u16) !void {
        return self.startServicesInternal(gossip_port, rpc_port, metrics_port, true);
    }

    fn startServicesInternal(
        self: *Validator,
        gossip_port: ?u16,
        rpc_port: ?u16,
        metrics_port: ?u16,
        strict: bool,
    ) !void {
        self.maybeLoadSnapshot();

        if (gossip_port) |port| {
            const any = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
            const gossip_node = gossip.GossipNode.init(self.allocator, self.identity, any, 0) catch |err| blk: {
                if (err == error.AccessDenied) {
                    if (strict) return err;
                    std.debug.print("[warn] gossip bind denied ({s}), disabled for this run\n", .{@errorName(err)});
                    break :blk null;
                }
                return err;
            };
            if (gossip_node) |node| {
                self.gossip_node = node;
                self.gossip_thread = try self.gossip_node.?.start();
            }
        }

        if (gossip_port) |gport| {
            const tvu_port: u16 = gport + 1;
            self.tvu_port = tvu_port;
            const tvu_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, tvu_port);
            if (turbine_mod.TurbineReceiver.init(self.allocator, tvu_addr)) |recv| {
                self.turbine_receiver = recv;
                if (self.gossip_node) |*node| node.my_info.tvu = tvu_addr;
                self.tvu_running.store(true, .seq_cst);
                self.turbine_thread = std.Thread.spawn(.{}, turbineLoop, .{self}) catch |err| blk: {
                    std.debug.print("[warn] turbine thread: {s}\n", .{@errorName(err)});
                    break :blk null;
                };
                std.debug.print("turbine recv bound on :{d}\n", .{tvu_port});
            } else |err| {
                std.debug.print("[warn] turbine bind :{d}: {s}\n", .{ tvu_port, @errorName(err) });
            }
        }

        var rpc_started = false;
        if (rpc_port) |port| {
            const any = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
            const rpc_server = rpc.RpcServer.init(self.allocator, any, &self.bank, self.identity.publicKey()) catch |err| blk: {
                if (err == error.AccessDenied) {
                    if (strict) return err;
                    std.debug.print("[warn] rpc bind denied ({s}), disabled for this run\n", .{@errorName(err)});
                    break :blk null;
                }
                return err;
            };
            if (rpc_server) |server| {
                self.rpc_server = server;
                self.rpc_thread = try self.rpc_server.?.start();
                rpc_started = true;
            }
        }

        if (metrics_port) |port| {
            const any = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
            const metrics_server_instance = metrics_server.MetricsServer.init(any, &metrics.GLOBAL) catch |err| blk: {
                if (err == error.AccessDenied) {
                    if (strict) return err;
                    std.debug.print("[warn] metrics bind denied ({s}), disabled for this run\n", .{@errorName(err)});
                    break :blk null;
                }
                return err;
            };
            if (metrics_server_instance) |instance| {
                self.metrics_server = instance;
                self.metrics_thread = try self.metrics_server.?.start();
            }
        }

        if (rpc_port) |rpc_p| {
            if (rpc_p != std.math.maxInt(u16)) {
                const tpu_port: u16 = @intCast(rpc_p + 1);
                const any = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, tpu_port);
                if (!rpc_started and !strict) {
                    std.debug.print("[warn] rpc not running, TPU startup disabled for this run\n", .{});
                } else {
                    const cert = try tls_cert.generateSelfSigned(self.allocator, "/tmp/solana-in-zig-tpu");
                    const tpu_server = tpu_quic.TpuQuicServer.init(self.allocator, any, &self.bank, cert.cert_path, cert.key_path) catch |err| blk: {
                        self.allocator.free(cert.cert_path);
                        self.allocator.free(cert.key_path);
                        if (err == error.AccessDenied) {
                            if (strict) return err;
                            std.debug.print("[warn] tpu bind denied ({s}), disabled for this run\n", .{@errorName(err)});
                            break :blk null;
                        }
                        return err;
                    };
                    if (tpu_server) |server| {
                        self.tpu_cert_bundle = cert;
                        self.tpu_server = server;
                        _ = try self.tpu_server.?.start();
                    } else {
                        self.allocator.free(cert.cert_path);
                        self.allocator.free(cert.key_path);
                    }
                }
            }
        }
    }

    pub fn stopServices(self: *Validator) void {
        self.tvu_running.store(false, .seq_cst);
        if (self.turbine_thread) |t| { t.join(); self.turbine_thread = null; }
        if (self.turbine_receiver) |*recv| { recv.deinit(); self.turbine_receiver = null; }

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

fn turbineLoop(self: *Validator) void {
    const alloc = self.allocator;
    var fec_sets = std.AutoHashMap(u64, shred_mod.FecSet).init(alloc);
    defer {
        var it = fec_sets.valueIterator();
        while (it.next()) |fs| fs.deinit();
        fec_sets.deinit();
    }

    while (self.tvu_running.load(.seq_cst)) {
        const recv = if (self.turbine_receiver) |*r| r else break;
        const sh = recv.recvShred() orelse {
            std.Thread.sleep(1 * std.time.ns_per_ms);
            continue;
        };
        _ = self.shreds_received.fetchAdd(1, .monotonic);

        const slot    = sh.slot();
        const fec_idx = sh.fecSetIndex();
        const key     = (@as(u64, slot) << 16) | @as(u64, fec_idx);

        const gop = fec_sets.getOrPut(key) catch continue;
        if (!gop.found_existing)
            gop.value_ptr.* = shred_mod.FecSet.init(alloc, slot, fec_idx);
        gop.value_ptr.addShred(sh) catch continue;

        if (gop.value_ptr.isComplete(1)) {
            var out = std.array_list.Managed(u8).init(alloc);
            if (gop.value_ptr.reassemble(&out)) |_| {
                std.debug.print("[turbine] slot {d}: {d}B assembled ({d} shreds total)\n",
                    .{ slot, out.items.len, self.shreds_received.load(.monotonic) });
            } else |_| {}
            out.deinit();
            var fs = fec_sets.fetchRemove(key).?.value;
            fs.deinit();
        }

        if (fec_sets.count() > 2000) {
            var it2 = fec_sets.valueIterator();
            while (it2.next()) |fs| fs.deinit();
            fec_sets.clearAndFree();
        }
    }
}

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
