const std = @import("std");

pub const Metrics = struct {
    // Counters.
    transactions_processed: std.atomic.Value(u64),
    transactions_ok: std.atomic.Value(u64),
    transactions_failed: std.atomic.Value(u64),
    slots_processed: std.atomic.Value(u64),
    gossip_messages_recv: std.atomic.Value(u64),
    gossip_messages_sent: std.atomic.Value(u64),
    rpc_requests: std.atomic.Value(u64),
    rpc_errors: std.atomic.Value(u64),

    // Gauges.
    current_slot: std.atomic.Value(u64),
    peer_count: std.atomic.Value(u64),
    accounts_count: std.atomic.Value(u64),

    // Approximate histograms.
    tx_process_time_ns_sum: std.atomic.Value(u64),
    tx_process_time_ns_count: std.atomic.Value(u64),
    rpc_latency_ns_sum: std.atomic.Value(u64),
    rpc_latency_ns_count: std.atomic.Value(u64),

    pub fn init() Metrics {
        return .{
            .transactions_processed = std.atomic.Value(u64).init(0),
            .transactions_ok = std.atomic.Value(u64).init(0),
            .transactions_failed = std.atomic.Value(u64).init(0),
            .slots_processed = std.atomic.Value(u64).init(0),
            .gossip_messages_recv = std.atomic.Value(u64).init(0),
            .gossip_messages_sent = std.atomic.Value(u64).init(0),
            .rpc_requests = std.atomic.Value(u64).init(0),
            .rpc_errors = std.atomic.Value(u64).init(0),
            .current_slot = std.atomic.Value(u64).init(0),
            .peer_count = std.atomic.Value(u64).init(0),
            .accounts_count = std.atomic.Value(u64).init(0),
            .tx_process_time_ns_sum = std.atomic.Value(u64).init(0),
            .tx_process_time_ns_count = std.atomic.Value(u64).init(0),
            .rpc_latency_ns_sum = std.atomic.Value(u64).init(0),
            .rpc_latency_ns_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn renderPrometheus(self: *const Metrics, writer: anytype) !void {
        const tx_ok = self.transactions_ok.load(.acquire);
        const tx_fail = self.transactions_failed.load(.acquire);
        const tx_total = tx_ok + tx_fail;
        const slots = self.slots_processed.load(.acquire);
        const g_recv = self.gossip_messages_recv.load(.acquire);
        const g_sent = self.gossip_messages_sent.load(.acquire);
        const rpc_requests = self.rpc_requests.load(.acquire);
        const rpc_errors = self.rpc_errors.load(.acquire);
        const slot = self.current_slot.load(.acquire);
        const peers = self.peer_count.load(.acquire);
        const accounts = self.accounts_count.load(.acquire);
        const tx_time_sum = self.tx_process_time_ns_sum.load(.acquire);
        const tx_time_count = self.tx_process_time_ns_count.load(.acquire);
        const rpc_time_sum = self.rpc_latency_ns_sum.load(.acquire);
        const rpc_time_count = self.rpc_latency_ns_count.load(.acquire);

        try writer.print("# HELP solana_transactions_total Total transactions processed\n", .{});
        try writer.print("# TYPE solana_transactions_total counter\n", .{});
        try writer.print("solana_transactions_total {d}\n\n", .{tx_total});

        try writer.print("# HELP solana_transactions_ok Total successful transactions\n", .{});
        try writer.print("# TYPE solana_transactions_ok counter\n", .{});
        try writer.print("solana_transactions_ok {d}\n\n", .{tx_ok});

        try writer.print("# HELP solana_transactions_failed Total failed transactions\n", .{});
        try writer.print("# TYPE solana_transactions_failed counter\n", .{});
        try writer.print("solana_transactions_failed {d}\n\n", .{tx_fail});

        try writer.print("# HELP solana_slots_processed_total Total slots processed\n", .{});
        try writer.print("# TYPE solana_slots_processed_total counter\n", .{});
        try writer.print("solana_slots_processed_total {d}\n\n", .{slots});

        try writer.print("# HELP solana_gossip_messages_received_total Gossip packets received\n", .{});
        try writer.print("# TYPE solana_gossip_messages_received_total counter\n", .{});
        try writer.print("solana_gossip_messages_received_total {d}\n\n", .{g_recv});

        try writer.print("# HELP solana_gossip_messages_sent_total Gossip packets sent\n", .{});
        try writer.print("# TYPE solana_gossip_messages_sent_total counter\n", .{});
        try writer.print("solana_gossip_messages_sent_total {d}\n\n", .{g_sent});

        try writer.print("# HELP solana_rpc_requests_total Total RPC requests\n", .{});
        try writer.print("# TYPE solana_rpc_requests_total counter\n", .{});
        try writer.print("solana_rpc_requests_total {d}\n\n", .{rpc_requests});

        try writer.print("# HELP solana_rpc_errors_total Total RPC errors\n", .{});
        try writer.print("# TYPE solana_rpc_errors_total counter\n", .{});
        try writer.print("solana_rpc_errors_total {d}\n\n", .{rpc_errors});

        try writer.print("# HELP solana_current_slot Current bank slot\n", .{});
        try writer.print("# TYPE solana_current_slot gauge\n", .{});
        try writer.print("solana_current_slot {d}\n\n", .{slot});

        try writer.print("# HELP solana_peer_count Number of peers\n", .{});
        try writer.print("# TYPE solana_peer_count gauge\n", .{});
        try writer.print("solana_peer_count {d}\n\n", .{peers});

        try writer.print("# HELP solana_accounts_count Number of accounts\n", .{});
        try writer.print("# TYPE solana_accounts_count gauge\n", .{});
        try writer.print("solana_accounts_count {d}\n\n", .{accounts});

        try writer.print("# HELP solana_transaction_process_time_ns_sum Sum of transaction processing durations in ns\n", .{});
        try writer.print("# TYPE solana_transaction_process_time_ns_sum gauge\n", .{});
        try writer.print("solana_transaction_process_time_ns_sum {d}\n", .{tx_time_sum});

        try writer.print("# HELP solana_transaction_process_time_ns_count Count of transaction processing timing samples\n", .{});
        try writer.print("# TYPE solana_transaction_process_time_ns_count gauge\n", .{});
        try writer.print("solana_transaction_process_time_ns_count {d}\n\n", .{tx_time_count});

        try writer.print("# HELP solana_rpc_latency_ns_sum Sum of RPC latencies in ns\n", .{});
        try writer.print("# TYPE solana_rpc_latency_ns_sum gauge\n", .{});
        try writer.print("solana_rpc_latency_ns_sum {d}\n", .{rpc_time_sum});

        try writer.print("# HELP solana_rpc_latency_ns_count Count of RPC timing samples\n", .{});
        try writer.print("# TYPE solana_rpc_latency_ns_count gauge\n", .{});
        try writer.print("solana_rpc_latency_ns_count {d}\n", .{rpc_time_count});
    }
};

pub var GLOBAL: Metrics = Metrics.init();

// ── OpenTelemetry OTLP HTTP export (Phase 5c) ────────────────────────────────
//
// Exports metrics as OTLP JSON to http://localhost:4318/v1/metrics every
// OTLP_FLUSH_INTERVAL_S seconds via a background thread.
//
// Wire format: OTLP Protobuf-JSON (application/json, POST).
// Compatible with OpenTelemetry Collector, Grafana Agent, etc.

const OTLP_HOST:             []const u8 = "127.0.0.1";
const OTLP_PORT:             u16        = 4318;
const OTLP_PATH:             []const u8 = "/v1/metrics";
const OTLP_FLUSH_INTERVAL_S: u64        = 10;

pub const OtlpExporter = struct {
    allocator: std.mem.Allocator,
    metrics:   *const Metrics,
    slot:      u64,  // per-flush slot label (updated by caller)
    epoch:     u64,

    pub fn init(allocator: std.mem.Allocator, m: *const Metrics) OtlpExporter {
        return .{ .allocator = allocator, .metrics = m, .slot = 0, .epoch = 0 };
    }

    /// Build the OTLP JSON payload for the current metric snapshot.
    pub fn buildJsonPayload(self: *const OtlpExporter, writer: anytype) !void {
        const tx_ok    = self.metrics.transactions_ok.load(.acquire);
        const tx_fail  = self.metrics.transactions_failed.load(.acquire);
        const tx_total = tx_ok + tx_fail;
        const slots    = self.metrics.slots_processed.load(.acquire);
        const cur_slot = self.metrics.current_slot.load(.acquire);
        const peers    = self.metrics.peer_count.load(.acquire);
        const accounts = self.metrics.accounts_count.load(.acquire);
        const tx_t_sum = self.metrics.tx_process_time_ns_sum.load(.acquire);
        const tx_t_cnt = self.metrics.tx_process_time_ns_count.load(.acquire);

        // OTLP JSON envelope (simplified — not full proto-JSON but OTel collector accepts it).
        try writer.writeAll("{\"resourceMetrics\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"sol.zig\"}}]},\"scopeMetrics\":[{\"metrics\":[");

        var first = true;
        inline for (.{
            .{ "solana.transactions.total",       tx_total,  "cumulativeTemporality" },
            .{ "solana.transactions.ok",          tx_ok,     "cumulativeTemporality" },
            .{ "solana.transactions.failed",      tx_fail,   "cumulativeTemporality" },
            .{ "solana.slots.processed",          slots,     "cumulativeTemporality" },
            .{ "solana.current_slot",             cur_slot,  "gauge" },
            .{ "solana.peer_count",               peers,     "gauge" },
            .{ "solana.accounts_count",           accounts,  "gauge" },
            .{ "solana.tx.process_time_ns.sum",   tx_t_sum,  "gauge" },
            .{ "solana.tx.process_time_ns.count", tx_t_cnt,  "gauge" },
        }) |entry| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print(
                "{{\"name\":\"{s}\",\"gauge\":{{\"dataPoints\":[{{\"asInt\":{d},\"attributes\":[{{\"key\":\"slot\",\"value\":{{\"intValue\":{d}}}}},{{\"key\":\"epoch\",\"value\":{{\"intValue\":{d}}}}}]}}]}}}}",
                .{ entry[0], entry[1], self.slot, self.epoch },
            );
        }

        try writer.writeAll("]}]}]}");
    }

    /// POST the current snapshot to the OTLP HTTP endpoint.
    /// Non-fatal: errors are silently swallowed so the validator keeps running.
    pub fn flush(self: *const OtlpExporter) void {
        self.flushInner() catch {};
    }

    fn flushInner(self: *const OtlpExporter) !void {
        var payload = std.ArrayList(u8).init(self.allocator);
        defer payload.deinit();
        try self.buildJsonPayload(payload.writer());

        // Open TCP connection to OTLP collector.
        const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, OTLP_PORT);
        const conn = std.net.tcpConnectToAddress(addr) catch return;
        defer conn.close();

        // HTTP/1.1 POST.
        var req_buf: [1024]u8 = undefined;
        const header = std.fmt.bufPrint(&req_buf,
            "POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
            .{ OTLP_PATH, OTLP_HOST, OTLP_PORT, payload.items.len },
        ) catch return;

        try conn.writeAll(header);
        try conn.writeAll(payload.items);

        // Read (and discard) the response to let the collector process the write.
        var resp_buf: [256]u8 = undefined;
        _ = conn.reader().read(&resp_buf) catch {};
    }
};

/// Background export loop — runs every OTLP_FLUSH_INTERVAL_S seconds.
/// Spawns a thread; call `stop_flag.store(false, .release)` to exit.
pub fn runOtlpExportLoop(exporter: *OtlpExporter, stop_flag: *std.atomic.Value(bool)) void {
    while (!stop_flag.load(.acquire)) {
        std.Thread.sleep(OTLP_FLUSH_INTERVAL_S * std.time.ns_per_s);
        if (stop_flag.load(.acquire)) break;
        exporter.flush();
    }
}

test "metrics emits basic prometheus payload" {
    var output = std.array_list.Managed(u8).init(std.testing.allocator);
    defer output.deinit();
    try GLOBAL.renderPrometheus(output.writer());
    try std.testing.expect(output.items.len > 100);
}
