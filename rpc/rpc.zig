const std = @import("std");
const base58 = @import("base58");
const types = @import("types");
const bank_mod = @import("bank");
const accounts_db = @import("accounts_db");
const metrics = @import("metrics");
const queue_mod = @import("sync/queue");

const MAX_HEADER_BYTES = 16 * 1024;
const MAX_BODY_BYTES = 128 * 1024;
const HEADER_END = "\r\n\r\n";
const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const WEBSOCKET_POLL_INTERVAL_MS: i32 = 100;
const SPL_TOKEN_PROGRAM_ID = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const SPL_TOKEN_ACCOUNT_MINT_OFFSET: usize = 0;
const SPL_TOKEN_ACCOUNT_OWNER_OFFSET: usize = 32;
const SPL_TOKEN_ACCOUNT_AMOUNT_OFFSET: usize = 64;
const SPL_MINT_SUPPLY_OFFSET: usize = 36;
const SPL_MINT_DECIMALS_OFFSET: usize = 44;

const SPL_TOKEN_ACCOUNT_MIN_SIZE = 72;
const SPL_MINT_MIN_SIZE = 45;

const Error = error{
    InvalidRequest,
    InvalidJson,
    InvalidJsonRpc,
    InvalidMethod,
    InvalidParams,
};

pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    sock: std.posix.socket_t,
    bank: *bank_mod.Bank,
    identity: types.Pubkey,
    running: std.atomic.Value(bool),
    next_subscription_id: std.atomic.Value(u64),
    thread_pool: [8]?std.Thread,
    queue: queue_mod.AtomicQueue(std.posix.socket_t),

    pub fn init(
        allocator: std.mem.Allocator,
        bind_addr: std.net.Address,
        bank: *bank_mod.Bank,
        identity: types.Pubkey,
    ) !RpcServer {
        const sock = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK,
            0,
        );
        errdefer std.posix.close(sock);

        try std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );

        const os_addr = bind_addr.any;
        try std.posix.bind(sock, &os_addr, bind_addr.getOsSockLen());
        try std.posix.listen(sock, 64);

        return .{
            .allocator = allocator,
            .sock = sock,
            .bank = bank,
            .identity = identity,
            .running = std.atomic.Value(bool).init(false),
            .next_subscription_id = std.atomic.Value(u64).init(1),
            .thread_pool = .{ null, null, null, null, null, null, null, null },
            .queue = queue_mod.AtomicQueue(std.posix.socket_t).init(allocator),
        };
    }

    pub fn start(self: *RpcServer) !std.Thread {
        self.running.store(true, .release);

        var first: std.Thread = undefined;
        var first_set = false;
        for (&self.thread_pool) |*slot| {
            const t = try std.Thread.spawn(.{}, serve, .{self});
            slot.* = t;
            if (!first_set) {
                first = t;
                first_set = true;
            }
        }

        return first;
    }

    pub fn stop(self: *RpcServer) void {
        self.running.store(false, .release);
    }

    pub fn deinit(self: *RpcServer) void {
        self.stop();
        if (self.sock != -1) {
            const fd = self.sock;
            self.sock = -1;
            std.posix.close(fd);
        }
        self.queue.deinit();
    }

    fn serve(self: *RpcServer) !void {
        while (self.running.load(.acquire)) {
            var peer: std.posix.sockaddr = undefined;
            var peer_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            const conn = std.posix.accept(self.sock, &peer, &peer_len, 0) catch |err| {
                if (!self.running.load(.acquire)) return;
                if (err == error.ConnectionAborted) return;
                if (err == error.WouldBlock) {
                    std.Thread.sleep(std.time.ns_per_ms);
                    continue;
                }
                return;
            };
            defer std.posix.close(conn);
            self.handleConnection(conn) catch {};
        }
    }

    fn handleConnection(self: *RpcServer, conn: std.posix.socket_t) !void {
        const started_ns = std.time.nanoTimestamp();
        var request = std.array_list.Managed(u8).init(self.allocator);
        defer request.deinit();

        var scratch: [1024]u8 = undefined;
        var header_end: usize = 0;
        var have_header = false;
        while (!have_header) {
            const n = try std.posix.recv(conn, &scratch, 0);
            if (n == 0) return;
            try request.appendSlice(scratch[0..n]);

            if (std.mem.indexOf(u8, request.items, HEADER_END)) |idx| {
                have_header = true;
                header_end = idx + HEADER_END.len;
            } else if (request.items.len > MAX_HEADER_BYTES) {
                return error.InvalidRequest;
            }
        }

        if (isWebSocketUpgrade(request.items[0..header_end])) {
            try self.handleWebSocket(conn, request.items[0..header_end]);
            return;
        }

        const content_len = try parseContentLength(request.items[0..header_end]);
        if (content_len > MAX_BODY_BYTES) return error.InvalidRequest;

        if (request.items.len < header_end) return error.InvalidRequest;
        if (request.items.len - header_end < content_len) {
            const missing = header_end + content_len - request.items.len;
            var got: usize = 0;
            while (got < missing) {
                const n = try std.posix.recv(conn, &scratch, 0);
                if (n == 0) return error.InvalidRequest;
                try request.appendSlice(scratch[0..n]);
                got += n;
            }
        }

        const body = request.items[header_end .. header_end + content_len];
        _ = metrics.GLOBAL.rpc_requests.fetchAdd(1, .monotonic);

        var response = std.array_list.Managed(u8).init(self.allocator);
        defer response.deinit();

        const id = parseId(request.items) catch "null";
        self.dispatch(id, body, &response) catch |err| {
            switch (err) {
                Error.InvalidParams => try writeErrorResponse(&response, id, -32602, "Invalid params", "null"),
                Error.InvalidJsonRpc => try writeErrorResponse(&response, id, -32600, "Invalid request", "null"),
                Error.InvalidRequest => try writeErrorResponse(&response, id, -32600, "Invalid request", "null"),
                Error.InvalidMethod => try writeErrorResponse(&response, id, -32601, "Method not found", "null"),
                else => try writeErrorResponse(&response, id, -32603, "Internal error", "null"),
            }
            _ = metrics.GLOBAL.rpc_errors.fetchAdd(1, .monotonic);
        };

        const elapsed_ns = @as(u64, @intCast(std.time.nanoTimestamp() - started_ns));
        _ = metrics.GLOBAL.rpc_latency_ns_sum.fetchAdd(elapsed_ns, .monotonic);
        _ = metrics.GLOBAL.rpc_latency_ns_count.fetchAdd(1, .monotonic);

        var resp_header: [256]u8 = undefined;
        const header_len = try std.fmt.bufPrint(
            &resp_header,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{response.items.len},
        );
        _ = try std.posix.send(conn, header_len, 0);
        _ = try std.posix.send(conn, response.items, 0);
    }

    fn handleWebSocket(self: *RpcServer, conn: std.posix.socket_t, headers: []const u8) !void {
        const ws_key = parseHeaderValue(headers, "sec-websocket-key") orelse return Error.InvalidRequest;
        const accept = try websocketAcceptKey(self.allocator, ws_key);
        defer self.allocator.free(accept);

        var hand = std.array_list.Managed(u8).init(self.allocator);
        defer hand.deinit();

        try hand.writer().print(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept},
        );
        _ = try std.posix.send(conn, hand.items, 0);

        var ws_state = WebSocketState{
            .subscriptions = std.array_list.Managed(WebSocketSubscription).init(self.allocator),
            .last_slot = self.bank.slot,
        };
        defer ws_state.subscriptions.deinit();

        while (self.running.load(.acquire)) {
            var poll_fds = [_]std.posix.pollfd{
                .{
                    .fd = conn,
                    .events = std.posix.POLL.IN | std.posix.POLL.HUP,
                    .revents = 0,
                },
            };

            const ready = std.posix.poll(&poll_fds, WEBSOCKET_POLL_INTERVAL_MS) catch 0;
            if (ready > 0) {
                if ((poll_fds[0].revents & std.posix.POLL.HUP) != 0) return;
                const frame = readWebSocketFrame(self.allocator, conn) catch |err| {
                    switch (err) {
                        error.InvalidFrame, error.UnsupportedFrame => {
                            continue;
                        },
                        error.ConnectionClosed => return,
                        else => return err,
                    }
                };
                if (frame.opcode == 0x8) {
                    defer self.allocator.free(frame.payload);
                    try sendWebSocketClose(conn);
                    return;
                }
                if (frame.opcode == 0x9) {
                    defer self.allocator.free(frame.payload);
                    try sendWebSocketFrameWithOpcode(conn, 0xA, frame.payload);
                    continue;
                }
                if (frame.opcode != 0x1) {
                    self.allocator.free(frame.payload);
                    continue;
                }

                var response = std.array_list.Managed(u8).init(self.allocator);
                defer response.deinit();
                const id = parseId(frame.payload) catch "null";

                self.handleWebSocketRpc(id, frame.payload, &ws_state, &response) catch |err| {
                    switch (err) {
                        Error.InvalidParams => try writeErrorResponse(&response, id, -32602, "Invalid params", "null"),
                        Error.InvalidJsonRpc => try writeErrorResponse(&response, id, -32600, "Invalid request", "null"),
                        Error.InvalidRequest => try writeErrorResponse(&response, id, -32600, "Invalid request", "null"),
                        Error.InvalidMethod => try writeErrorResponse(&response, id, -32601, "Method not found", "null"),
                        else => try writeErrorResponse(&response, id, -32603, "Internal error", "null"),
                    }
            _ = metrics.GLOBAL.rpc_errors.fetchAdd(1, .monotonic);
                };

                if (response.items.len > 0) {
                    try sendWebSocketFrame(conn, response.items);
                }
                self.allocator.free(frame.payload);
            }

            try self.pushWebSocketNotifications(conn, &ws_state);
        }
    }

    fn handleWebSocketRpc(
        self: *RpcServer,
        id: []const u8,
        body: []const u8,
        ws_state: *WebSocketState,
        out: *std.array_list.Managed(u8),
    ) !void {
        const method = parseStringField(body, "method") orelse return Error.InvalidJson;
        const jsonrpc = parseStringField(body, "jsonrpc") orelse return Error.InvalidJson;
        if (!std.mem.eql(u8, jsonrpc, "2.0")) return Error.InvalidJsonRpc;

        if (std.mem.eql(u8, method, "accountSubscribe")) {
            const pk_text = parseNthStringParam(self.allocator, body, 0) orelse return Error.InvalidParams;
            const pubkey = decodePubkeyFromText(pk_text) orelse return Error.InvalidParams;
            const sub_id = self.next_subscription_id.fetchAdd(1, .monotonic);

            var sub = WebSocketSubscription{
                .id = sub_id,
                .kind = .account,
                .pubkey = pubkey,
                .has_account = false,
                .lamports = 0,
                .data_len = 0,
                .data_hash = 0,
            };
            initializeAccountSubscriptionState(self, &sub);
            try ws_state.subscriptions.append(sub);

            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{d},\"id\":{s}}}", .{ sub_id, id });
            return;
        }

        if (std.mem.eql(u8, method, "slotSubscribe")) {
            const sub_id = self.next_subscription_id.fetchAdd(1, .monotonic);
            try ws_state.subscriptions.append(.{ .id = sub_id, .kind = .slot });
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{d},\"id\":{s}}}", .{ sub_id, id });
            return;
        }

        if (std.mem.eql(u8, method, "logsSubscribe")) {
            const sub_id = self.next_subscription_id.fetchAdd(1, .monotonic);
            try ws_state.subscriptions.append(.{ .id = sub_id, .kind = .logs });
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{d},\"id\":{s}}}", .{ sub_id, id });
            return;
        }

        if (std.mem.eql(u8, method, "accountUnsubscribe")) {
            const target_id = parseSubscriptionIdParam(self.allocator, body) orelse return Error.InvalidParams;
            var removed = false;
            var idx: usize = 0;
            while (idx < ws_state.subscriptions.items.len) {
                if (ws_state.subscriptions.items[idx].kind == .account and ws_state.subscriptions.items[idx].id == target_id) {
                    _ = ws_state.subscriptions.swapRemove(idx);
                    removed = true;
                    break;
                }
                idx += 1;
            }
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{s},\"id\":{s}}}", .{ if (removed) "true" else "false", id });
            return;
        }

        if (std.mem.eql(u8, method, "slotUnsubscribe")) {
            const target_id = parseSubscriptionIdParam(self.allocator, body) orelse return Error.InvalidParams;
            var removed = false;
            var idx: usize = 0;
            while (idx < ws_state.subscriptions.items.len) {
                if (ws_state.subscriptions.items[idx].kind == .slot and ws_state.subscriptions.items[idx].id == target_id) {
                    _ = ws_state.subscriptions.swapRemove(idx);
                    removed = true;
                    break;
                }
                idx += 1;
            }
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{s},\"id\":{s}}}", .{ if (removed) "true" else "false", id });
            return;
        }

        if (std.mem.eql(u8, method, "logsUnsubscribe")) {
            const target_id = parseSubscriptionIdParam(self.allocator, body) orelse return Error.InvalidParams;
            var removed = false;
            var idx: usize = 0;
            while (idx < ws_state.subscriptions.items.len) {
                if (ws_state.subscriptions.items[idx].kind == .logs and ws_state.subscriptions.items[idx].id == target_id) {
                    _ = ws_state.subscriptions.swapRemove(idx);
                    removed = true;
                    break;
                }
                idx += 1;
            }
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{s},\"id\":{s}}}", .{ if (removed) "true" else "false", id });
            return;
        }

        return self.dispatch(id, body, out);
    }

    fn pushWebSocketNotifications(self: *RpcServer, conn: std.posix.socket_t, ws_state: *WebSocketState) !void {
        const current_slot = self.bank.slot;

        if (current_slot > ws_state.last_slot) {
            var slot_id = ws_state.last_slot + 1;
            while (slot_id <= current_slot) : (slot_id += 1) {
                for (ws_state.subscriptions.items) |*subscription| {
                    if (subscription.kind == .slot) {
                        var payload = std.array_list.Managed(u8).init(self.allocator);
                        defer payload.deinit();
                        try writeSlotNotification(&payload, slot_id, subscription.id);
                        try sendWebSocketFrame(conn, payload.items);
                    }
                    if (subscription.kind == .logs) {
                        var payload = std.array_list.Managed(u8).init(self.allocator);
                        defer payload.deinit();
                        try writeLogsNotification(&payload, slot_id, subscription.id);
                        try sendWebSocketFrame(conn, payload.items);
                    }
                }

                if (slot_id == std.math.maxInt(types.Slot)) break;
            }
            ws_state.last_slot = current_slot;
        }

        for (ws_state.subscriptions.items) |*subscription| {
            if (subscription.kind != .account) continue;
            var changed = false;
            if (self.bank.db.get(subscription.pubkey)) |acct| {
                defer self.allocator.free(acct.data);
                const data_hash = std.hash.Wyhash.hash(0, acct.data);
                if (!subscription.has_account) {
                    changed = true;
                } else if (subscription.lamports != acct.lamports or subscription.data_len != acct.data.len or subscription.data_hash != data_hash) {
                    changed = true;
                }

                if (changed) {
                    var notif = std.array_list.Managed(u8).init(self.allocator);
                    defer notif.deinit();
                    try writeAccountNotification(self.allocator, &notif, subscription.pubkey, &acct, self.bank.slot, subscription.id);
                    try sendWebSocketFrame(conn, notif.items);
                }

                subscription.has_account = true;
                subscription.lamports = acct.lamports;
                subscription.data_len = acct.data.len;
                subscription.data_hash = data_hash;
            } else if (subscription.has_account) {
                subscription.has_account = false;
                var notif = std.array_list.Managed(u8).init(self.allocator);
                defer notif.deinit();
                try writeMissingAccountNotification(&notif, subscription.id);
                try sendWebSocketFrame(conn, notif.items);
            }
        }
    }

    fn dispatch(self: *RpcServer, id: []const u8, body: []const u8, out: *std.array_list.Managed(u8)) !void {
        const method = parseStringField(body, "method") orelse return Error.InvalidJson;
        const jsonrpc = parseStringField(body, "jsonrpc") orelse return Error.InvalidJson;
        if (!std.mem.eql(u8, jsonrpc, "2.0")) return Error.InvalidJsonRpc;

        if (std.mem.eql(u8, method, "getHealth")) {
            return writeSuccessResult(out, id, "\"ok\"");
        }
        if (std.mem.eql(u8, method, "getSlot")) {
            return writeNumberResult(out, id, self.bank.slot);
        }
        if (std.mem.eql(u8, method, "getLatestBlockhash")) {
            var h: [64]u8 = undefined;
            const encoded = try base58.encode(&self.bank.lastBlockhash().bytes, &h);
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":\"{s}\",\"id\":{s}}}", .{ encoded, id });
            return;
        }

        if (std.mem.eql(u8, method, "getBalance")) {
            const pk = parsePubkeyField(body) orelse return Error.InvalidParams;
            const bal = self.bank.getBalance(pk);
            try out.writer().writeAll("{\"jsonrpc\":\"2.0\",\"result\":");
            try out.writer().print(
                "{{\"context\":{{\"slot\":{d},\"value\":{d}}}}}",
                .{ self.bank.slot, bal },
            );
            try out.writer().print(",\"id\":{s}}}", .{id});
            return;
        }

        if (std.mem.eql(u8, method, "getClusterNodes")) {
            var pk_buf: [64]u8 = undefined;
            const id_text = try base58.encode(&self.identity.bytes, &pk_buf);
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":[{{\"pubkey\":\"{s}\",\"gossip\":\"127.0.0.1:0\",\"tpu\":\"127.0.0.1:0\",\"version\":\"1.18.0-zig\"}}],\"id\":{s}}}",
                .{ id_text, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getEpochInfo")) {
            const slots_per_epoch = self.bank.epoch_schedule.slots_per_epoch;
            const slot_index = if (slots_per_epoch == 0) 0 else self.bank.slot % slots_per_epoch;
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"absoluteSlot\":{d},\"blockHeight\":{d},\"slotIndex\":{d},\"slotsInEpoch\":{d},\"epoch\":{d},\"transactionCount\":0}},\"id\":{s}}}",
                .{ self.bank.slot, self.bank.slot, slot_index, slots_per_epoch, self.bank.epoch, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getEpochSchedule")) {
            const es = self.bank.epoch_schedule;
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"slotsPerEpoch\":{d},\"leaderScheduleSlotOffset\":{d},\"warmup\":{},\"firstNormalEpoch\":{d},\"firstNormalSlot\":{d}}},\"id\":{s}}}",
                .{ es.slots_per_epoch, es.leader_schedule_slot_offset, @intFromBool(es.warmup), es.first_normal_epoch, es.first_normal_slot, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getGenesisHash")) {
            var h: [64]u8 = undefined;
            const encoded = try base58.encode(&types.Hash.ZERO.bytes, &h);
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":\"{s}\",\"id\":{s}}}", .{ encoded, id });
            return;
        }
        if (std.mem.eql(u8, method, "getIdentity")) {
            var id_buf: [64]u8 = undefined;
            const identity_text = try base58.encode(&self.identity.bytes, &id_buf);
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{{\"identity\":\"{s}\"}},\"id\":{s}}}", .{ identity_text, id });
            return;
        }
        if (std.mem.eql(u8, method, "getInflationGovernor")) {
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{{\"foundation\":0.0,\"foundationTerm\":0.0,\"total\":0.08,\"validator\":0.048}},\"id\":{s}}}", .{id});
            return;
        }
        if (std.mem.eql(u8, method, "getInflationRate")) {
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{{\"total\":0.08,\"validator\":0.048,\"foundation\":0.0,\"epoch\":0}},\"id\":{s}}}", .{id});
            return;
        }
        if (std.mem.eql(u8, method, "getInflationReward")) {
            try writeSuccessResult(out, id, "[null]");
            return;
        }
        if (std.mem.eql(u8, method, "getLeaderSchedule")) {
            var id_text: [64]u8 = undefined;
            const identity_text = try base58.encode(&self.identity.bytes, &id_text);
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{{\"{s}\":[0,1,2]}},\"id\":{s}}}", .{ identity_text, id });
            return;
        }
        if (std.mem.eql(u8, method, "getMinimumBalanceForRentExemption")) {
            const raw = parseNumericFromKey(body, "params") orelse return Error.InvalidParams;
            const size = std.fmt.parseInt(u64, raw, 10) catch return Error.InvalidParams;
            const minimum = self.bank.rent.minimumBalance(@as(usize, @intCast(size)));
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":{d}}},\"id\":{s}}}",
                .{ self.bank.slot, minimum, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getVersion")) {
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{{\"solana-core\":\"1.18.0-zig\",\"feature-set\":0}},\"id\":{s}}}", .{id});
            return;
        }

        if (std.mem.eql(u8, method, "getAccountInfo")) {
            if (parsePubkeyField(body)) |pk| {
                if (self.bank.db.get(pk)) |acct| {
                    defer self.allocator.free(acct.data);
                    try writeAccountResponse(out, self.allocator, id, pk, &acct, self.bank.slot);
                    return;
                }
            }
            try writeNullResult(out, id);
            return;
        }
        if (std.mem.eql(u8, method, "getMultipleAccounts")) {
            const pubkeys = parseTopLevelPubkeys(self.allocator, body) catch return Error.InvalidParams;
            defer self.allocator.free(pubkeys);

            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":[", .{ self.bank.slot });
            for (pubkeys, 0..) |pk, idx| {
                if (idx > 0) try out.writer().print(",", .{});
                if (self.bank.db.get(pk)) |acct| {
                    defer self.allocator.free(acct.data);
                    try writeAccountLite(out, self.allocator, pk, acct, true);
                } else {
                    try out.writer().print("null", .{});
                }
            }
            try out.writer().print("],\"id\":{s}}}", .{ id });
            return;
        }
        if (std.mem.eql(u8, method, "getProgramAccounts")) {
            const keys = parseTopLevelPubkeys(self.allocator, body) catch return Error.InvalidParams;
            if (keys.len == 0) {
                self.allocator.free(keys);
                try writeSuccessResult(out, id, "[]");
                return;
            }
            const program_id = keys[0];
            self.allocator.free(keys);

            const listed = try self.bank.db.listAccounts(self.allocator);
            defer accounts_db.AccountsDb.freeListedAccounts(self.allocator, listed);

            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":[", .{});
            var first = true;
            for (listed) |entry| {
                if (!std.mem.eql(u8, &entry.account.owner.bytes, &program_id.bytes)) continue;
                if (!first) try out.writer().print(",", .{});
                first = false;

                try writeProgramAccount(out, self.allocator, entry.key, entry.account);
            }
            try out.writer().print("],\"id\":{s}}}", .{ id });
            return;
        }
        if (std.mem.eql(u8, method, "getLargestAccounts")) {
            const listed = try self.bank.db.listAccounts(self.allocator);
            defer accounts_db.AccountsDb.freeListedAccounts(self.allocator, listed);

            const ListedAccount = std.meta.Child(@TypeOf(listed));
            std.mem.sort(ListedAccount, listed, {}, struct {
                fn lessThan(_: void, a: ListedAccount, b: ListedAccount) bool {
                    return a.account.lamports > b.account.lamports;
                }
            }.lessThan);

            const limit = if (listed.len < 20) listed.len else 20;
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":[", .{});
            for (listed[0..limit], 0..) |entry, i| {
                if (i > 0) try out.writer().print(",", .{});
                var pk_buf: [64]u8 = undefined;
                const pk_text = try base58.encode(&entry.key.bytes, &pk_buf);
                try out.writer().print("{{\"address\":\"{s}\",\"lamports\":{d}}}", .{ pk_text, entry.account.lamports });
            }
            try out.writer().print("],\"id\":{s}}}", .{ id });
            return;
        }
        if (std.mem.eql(u8, method, "getTokenAccountsByOwner")) {
            const strings = try parseTopLevelParamsStrings(self.allocator, body);
            defer self.allocator.free(strings);
            if (strings.len == 0) return Error.InvalidParams;

            const owner = decodePubkeyFromText(strings[0]) orelse return Error.InvalidParams;
            const token_program = if (strings.len > 1)
                (decodePubkeyFromText(strings[1]) orelse return Error.InvalidParams)
            else
                defaultTokenProgram() orelse return Error.InvalidParams;

            const listed = try self.bank.db.listAccounts(self.allocator);
            defer accounts_db.AccountsDb.freeListedAccounts(self.allocator, listed);

            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":[",
                .{ self.bank.slot },
            );
            var first = true;
            for (listed) |entry| {
                if (!entry.account.owner.eql(token_program)) continue;
                const info = parseTokenAccount(entry.account.data) orelse continue;
                if (!info.owner.eql(owner)) continue;

                if (!first) try out.writer().print(",", .{});
                first = false;
                try writeProgramAccount(out, self.allocator, entry.key, entry.account);
            }
            try out.writer().print("]}},\"id\":{s}}}", .{ id });
            return;
        }
        if (std.mem.eql(u8, method, "getTokenAccountBalance")) {
            const token_account_pk_text = parseNthStringParam(self.allocator, body, 0) orelse return Error.InvalidParams;
            const token_account_pk = decodePubkeyFromText(token_account_pk_text) orelse return Error.InvalidParams;
            const token_account = self.bank.db.get(token_account_pk) orelse {
                try writeNullResult(out, id);
                return;
            };
            defer self.allocator.free(token_account.data);

            const token_info = parseTokenAccount(token_account.data) orelse {
                try writeNullResult(out, id);
                return;
            };
            const mint_account = self.bank.db.get(token_info.mint) orelse {
                try writeNullResult(out, id);
                return;
            };
            defer self.allocator.free(mint_account.data);

            const mint_info = parseMint(mint_account.data) orelse {
                try writeNullResult(out, id);
                return;
            };

            const amount_text = try std.fmt.allocPrint(self.allocator, "{d}", .{token_info.amount});
            defer self.allocator.free(amount_text);

            const ui_amount_text = try formatUiAmount(self.allocator, token_info.amount, mint_info.decimals);
            defer self.allocator.free(ui_amount_text);

            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":{{\"amount\":\"{s}\",\"decimals\":{d},\"uiAmount\":null,\"uiAmountString\":\"{s}\"}}}},\"id\":{s}}}",
                .{ self.bank.slot, amount_text, mint_info.decimals, ui_amount_text, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getTokenSupply")) {
            const mint_pk_text = parseNthStringParam(self.allocator, body, 0) orelse return Error.InvalidParams;
            const mint_pk = decodePubkeyFromText(mint_pk_text) orelse return Error.InvalidParams;
            const mint_account = self.bank.db.get(mint_pk) orelse {
                try writeNullResult(out, id);
                return;
            };
            defer self.allocator.free(mint_account.data);

            const mint_info = parseMint(mint_account.data) orelse {
                try writeNullResult(out, id);
                return;
            };

            const supply_text = try std.fmt.allocPrint(self.allocator, "{d}", .{mint_info.supply});
            defer self.allocator.free(supply_text);

            const ui_amount_text = try formatUiAmount(self.allocator, mint_info.supply, mint_info.decimals);
            defer self.allocator.free(ui_amount_text);

            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":{{\"amount\":\"{s}\",\"decimals\":{d},\"uiAmount\":null,\"uiAmountString\":\"{s}\"}}}},\"id\":{s}}}",
                .{ self.bank.slot, supply_text, mint_info.decimals, ui_amount_text, id },
            );
            return;
        }

        if (std.mem.eql(u8, method, "getBlock")) {
            const slots = parseTopLevelUnsignedParams(self.allocator, body) catch return Error.InvalidParams;
            defer self.allocator.free(slots);
            const requested_slot = if (slots.len > 0) slots[0] else self.bank.slot;
            const parent_slot = if (requested_slot > 0) requested_slot - 1 else 0;
            const bh = self.bank.lastBlockhash();
            var bh_buf: [64]u8 = undefined;
            const bh_text = try base58.encode(&bh.bytes, &bh_buf);
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"slot\":{d},\"blockhash\":\"{s}\",\"previousBlockhash\":\"{s}\",\"parentSlot\":{d},\"transactions\":[],\"rewards\":[],\"blockTime\":{d}}},\"id\":{s}}}",
                .{
                    requested_slot,
                    bh_text,
                    bh_text,
                    parent_slot,
                    std.time.timestamp(),
                    id,
                },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getBlockHeight")) {
            try writeNumberResult(out, id, self.bank.slot);
            return;
        }
        if (std.mem.eql(u8, method, "getBlockProduction")) {
            var id_text: [64]u8 = undefined;
            const identity_text = try base58.encode(&self.identity.bytes, &id_text);
            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{{\"byIdentity\":{{\"{s}\":[{d},{d}]}}}},\"id\":{s}}}", .{ identity_text, 1, 1, id });
            return;
        }
        if (std.mem.eql(u8, method, "getBlockCommitment")) {
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":{{\"commitment\":null,\"totalStake\":1000000}}}},\"id\":{s}}}",
                .{ self.bank.slot, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getBlocks")) {
            const nums = parseTopLevelUnsignedParams(self.allocator, body) catch return Error.InvalidParams;
            defer self.allocator.free(nums);
            if (nums.len == 0) {
                try writeSuccessResult(out, id, "[]");
                return;
            }

            const start_slot = nums[0];
            const end_slot = if (nums.len > 1) nums[1] else self.bank.slot;
            if (start_slot > end_slot) {
                try writeSuccessResult(out, id, "[]");
                return;
            }

            const capped_start = if (start_slot > self.bank.slot) self.bank.slot + 1 else start_slot;
            const capped_end = if (end_slot > self.bank.slot) self.bank.slot else end_slot;
            if (capped_start > capped_end) {
                try writeSuccessResult(out, id, "[]");
                return;
            }

            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":[", .{});
            var slot = capped_start;
            var i: usize = 0;
            while (slot <= capped_end and i < 4096) : ({
                i += 1;
                if (slot == std.math.maxInt(types.Slot)) {
                    slot = std.math.maxInt(types.Slot);
                } else {
                    slot += 1;
                }
            }) {
                if (i > 0) try out.writer().print(",", .{});
                try out.writer().print("{d}", .{slot});
            }
            try out.writer().print("],\"id\":{s}}}", .{ id });
            return;
        }
        if (std.mem.eql(u8, method, "getBlocksWithLimit")) {
            const nums = parseTopLevelUnsignedParams(self.allocator, body) catch return Error.InvalidParams;
            defer self.allocator.free(nums);
            if (nums.len < 2) {
                try writeErrorResponse(out, id, -32602, "Invalid params", "null");
                return;
            }

            const start_slot = nums[0];
            const limit = nums[1];
            if (start_slot > self.bank.slot or limit == 0) {
                try writeSuccessResult(out, id, "[]");
                return;
            }

            const available_slots = self.bank.slot - start_slot + 1;
            const requested = if (limit < available_slots) limit else available_slots;
            const count = if (requested > std.math.maxInt(usize)) std.math.maxInt(usize) else @as(usize, @intCast(requested));

            try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":[", .{});
            var slot = start_slot;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (i > 0) try out.writer().print(",", .{});
                try out.writer().print("{d}", .{slot});
                if (slot == std.math.maxInt(types.Slot)) {
                    break;
                }
                slot += 1;
            }
            try out.writer().print("],\"id\":{s}}}", .{ id });
            return;
        }
        if (std.mem.eql(u8, method, "getBlockTime")) {
            const now = std.time.timestamp();
            try writeNumberResult(out, id, @as(u64, @intCast(now)));
            return;
        }
        if (std.mem.eql(u8, method, "getFirstAvailableBlock")) {
            try writeNumberResult(out, id, 0);
            return;
        }
        if (std.mem.eql(u8, method, "getTransaction")) {
            try writeNullResult(out, id);
            return;
        }
        if (std.mem.eql(u8, method, "getSignaturesForAddress")) {
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":[]}},\"id\":{s}}}",
                .{ self.bank.slot, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getSignatureStatuses")) {
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":[]}},\"id\":{s}}}",
                .{ self.bank.slot, id },
            );
            return;
        }

        if (std.mem.eql(u8, method, "getFeeForMessage")) {
            const msg_b64 = parseNthStringParam(self.allocator, body, 0) orelse return Error.InvalidParams;
            var decoded = std.array_list.Managed(u8).init(self.allocator);
            defer decoded.deinit();

            const decoded_capacity = try std.base64.standard.Decoder.calcSizeUpperBound(msg_b64.len);
            try decoded.resize(decoded_capacity);
            const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(msg_b64);
            try decoded.resize(decoded_len);
            try std.base64.standard.Decoder.decode(decoded.items, msg_b64);
            if (decoded_len < 2) return Error.InvalidParams;

            const sig_count = std.mem.readInt(u16, decoded.items[0..2], .little);
            const fee = self.bank.calcFee(sig_count);
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":{d}}},\"id\":{s}}}",
                .{ self.bank.slot, fee, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getRecentPrioritizationFees")) {
            try writeSuccessResult(out, id, "[]");
            return;
        }
        if (std.mem.eql(u8, method, "getStakeMinimumDelegation")) {
            try writeSuccessResult(out, id, "{\"value\":1}");
            return;
        }
        if (std.mem.eql(u8, method, "getSupply")) {
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":{{\"total\":1000000000000,\"circulating\":1000000000000,\"nonCirculating\":0}}}},\"id\":{s}}}",
                .{ self.bank.slot, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getVoteAccounts")) {
            var pk_buf: [64]u8 = undefined;
            const vote_text = try base58.encode(&self.identity.bytes, &pk_buf);
            try out.writer().print(
                "{{\"jsonrpc\":\"2.0\",\"result\":{{\"current\":[{{\"votePubkey\":\"{s}\",\"nodePubkey\":\"{s}\",\"activatedStake\":0,\"epochVoteAccount\":0,\"commission\":0,\"lastVote\":0,\"epochCredits\":[]}}],\"delinquent\":[]}},\"id\":{s}}}",
                .{ vote_text, vote_text, id },
            );
            return;
        }
        if (std.mem.eql(u8, method, "getMaxRetransmitSlot")) {
            try writeNumberResult(out, id, self.bank.slot);
            return;
        }
        if (std.mem.eql(u8, method, "getMaxShredInsertSlot")) {
            try writeNumberResult(out, id, self.bank.slot);
            return;
        }
        if (std.mem.eql(u8, method, "minimumLedgerSlot")) {
            try writeNumberResult(out, id, 0);
            return;
        }

        if (std.mem.eql(u8, method, "accountSubscribe") or
            std.mem.eql(u8, method, "slotSubscribe") or
            std.mem.eql(u8, method, "logsSubscribe"))
        {
            try writeNumberResult(out, id, 1);
            return;
        }

        return Error.InvalidMethod;
    }
};

fn writeSuccessResult(out: *std.array_list.Managed(u8), id: []const u8, value: []const u8) !void {
    try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{s},\"id\":{s}}}", .{ value, id });
}

const WebSocketSubscriptionKind = enum {
    slot,
    logs,
    account,
};

const WebSocketSubscription = struct {
    id: u64,
    kind: WebSocketSubscriptionKind,
    pubkey: types.Pubkey = .{ .bytes = [_]u8{0} ** 32 },
    has_account: bool = false,
    lamports: u64 = 0,
    data_len: usize = 0,
    data_hash: u64 = 0,
};

const WebSocketState = struct {
    subscriptions: std.array_list.Managed(WebSocketSubscription),
    last_slot: types.Slot,
};

const WsFrame = struct {
    opcode: u8,
    payload: []u8,
};

fn isWebSocketUpgrade(headers: []const u8) bool {
    const upgrade_value = parseHeaderValue(headers, "upgrade") orelse return false;
    if (!std.ascii.eqlIgnoreCase(upgrade_value, "websocket")) return false;
    const connection_value = parseHeaderValue(headers, "connection") orelse return false;
    return headerValueContainsToken(connection_value, "upgrade");
}

fn websocketAcceptKey(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var concat: [128]u8 = undefined;
    const guid_len = WEBSOCKET_GUID.len;
    const needed = key.len + guid_len;
    if (needed > concat.len) return Error.InvalidRequest;

    @memcpy(concat[0..key.len], key);
    @memcpy(concat[key.len..needed], WEBSOCKET_GUID);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(concat[0..needed], &digest, .{});

    var encoded: [32]u8 = undefined;
    const encoded_slice = std.base64.standard.Encoder.encode(encoded[0..], &digest);
    return allocator.dupe(u8, encoded_slice);
}

fn parseHeaderValue(headers: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) return null;

        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        if (colon == 0) continue;

        const raw_key = trimAsciiSpace(line[0..colon]);
        if (!std.ascii.eqlIgnoreCase(raw_key, key)) continue;

        var value_start = colon + 1;
        while (value_start < line.len and (line[value_start] == ' ' or line[value_start] == '\t')) : (value_start += 1) {}
        if (value_start >= line.len) return "";
        return trimAsciiSpace(line[value_start..]);
    }
    return null;
}

