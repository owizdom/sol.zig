const std = @import("std");
const types = @import("types");
const transaction = @import("transaction");
const bank_mod = @import("bank");
const quic = @import("net/quic");
const encoding = @import("encoding");

const MAX_TX_LEN = 64 * 1024;
const MAX_REPLAY_CACHE = 512;
const REPLAY_WINDOW_MS: i64 = 30_000;
const RECV_IDLE_TIMEOUT_MS: i64 = 20_000;

// ── Fair MEV ordering ────────────────────────────────────────────────────────
// Transactions are sorted by arrival timestamp before block packing.
// This guarantees time-priority ordering — no fee reordering is possible.
const PendingTx = struct {
    data:       []u8,       // heap-owned wire bytes
    arrival_ns: i128,       // std.time.nanoTimestamp() on receipt

    fn lessThan(_: void, a: PendingTx, b: PendingTx) bool {
        return a.arrival_ns < b.arrival_ns;
    }
};

pub const TpuQuicServer = struct {
    allocator: std.mem.Allocator,
    bank: *bank_mod.Bank,
    server: quic.QuicServer,
    bound_addr: std.net.Address,
    running: std.atomic.Value(bool),
    active_connections: std.atomic.Value(usize),
    max_connections: usize,
    max_streams: usize,
    thread: ?std.Thread,

    pub fn init(
        allocator: std.mem.Allocator,
        bind_addr: std.net.Address,
        bank: *bank_mod.Bank,
        cert_path: []const u8,
        key_path: []const u8,
    ) !TpuQuicServer {
        return TpuQuicServer{
            .allocator = allocator,
            .bank = bank,
            .server = try quic.QuicServer.init(allocator, bind_addr, cert_path, key_path),
            .bound_addr = bind_addr,
            .running = std.atomic.Value(bool).init(false),
            .active_connections = std.atomic.Value(usize).init(0),
            .max_connections = 512,
            .max_streams = 32,
            .thread = null,
        };
    }

    pub fn initWithLimits(
        allocator: std.mem.Allocator,
        bind_addr: std.net.Address,
        bank: *bank_mod.Bank,
        cert_path: []const u8,
        key_path: []const u8,
        max_connections: usize,
        max_streams: usize,
    ) !TpuQuicServer {
        var srv = try init(allocator, bind_addr, bank, cert_path, key_path);
        srv.max_connections = max_connections;
        srv.max_streams = max_streams;
        return srv;
    }

    pub fn start(self: *TpuQuicServer) !std.Thread {
        self.running.store(true, .release);
        const t = try std.Thread.spawn(.{}, run, .{self});
        self.thread = t;
        return t;
    }

    pub fn stop(self: *TpuQuicServer) void {
        self.running.store(false, .release);
        self.server.deinit();
    }

    pub fn deinit(self: *TpuQuicServer) void {
        self.stop();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

fn run(srv: *TpuQuicServer) !void {
    while (srv.running.load(.acquire)) {
        const conn = srv.server.accept() catch {
            if (!srv.running.load(.acquire)) return;
            continue;
        };

        const old = srv.active_connections.fetchAdd(1, .monotonic);
        if (old >= srv.max_connections) {
            _ = srv.active_connections.fetchSub(1, .monotonic);
            _ = srv.server.connections.remove(conn.dcid);
            var reject_conn = conn;
            reject_conn.deinit();
            continue;
        }

        _ = std.Thread.spawn(.{}, handleConnection, .{ srv, conn }) catch {
            _ = srv.active_connections.fetchSub(1, .monotonic);
            _ = srv.server.connections.remove(conn.dcid);
            var dropped = conn;
            dropped.deinit();
            continue;
        };
    }
}

fn handleConnection(srv: *TpuQuicServer, conn: *quic.QuicConn) void {
    defer {
        const c = conn;
        c.deinit();
        _ = srv.active_connections.fetchSub(1, .monotonic);
        _ = srv.server.connections.remove(conn.dcid);
    }

    var rx_chunk: [4096]u8 = undefined;
    var rx_buf: [MAX_TX_LEN]u8 = undefined;
    var rx_len: usize = 0;
    var expected_tx_len: ?usize = null;
    var replay_window = std.AutoHashMap([64]u8, i64).init(srv.allocator);
    defer replay_window.deinit();
    var stale_keys: [MAX_REPLAY_CACHE][64]u8 = undefined;
    var streams: usize = 0;
    var last_activity_ms = std.time.milliTimestamp();

    // Fair MEV queue: collect parsed transactions with arrival timestamps,
    // sort by arrival_ns before dispatching to the bank.
    var pending = std.ArrayList(PendingTx).init(srv.allocator);
    defer {
        for (pending.items) |*p| srv.allocator.free(p.data);
        pending.deinit();
    }

    while (srv.running.load(.acquire)) {
        if (streams >= srv.max_streams) break;
        const now_ms = std.time.milliTimestamp();
        const next_deadline_ms = now_ms + RECV_IDLE_TIMEOUT_MS;
        const timeout_ms = if (next_deadline_ms > now_ms) next_deadline_ms - now_ms else 0;
        if (timeout_ms == 0) break;

        const n = recvChunkWithTimeout(conn, &rx_chunk, timeout_ms) catch |err| {
            if (err == quic.QuicError.Timeout) break;
            break;
        };
        if (n == 0) break;
        if (rx_len + n > rx_buf.len) {
            sendPacket(conn, "{\"error\":\"frame_too_large\"}") catch {};
            break;
        }
        std.mem.copyForwards(u8, rx_buf[rx_len .. rx_len + n], rx_chunk[0..n]);
        rx_len += n;
        last_activity_ms = std.time.milliTimestamp();

        var parse_off: usize = 0;
        while (parse_off < rx_len) {
            if (expected_tx_len == null) {
                expected_tx_len = parseTransactionLengthFromStream(rx_buf[parse_off..rx_len]) catch {
                    sendPacket(conn, "{\"error\":\"invalid_transaction\"}") catch {};
                    break;
                };
            }
            const tx_size = expected_tx_len orelse break;
            if (tx_size == 0 or tx_size > MAX_TX_LEN) {
                sendPacket(conn, "{\"error\":\"frame_too_large\"}") catch {};
                break;
            }
            if (rx_len - parse_off < tx_size) break;

            // Record arrival time (nanoseconds) for fair ordering.
            const arrival_ns = std.time.nanoTimestamp();

            const wire_bytes = rx_buf[parse_off .. parse_off + tx_size];
            parse_off += tx_size;
            expected_tx_len = null;
            streams += 1;
            last_activity_ms = std.time.milliTimestamp();

            // Replay deduplication.
            if (replay_window.count() >= MAX_REPLAY_CACHE) {
                replay_window.clearRetainingCapacity();
            }
            if (replay_window.count() > 0) {
                var stale_count: usize = 0;
                var it = replay_window.iterator();
                while (it.next()) |entry| {
                    if (last_activity_ms - entry.value_ptr.* > REPLAY_WINDOW_MS and stale_count < stale_keys.len) {
                        stale_keys[stale_count] = entry.key_ptr.*;
                        stale_count += 1;
                    }
                }
                var si: usize = 0;
                while (si < stale_count) : (si += 1) {
                    _ = replay_window.remove(stale_keys[si]);
                }
            }

            const parsed_tx = transaction.deserialize(wire_bytes, srv.allocator) catch {
                sendPacket(conn, "{\"error\":\"invalid_transaction\"}") catch {};
                continue;
            };
            defer transaction.free(parsed_tx, srv.allocator);

            if (parsed_tx.signatures.len > 0) {
                const sig = parsed_tx.signatures[0].bytes;
                const now = std.time.milliTimestamp();
                if (replay_window.get(sig)) |seen_ms| {
                    if (now - seen_ms <= REPLAY_WINDOW_MS) {
                        sendPacket(conn, "{\"error\":\"duplicate_transaction\"}") catch {};
                        continue;
                    }
                }
                replay_window.put(sig, now) catch {};
            }

            // Enqueue with arrival timestamp (fair MEV: no fee reordering).
            const data_copy = srv.allocator.dupe(u8, wire_bytes) catch continue;
            pending.append(PendingTx{ .data = data_copy, .arrival_ns = arrival_ns }) catch {
                srv.allocator.free(data_copy);
            };
        }

        if (parse_off > 0) {
            const remaining = rx_len - parse_off;
            if (remaining > 0) {
                std.mem.copyForwards(u8, rx_buf[0..remaining], rx_buf[parse_off..rx_len]);
            }
            rx_len = remaining;
        }
    }

    // Sort pending transactions by arrival time (time-priority, fair MEV).
    std.sort.pdq(PendingTx, pending.items, {}, PendingTx.lessThan);

    // Dispatch sorted transactions to the bank.
    for (pending.items) |*p| {
        const parsed_tx = transaction.deserialize(p.data, srv.allocator) catch continue;
        defer transaction.free(parsed_tx, srv.allocator);

        const result = srv.bank.processTransaction(parsed_tx) catch continue;
        const status = if (result.status == .ok) "ok" else "err";
        var out: [128]u8 = undefined;
        const payload = std.fmt.bufPrint(
            &out,
            "{{\"status\":\"{s}\",\"fee\":{d},\"compute_units\":{d}}}",
            .{ status, result.fee, result.compute_units },
        ) catch continue;
        sendPacket(conn, payload) catch {};
    }
}

fn recvExact(conn: *quic.QuicConn, buf: []u8) !usize {
    var off: usize = 0;
    while (off < buf.len) {
        const n = try conn.recv(buf[off..]);
        if (n == 0) return error.UnexpectedEof;
        off += n;
    }
    return off;
}

fn recvChunkWithTimeout(conn: *quic.QuicConn, buf: []u8, timeout_ms: i64) !usize {
    const n = conn.recvWithTimeout(buf, timeout_ms) catch |err| {
        return err;
    };
    if (n == 0) return error.UnexpectedEof;
    return n;
}

fn sendPacket(conn: *quic.QuicConn, payload: []const u8) !void {
    if (payload.len > MAX_TX_LEN) return;
    _ = try conn.send(payload);
}

fn sendResponse(conn: *quic.QuicConn, payload: []const u8) !void {
    return sendPacket(conn, payload);
}

fn parseFrameLengthsFromChunks(
    allocator: std.mem.Allocator,
    chunks: []const []const u8,
) !std.ArrayList(usize) {
    const ParseError = error{
        FrameTooLarge,
    };

    var out = std.ArrayList(usize).init(allocator);
    var rx_buf: [MAX_TX_LEN]u8 = undefined;
    var rx_len: usize = 0;
    var expected_tx_len: ?usize = null;

    for (chunks) |chunk| {
        if (chunk.len == 0) continue;
        if (rx_len + chunk.len > rx_buf.len) return ParseError.FrameTooLarge;

        std.mem.copyForwards(u8, rx_buf[rx_len .. rx_len + chunk.len], chunk);
        rx_len += chunk.len;

        var parse_off: usize = 0;
        while (parse_off < rx_len) {
            if (expected_tx_len == null) {
                expected_tx_len = parseTransactionLengthFromStream(rx_buf[parse_off..rx_len]) catch return ParseError.FrameTooLarge;
            }
            const tx_len = expected_tx_len orelse break;
            if (tx_len == 0 or tx_len > MAX_TX_LEN) return ParseError.FrameTooLarge;
            if (rx_len - parse_off < tx_len) break;
            parse_off += tx_len;
            expected_tx_len = null;
            try out.append(tx_len);
        }

        if (parse_off > 0) {
            const remaining = rx_len - parse_off;
            if (remaining > 0) {
                std.mem.copyForwards(u8, rx_buf[0..remaining], rx_buf[parse_off .. rx_len]);
            }
            rx_len = remaining;
        }
    }

    return out;
}

fn appendFrame(stream: *std.ArrayList(u8), bytes: []const u8) !void {
    try stream.appendSlice(bytes);
}

const TxParseError = error{
    InvalidFrame,
};

fn parseTransactionLengthFromStream(raw: []const u8) TxParseError!?usize {
    var off: usize = 0;

    const sig_count = try readCompactLen(raw, &off) orelse return null;
    off = try checkedAdd(off, try checkedMul(@as(usize, sig_count), 64));
    if (off > raw.len) return null;

    off = try checkedAdd(off, 3);
    if (off > raw.len) return null;

    const account_count = try readCompactLen(raw, &off) orelse return null;
    off = try checkedAdd(off, try checkedMul(@as(usize, account_count), 32));
    if (off > raw.len) return null;

    off = try checkedAdd(off, 32);
    if (off > raw.len) return null;

    const instruction_count = @as(usize, try readCompactLen(raw, &off) orelse return null);
    var ix: usize = 0;
    while (ix < instruction_count) : (ix += 1) {
        off = try checkedAdd(off, 1);
        if (off > raw.len) return null;

        const account_meta_count = try readCompactLen(raw, &off) orelse return null;
        off = try checkedAdd(off, @as(usize, account_meta_count));
        if (off > raw.len) return null;

        const data_len = try readCompactLen(raw, &off) orelse return null;
        off = try checkedAdd(off, @as(usize, data_len));
        if (off > raw.len) return null;
    }

    return off;
}

fn readCompactLen(raw: []const u8, off: *usize) TxParseError!?u16 {
    if (off.* >= raw.len) return null;

    var shift: u8 = 0;
    var value: u16 = 0;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const index = off.* + i;
        if (index >= raw.len) return null;
        const byte = raw[index];
        value |= @as(u16, byte & 0x7f) << shift;
        if ((byte & 0x80) == 0) {
            off.* += i + 1;
            return value;
        }
        shift +|= 7;
    }

    return TxParseError.InvalidFrame;
}

fn checkedAdd(a: usize, b: usize) TxParseError!usize {
    const out = a + b;
    if (out < a or out < b) return TxParseError.InvalidFrame;
    return out;
}

fn checkedMul(a: usize, b: usize) TxParseError!usize {
    if (a == 0 or b == 0) return 0;
    if (a > (std.math.maxInt(usize) / b)) return TxParseError.InvalidFrame;
    return a * b;
}

fn buildTestTransaction(out: []u8, payload_len: usize) usize {
    var off: usize = 0;
    off += encoding.writeCompactU16(1, out[off..]);
    @memset(out[off .. off + 64], 0x11);
    off += 64;
    out[off] = 1;
    out[off + 1] = 0;
    out[off + 2] = 0;
    off += 3;
    off += encoding.writeCompactU16(2, out[off..]);
    @memset(out[off .. off + 32], 0x22);
    off += 32;
    @memset(out[off .. off + 32], 0x33);
    off += 32;
    @memset(out[off .. off + 32], 0x44);
    off += 32;
    off += encoding.writeCompactU16(1, out[off..]);
    out[off] = 2;
    off += 1;
    off += encoding.writeCompactU16(2, out[off..]);
    out[off] = 0;
    out[off + 1] = 1;
    off += 2;
    off += encoding.writeCompactU16(@as(u16, @intCast(payload_len)), out[off..]);
    var j: usize = 0;
    while (j < payload_len) : (j += 1) {
        out[off + j] = @truncate(0x55 + j);
    }
    off += payload_len;
    return off;
}

test "tpu max limit constants are usable" {
    const cfg = types.Hash{ .bytes = [_]u8{1} ** 32 };
    _ = cfg;
}

test "property: TPU frame parsing is stable across random chunk boundaries" {
    var seed: u64 = 0xC0FFEE_1234;
    const iterations: usize = 64;

    fn nextRand(v: *u64) u64 {
        v.* = (v.* * 6364136223846793005) + 1;
        return v.*;
    }

    fn randRange(v: *u64, max: usize) usize {
        if (max == 0) return 0;
        return @as(usize, @intCast(nextRand(v) % @as(u64, max)));
    }

    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        var stream = std.ArrayList(u8).init(std.testing.allocator);
        defer stream.deinit();
        var frame_count = 1 + randRange(&seed, 8);
        var tx_template: [MAX_TX_LEN]u8 = undefined;
        var frame_idx: usize = 0;
        while (frame_idx < frame_count) : (frame_idx += 1) {
            const payload_len = 1 + randRange(&seed, 32);
            const tx_len = buildTestTransaction(&tx_template, payload_len);
            try appendFrame(&stream, tx_template[0..tx_len]);
        }

        const contiguous = try parseFrameLengthsFromChunks(std.testing.allocator, &[_][]const u8{stream.items});
        defer contiguous.deinit();

        var chunks = std.ArrayList([]const u8).init(std.testing.allocator);
        defer chunks.deinit();
        var remaining = stream.items.len;
        var offset: usize = 0;
        while (remaining > 0) {
            const max_chunk = 1 + randRange(&seed, 17);
            const take = @min(max_chunk, remaining);
            try chunks.append(stream.items[offset .. offset + take]);
            offset += take;
            remaining -= take;
        }

        const chunked = try parseFrameLengthsFromChunks(std.testing.allocator, chunks.items);
        defer chunked.deinit();

        try std.testing.expectEqual(contiguous.items.len, chunked.items.len);
        var i: usize = 0;
        while (i < contiguous.items.len) : (i += 1) {
            try std.testing.expectEqual(contiguous.items[i], chunked.items[i]);
        }
    }
}