fn headerValueContainsToken(value: []const u8, token: []const u8) bool {
    var i: usize = 0;
    while (i < value.len) {
        while (i < value.len and (value[i] == ' ' or value[i] == '\t' or value[i] == ',')) : (i += 1) {}
        const start = i;
        while (i < value.len and value[i] != ',') : (i += 1) {}
        const part = trimAsciiSpace(value[start..i]);
        if (std.ascii.eqlIgnoreCase(part, token)) {
            return true;
        }
        if (i < value.len and value[i] == ',') i += 1;
    }
    return false;
}

fn trimAsciiSpace(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and (text[start] == ' ' or text[start] == '\t' or text[start] == '\r' or text[start] == '\n')) : (start += 1) {}
    var end = text.len;
    while (end > start and (text[end - 1] == ' ' or text[end - 1] == '\t' or text[end - 1] == '\r' or text[end - 1] == '\n')) : (end -= 1) {}
    return text[start..end];
}

fn parseSubscriptionIdParam(allocator: std.mem.Allocator, body: []const u8) ?u64 {
    const ids = parseTopLevelUnsignedParams(allocator, body) catch return null;
    defer allocator.free(ids);
    if (ids.len == 0) return null;
    return ids[0];
}

fn readWebSocketFrame(allocator: std.mem.Allocator, conn: std.posix.socket_t) !WsFrame {
    var frame_header: [2]u8 = undefined;
    try recvExact(conn, &frame_header);

    if ((frame_header[0] & 0x80) == 0) return error.InvalidFrame;
    const opcode = frame_header[0] & 0x0f;
    if (opcode != 0x1 and opcode != 0x8 and opcode != 0x9 and opcode != 0xA) return error.UnsupportedFrame;

    const masked = (frame_header[1] & 0x80) == 0x80;
    if (!masked) return error.InvalidFrame;

    var payload_len: usize = @intCast(frame_header[1] & 0x7f);
    if (payload_len == 126) {
        var ext = [_]u8{0} ** 2;
        try recvExact(conn, &ext);
        payload_len = @as(usize, std.mem.readInt(u16, &ext, .big));
    } else if (payload_len == 127) {
        var ext = [_]u8{0} ** 8;
        try recvExact(conn, &ext);
        const wide_len = std.mem.readInt(u64, &ext, .big);
        if (wide_len > MAX_BODY_BYTES) return error.InvalidFrame;
        payload_len = @intCast(wide_len);
    }
    if (payload_len > MAX_BODY_BYTES) return error.InvalidFrame;

    var mask: [4]u8 = undefined;
    try recvExact(conn, &mask);
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    if (payload_len > 0) try recvExact(conn, payload);

    var i: usize = 0;
    while (i < payload_len) : (i += 1) {
        payload[i] ^= mask[i % 4];
    }

    return .{
        .opcode = opcode,
        .payload = payload,
    };
}

fn recvExact(conn: std.posix.socket_t, buffer: []u8) !void {
    var got: usize = 0;
    while (got < buffer.len) {
        const n = try std.posix.recv(conn, buffer[got..], 0);
        if (n == 0) return error.ConnectionClosed;
        got += n;
    }
}

fn sendWebSocketFrame(conn: std.posix.socket_t, payload: []const u8) !void {
    return sendWebSocketFrameWithOpcode(conn, 0x1, payload);
}

fn sendWebSocketFrameWithOpcode(conn: std.posix.socket_t, opcode: u8, payload: []const u8) !void {
    var header: [14]u8 = undefined;
    var len: usize = 0;
    header[len] = 0x80 | (opcode & 0x0f);
    len += 1;

    if (payload.len <= 125) {
        header[len] = @intCast(payload.len);
        len += 1;
    } else if (payload.len <= 0xffff) {
        header[len] = 126;
        len += 1;
        std.mem.writeInt(u16, header[len..][0..2], @intCast(payload.len), .big);
        len += 2;
    } else {
        header[len] = 127;
        len += 1;
        std.mem.writeInt(u64, header[len..][0..8], @intCast(payload.len), .big);
        len += 8;
    }

    _ = try std.posix.send(conn, header[0..len], 0);
    if (payload.len > 0) _ = try std.posix.send(conn, payload, 0);
}

fn sendWebSocketClose(conn: std.posix.socket_t) !void {
    const close_payload = &[_]u8{ 0x03, 0xE8 };
    try sendWebSocketFrameWithOpcode(conn, 0x8, close_payload);
}

fn writeSlotNotification(out: *std.array_list.Managed(u8), slot: types.Slot, subscription_id: u64) !void {
    const parent_slot = if (slot == 0) 0 else slot - 1;
            try out.writer().print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"slotNotification\",\"params\":{{\"result\":{{\"parent\":{d},\"slot\":{d}}},\"subscription\":{d}}}}}",
        .{ parent_slot, slot, subscription_id },
    );
}

fn writeLogsNotification(out: *std.array_list.Managed(u8), slot: types.Slot, subscription_id: u64) !void {
    try out.writer().print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"logsNotification\",\"params\":{{\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":{{\"signature\":null,\"err\":null,\"logs\":[\"slot {d}\"]}}}},\"subscription\":{d}}}}}",
        .{ slot, slot, subscription_id },
    );
}

fn writeAccountNotification(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(u8),
    pk: types.Pubkey,
    account: *const accounts_db.StoredAccount,
    slot: types.Slot,
    subscription_id: u64,
) !void {
    try out.writer().writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"accountNotification\",\"params\":{\"result\":{\"context\":{\"slot\":");
    try out.writer().print("{d},\"value\":", .{slot});
    try writeAccountObject(out, allocator, pk, account, false);
    try out.writer().writeAll(",\"subscription\":");
    try out.writer().print("{d}", .{subscription_id});
    try out.writer().writeAll("}}");
}

fn writeMissingAccountNotification(out: *std.array_list.Managed(u8), subscription_id: u64) !void {
    try out.writer().writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"accountNotification\",\"params\":{\"result\":{\"context\":{\"slot\":0},\"value\":null");
    try out.writer().writeAll(",\"subscription\":");
    try out.writer().print("{d}", .{subscription_id});
    try out.writer().writeAll("}}");
}

fn initializeAccountSubscriptionState(self: *RpcServer, sub: *WebSocketSubscription) void {
    if (self.bank.db.get(sub.pubkey)) |acct| {
        defer self.allocator.free(acct.data);
        sub.has_account = true;
        sub.lamports = acct.lamports;
        sub.data_len = acct.data.len;
        sub.data_hash = std.hash.Wyhash.hash(0, acct.data);
    } else {
        sub.has_account = false;
        sub.lamports = 0;
        sub.data_len = 0;
        sub.data_hash = 0;
    }
}

fn writeNumberResult(out: *std.array_list.Managed(u8), id: []const u8, value: anytype) !void {
    try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{d},\"id\":{s}}}", .{ value, id });
}

fn writeNullResult(out: *std.array_list.Managed(u8), id: []const u8) !void {
    try writeSuccessResult(out, id, "null");
}

fn writeAccountResponse(
    out: *std.array_list.Managed(u8),
    allocator: std.mem.Allocator,
    id: []const u8,
    pk: types.Pubkey,
    account: *const accounts_db.StoredAccount,
    slot: types.Slot,
) !void {
    try out.writer().print("{{\"jsonrpc\":\"2.0\",\"result\":{{\"context\":{{\"slot\":{d}}},\"value\":", .{ slot });
    try writeAccountObject(out, allocator, pk, account, false);
    try out.writer().print("}},\"id\":{s}}}", .{id});
}

fn writeAccountLite(
    out: *std.array_list.Managed(u8),
    allocator: std.mem.Allocator,
    pk: types.Pubkey,
    account: accounts_db.StoredAccount,
    include_pubkey_field: bool,
) !void {
    try writeAccountObject(out, allocator, pk, &account, include_pubkey_field);
}

fn writeProgramAccount(
    out: *std.array_list.Managed(u8),
    allocator: std.mem.Allocator,
    pk: types.Pubkey,
    account: accounts_db.StoredAccount,
) !void {
    var pk_buf: [64]u8 = undefined;
    const pk_text = try base58.encode(&pk.bytes, &pk_buf);
    try out.writer().print("{{\"pubkey\":\"{s}\",\"account\":", .{pk_text});
    try writeAccountObject(out, allocator, pk, &account, false);
    try out.writer().print("}}", .{});
}

fn writeAccountObject(
    out: *std.array_list.Managed(u8),
    allocator: std.mem.Allocator,
    pk: types.Pubkey,
    account: *const accounts_db.StoredAccount,
    include_pubkey_field: bool,
) !void {
    var owner_buf: [64]u8 = undefined;
    const owner_text = try base58.encode(&account.owner.bytes, &owner_buf);

    var data_b64 = std.array_list.Managed(u8).init(allocator);
    defer data_b64.deinit();
    try data_b64.resize(std.base64.standard.Encoder.calcSize(account.data.len));
    const encoded = std.base64.standard.Encoder.encode(data_b64.items, account.data);
    const encoded_len = encoded.len;

    if (include_pubkey_field) {
        var key_buf: [64]u8 = undefined;
        const key_text = try base58.encode(&pk.bytes, &key_buf);
        try out.writer().print(
            "{{\"lamports\":{d},\"owner\":\"{s}\",\"executable\":{any},\"rentEpoch\":{d},\"data\":[\"{s}\",\"base64\"],\"pubkey\":\"{s}\"}}",
            .{ account.lamports, owner_text, account.executable, account.rent_epoch, data_b64.items[0..encoded_len], key_text },
        );
    } else {
        try out.writer().print(
            "{{\"lamports\":{d},\"owner\":\"{s}\",\"executable\":{any},\"rentEpoch\":{d},\"data\":[\"{s}\",\"base64\"]}}",
            .{ account.lamports, owner_text, account.executable, account.rent_epoch, data_b64.items[0..encoded_len] },
        );
    }
}

fn writeErrorResponse(out: *std.array_list.Managed(u8), id: []const u8, code: i32, msg: []const u8, data: []const u8) !void {
    try out.writer().print(
        "{{\"jsonrpc\":\"2.0\",\"error\":{{\"code\":{d},\"message\":\"{s}\",\"data\":{s}}},\"id\":{s}}}",
        .{ code, msg, data, id },
    );
}

fn parseContentLength(header: []const u8) !usize {
    const key = "Content-Length";
    const start = std.mem.indexOf(u8, header, key) orelse return Error.InvalidRequest;
    var i = start + key.len;
    while (i < header.len and (header[i] == ' ' or header[i] == '\t')) : (i += 1) {}
    if (i >= header.len or header[i] != ':') return Error.InvalidRequest;
    i += 1;
    while (i < header.len and (header[i] == ' ' or header[i] == '\t')) : (i += 1) {}
    const len_start = i;
    while (i < header.len and header[i] >= '0' and header[i] <= '9') : (i += 1) {}
    if (len_start == i) return Error.InvalidRequest;
    return std.fmt.parseInt(usize, header[len_start..i], 10) catch Error.InvalidRequest;
}

fn parseId(body: []const u8) ![]const u8 {
    const pos = findKey(body, "id") orelse return Error.InvalidRequest;
    var i = pos + 3;
    while (i < body.len and body[i] != ':') : (i += 1) {}
    if (i >= body.len) return Error.InvalidRequest;
    i += 1;
    while (i < body.len and (body[i] == ' ' or body[i] == '\n' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len) return Error.InvalidRequest;

    if (body[i] == '"') {
        const start = i;
        i += 1;
        while (i < body.len and body[i] != '"') : (i += 1) {}
        if (i >= body.len) return Error.InvalidRequest;
        return body[start .. i + 1];
    }

    const start = i;
    while (i < body.len and (body[i] == '-' or (body[i] >= '0' and body[i] <= '9'))) : (i += 1) {}
    if (start == i) return Error.InvalidRequest;
    return body[start..i];
}

fn parseStringField(body: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = findKey(body, key) orelse return null;
    var i = key_pos + key.len + 2;
    while (i < body.len and (body[i] == ' ' or body[i] == '\n' or body[i] == '\t' or body[i] == '\r')) : (i += 1) {}
    if (i >= body.len or body[i] != ':') return null;
    i += 1;
    while (i < body.len and (body[i] == ' ' or body[i] == '\n' or body[i] == '\t' or body[i] == '\r')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i >= body.len) return null;
    return body[start..i];
}

fn parsePubkeyField(body: []const u8) ?types.Pubkey {
    if (parseStringField(body, "pubkey")) |pk_text| {
        return decodePubkeyFromText(pk_text);
    }

    const params_pos = findKey(body, "params") orelse return null;
    var i = params_pos + 7;
    while (i < body.len and body[i] != '[') : (i += 1) {}
    if (i >= body.len) return null;
    while (i < body.len and (body[i] == ' ' or body[i] == '\n' or body[i] == '\t')) : (i += 1) {}
    i += 1;
    if (i >= body.len or body[i] != '"') return null;
    const start = i + 1;
    i = start;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i >= body.len) return null;
    return decodePubkeyFromText(body[start..i]);
}

fn parseTopLevelPubkeys(allocator: std.mem.Allocator, body: []const u8) ![]types.Pubkey {
    const strings = try parseTopLevelParamsStrings(allocator, body);
    defer allocator.free(strings);

    var keys = std.array_list.Managed(types.Pubkey).init(allocator);
    errdefer keys.deinit();

    for (strings) |pk_text| {
        const pk = decodePubkeyFromText(pk_text) orelse return Error.InvalidParams;
        try keys.append(pk);
    }

    return keys.toOwnedSlice();
}

fn parseNthStringParam(allocator: std.mem.Allocator, body: []const u8, index: usize) ?[]const u8 {
    const strings = parseTopLevelParamsStrings(allocator, body) catch return null;
    defer allocator.free(strings);
    if (index >= strings.len) return null;
    return strings[index];
}

fn parseTopLevelParamsStrings(allocator: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    const params_pos = findKey(body, "params") orelse {
        return try allocator.alloc([]const u8, 0);
    };

    var i = params_pos + 7;
    while (i < body.len and body[i] != '[') : (i += 1) {}
    if (i >= body.len) return Error.InvalidParams;

    i += 1;
    var out = std.array_list.Managed([]const u8).init(allocator);
    errdefer out.deinit();

    var curly_depth: usize = 0;
    var nested_array_depth: usize = 0;
    while (i < body.len) {
        while (i < body.len and (body[i] == ' ' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t' or body[i] == ',')) : (i += 1) {}
        if (i >= body.len) return Error.InvalidParams;

        if (body[i] == ']' and nested_array_depth == 0 and curly_depth == 0) break;

        switch (body[i]) {
            '[' => {
                nested_array_depth += 1;
                i += 1;
            },
            ']' => {
                if (nested_array_depth == 0) break;
                nested_array_depth -= 1;
                i += 1;
            },
            '{' => {
                curly_depth += 1;
                i += 1;
            },
            '}' => {
                if (curly_depth == 0) return Error.InvalidParams;
                curly_depth -= 1;
                i += 1;
            },
            '"' => {
                const start = i + 1;
                i = start;
                while (i < body.len and body[i] != '"') : (i += 1) {}
                if (i >= body.len) return Error.InvalidParams;
                if (nested_array_depth == 0 and curly_depth == 0) {
                    try out.append(body[start..i]);
                }
                i += 1;
            },
            else => i += 1,
        }
    }

    return out.toOwnedSlice();
}

fn parseTopLevelUnsignedParams(allocator: std.mem.Allocator, body: []const u8) ![]types.Slot {
    const params_pos = findKey(body, "params") orelse {
        return try allocator.alloc(types.Slot, 0);
    };

    var i = params_pos + 7;
    while (i < body.len and body[i] != '[') : (i += 1) {}
    if (i >= body.len) return Error.InvalidParams;
    i += 1;

    var out = std.array_list.Managed(types.Slot).init(allocator);
    errdefer out.deinit();

    var curly_depth: usize = 0;
    var nested_array_depth: usize = 0;
    while (i < body.len) {
        while (i < body.len and (body[i] == ' ' or body[i] == '\n' or body[i] == '\r' or body[i] == '\t' or body[i] == ',')) : (i += 1) {}
        if (i >= body.len) return Error.InvalidParams;
        if (body[i] == ']' and nested_array_depth == 0 and curly_depth == 0) break;

        switch (body[i]) {
            '[' => {
                nested_array_depth += 1;
                i += 1;
            },
            ']' => {
                if (nested_array_depth == 0) break;
                nested_array_depth -= 1;
                i += 1;
            },
            '{' => {
                curly_depth += 1;
                i += 1;
            },
            '}' => {
                if (curly_depth == 0) return Error.InvalidParams;
                curly_depth -= 1;
                i += 1;
            },
            '0'...'9' => {
                if (nested_array_depth == 0 and curly_depth == 0) {
                    const start = i;
                    i += 1;
                    while (i < body.len and (body[i] >= '0' and body[i] <= '9')) : (i += 1) {}
                    const value = std.fmt.parseUnsigned(types.Slot, body[start..i], 10) catch return Error.InvalidParams;
                    try out.append(value);
                } else {
                    while (i < body.len and body[i] != ',' and body[i] != ']' and body[i] != '}') : (i += 1) {}
                }
            },
            '"' => {
                i += 1;
                while (i < body.len and body[i] != '"') : (i += 1) {}
                if (i >= body.len) return Error.InvalidParams;
                i += 1;
            },
            else => i += 1,
        }
    }

    return out.toOwnedSlice();
}

fn decodePubkeyFromText(pk_text: []const u8) ?types.Pubkey {
    var decoded_out: [64]u8 = undefined;
    const decoded = base58.decode(pk_text, &decoded_out) catch return null;
    if (decoded.len == 0 or decoded.len > 32) return null;
    var key_bytes: [32]u8 = .{0} ** 32;
    const offset = 32 - decoded.len;
    @memcpy(key_bytes[offset ..], decoded);
    return .{ .bytes = key_bytes };
}

fn parseNumericFromKey(body: []const u8, key: []const u8) ?[]const u8 {
    const params_pos = findKey(body, key) orelse return null;
    var i = params_pos + key.len + 2;
    while (i < body.len and body[i] != '[' and body[i] != ':' and body[i] != '"') : (i += 1) {}
    while (i < body.len and (body[i] == '[' or body[i] == ':' or body[i] == ' ' or body[i] == '\n' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len) return null;
    const start = i;
    if (start < body.len and (body[start] == '-' or (body[start] >= '0' and body[start] <= '9'))) {
        while (i < body.len and (body[i] == '-' or (body[i] >= '0' and body[i] <= '9'))) : (i += 1) {}
        return body[start..i];
    }
    return null;
}

const TokenAccountInfo = struct {
    mint: types.Pubkey,
    owner: types.Pubkey,
    amount: u64,
};

const MintInfo = struct {
    supply: u64,
    decimals: u8,
};

fn defaultTokenProgram() ?types.Pubkey {
    return decodePubkeyFromText(SPL_TOKEN_PROGRAM_ID);
}

fn parseTokenAccount(data: []const u8) ?TokenAccountInfo {
    if (data.len < SPL_TOKEN_ACCOUNT_MIN_SIZE) return null;

    var mint = types.Pubkey{ .bytes = undefined };
    @memcpy(&mint.bytes, data[SPL_TOKEN_ACCOUNT_MINT_OFFSET .. SPL_TOKEN_ACCOUNT_MINT_OFFSET + 32]);

    var owner = types.Pubkey{ .bytes = undefined };
    @memcpy(&owner.bytes, data[SPL_TOKEN_ACCOUNT_OWNER_OFFSET .. SPL_TOKEN_ACCOUNT_OWNER_OFFSET + 32]);

    const amount = std.mem.readInt(
        u64,
        data[SPL_TOKEN_ACCOUNT_AMOUNT_OFFSET .. SPL_TOKEN_ACCOUNT_AMOUNT_OFFSET + 8],
        .little,
    );

    return .{ .mint = mint, .owner = owner, .amount = amount };
}

fn parseMint(data: []const u8) ?MintInfo {
    if (data.len < SPL_MINT_MIN_SIZE) return null;

    const supply = std.mem.readInt(u64, data[SPL_MINT_SUPPLY_OFFSET .. SPL_MINT_SUPPLY_OFFSET + 8], .little);
    const decimals = data[SPL_MINT_DECIMALS_OFFSET];
    return .{ .supply = supply, .decimals = decimals };
}

fn formatUiAmount(allocator: std.mem.Allocator, amount: u64, decimals: u8) ![]u8 {
    const amount_text = try std.fmt.allocPrint(allocator, "{d}", .{amount});
    if (decimals == 0) return amount_text;

    defer allocator.free(amount_text);

    const scale = @as(usize, decimals);
    var ui = std.array_list.Managed(u8).init(allocator);
    errdefer ui.deinit();

    if (scale >= amount_text.len) {
        try ui.appendSlice("0.");
        var i: usize = 0;
        while (i + amount_text.len < scale) : (i += 1) {
            try ui.append('0');
        }
        try ui.appendSlice(amount_text);
    } else {
        const split = amount_text.len - scale;
        try ui.appendSlice(amount_text[0..split]);
        try ui.append('.');
        try ui.appendSlice(amount_text[split..]);
    }

    return ui.toOwnedSlice();
}

fn findKey(body: []const u8, key: []const u8) ?usize {
    if (key.len == 0) return null;
    var i: usize = 0;
    while (i + key.len + 2 <= body.len) : (i += 1) {
        if (body[i] != '"') continue;
        if (!std.mem.eql(u8, body[i + 1 .. i + 1 + key.len], key)) continue;
        if (i + key.len + 1 >= body.len) return null;
        if (body[i + 1 + key.len] != '"') continue;
        return i + 1;
    }
    return null;
}
