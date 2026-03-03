const std = @import("std");

const SERVICE_STREAM_ID: u64 = 0;
const DEFAULT_STREAM_ID_STEP: u64 = 2;
const STREAM_ID_PARITY_MASK: u64 = 0x01;
const DEFAULT_REMOTE_STREAM_ID_START: u64 = if ((SERVICE_STREAM_ID & STREAM_ID_PARITY_MASK) == 0) 1 else 0;
const DEFAULT_LOCAL_MAX_DATA: u64 = 1 << 16;
const DEFAULT_LOCAL_MAX_STREAM_DATA: u64 = 1 << 14;
const DEFAULT_PEER_MAX_DATA: u64 = 1 << 16;
const DEFAULT_PEER_MAX_STREAM_DATA: u64 = 1 << 14;
const DEFAULT_PATH_MTU: usize = 1200;
const DEFAULT_SMTT: usize = 1200;
const DEFAULT_INITIAL_CWND: usize = DEFAULT_SMTT * 2;
const PTO_BASE_MS: i64 = 250;
const PTO_MAX_BACKOFF: i64 = 4000;
const ACK_COALESCE_WINDOW_MS: i64 = 10;
const SUPPORTED_QUIC_VERSION: u32 = 1;
const TLS_PLACEHOLDER_MAGIC_CLIENT: []const u8 = "ZIGTLS-CLIENT-HELLO";
const TLS_PLACEHOLDER_MAGIC_SERVER: []const u8 = "ZIGTLS-SERVER-HELLO";
const TLS_PLACEHOLDER_MAGIC_FINISH: []const u8 = "ZIGTLS-FINISHED";

const FRAME_PADDING: u8 = 0x00;
const FRAME_PING: u8 = 0x01;
const FRAME_ACK: u8 = 0x02;
const FRAME_ACK_ECN: u8 = 0x03;
const FRAME_CRYPTO: u8 = 0x06;
const FRAME_STREAM_MASK: u8 = 0xF8;
const FRAME_STREAM: u8 = 0x08;
const FRAME_MAX_DATA: u8 = 0x10;
const FRAME_MAX_STREAM_DATA: u8 = 0x11;
const FRAME_CONNECTION_CLOSE: u8 = 0x1c;
const FRAME_CONNECTION_CLOSE_APP: u8 = 0x1d;
const FRAME_HANDSHAKE_DONE: u8 = 0x1e;

const QUIC_LONG_HEADER: u8 = 0x80;
const QUIC_LONG_FIXED_BIT: u8 = 0x40;
const QUIC_SHORT_FIXED_BIT: u8 = 0x40;
const QUIC_SHORT_RESERVED_BITS: u8 = 0x30;
const QUIC_LONG_RESERVED_MASK: u8 = 0x0c;
const QUIC_SHORT_PACKET_NUMBER_MASK: u8 = 0x03;
const QUIC_PACKET_NUMBER_BYTES_4: usize = 4;
const DEFAULT_CONNECTION_ID_LEN: u8 = 8;

const FrameType = enum(u8) {
    padding = FRAME_PADDING,
    ping = FRAME_PING,
    ack = FRAME_ACK,
    ack_ecn = FRAME_ACK_ECN,
    crypto = FRAME_CRYPTO,
    max_data = FRAME_MAX_DATA,
    max_stream_data = FRAME_MAX_STREAM_DATA,
    stream = FRAME_STREAM,
    connection_close = FRAME_CONNECTION_CLOSE,
    connection_close_app = FRAME_CONNECTION_CLOSE_APP,
    handshake_done = FRAME_HANDSHAKE_DONE,
};

pub const ConnectionId = [8]u8;

pub const PacketType = enum(u8) {
    initial = 0x00,
    zero_rtt = 0x01,
    handshake = 0x02,
    retry = 0x03,
    one_rtt = 0xff,
};

pub const PacketHeader = struct {
    is_long: bool,
    packet_type: PacketType,
    version: u32,
    dcid: ConnectionId,
    dcid_len: u8,
    scid: ConnectionId,
    scid_len: u8,
    packet_number: u64,
    packet_number_len: u8,
    payload_offset: usize,
};

const VarInt = struct {
    value: u64,
    bytes: usize,
};

const PacketRange = struct {
    start: u64,
    end: u64,
};

const StreamState = enum(u8) {
    idle,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

const QuicConnState = enum(u8) {
    pre_init,
    handshake,
    connected,
    draining,
    closed,
};

const QuicTlsMode = enum(u8) {
    disabled,
    placeholder,
};

const QuicTlsState = enum(u8) {
    waiting_for_client_hello,
    sent_server_hello,
    established,
    failed,
};

const QuicStream = struct {
    id: u64,
    state: StreamState,
    send_offset: u64,
    recv_offset: u64,
    send_max_data: u64,
    recv_max_data: u64,
    recv_buffer: std.ArrayListUnmanaged(u8),
    fin_send: bool,
    fin_recv: bool,

    pub fn init(id: u64, send_max_data: u64, recv_max_data: u64) QuicStream {
        return QuicStream{
            .id = id,
            .state = .open,
            .send_offset = 0,
            .recv_offset = 0,
            .send_max_data = send_max_data,
            .recv_max_data = recv_max_data,
            .recv_buffer = .empty,
            .fin_send = false,
            .fin_recv = false,
        };
    }

    pub fn canSendBytes(self: *const QuicStream, n: u64) bool {
        return self.send_offset + n <= self.send_max_data;
    }

    pub fn canReceiveBytes(self: *const QuicStream, n: u64) bool {
        return self.recv_offset + n <= self.recv_max_data;
    }

    pub fn markSent(self: *QuicStream, n: u64) void {
        self.send_offset += n;
    }

    pub fn markReceived(self: *QuicStream, n: u64) void {
        self.recv_offset += n;
    }

    pub fn deinit(self: *QuicStream, allocator: std.mem.Allocator) void {
        self.recv_buffer.deinit(allocator);
    }
};

const SentPacket = struct {
    packet_number: u64,
    wire: []u8,
    sent_at_ms: i64,
    size: usize,
    payload_size: usize,
    retransmit_count: u8,

    pub fn init(packet_number: u64, wire: []u8, sent_at_ms: i64, payload_size: usize) SentPacket {
        return SentPacket{
            .packet_number = packet_number,
            .wire = wire,
            .sent_at_ms = sent_at_ms,
            .size = wire.len,
            .payload_size = payload_size,
            .retransmit_count = 0,
        };
    }

    pub fn deinit(self: *SentPacket, allocator: std.mem.Allocator) void {
        allocator.free(self.wire);
    }
};

pub const QuicConn = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    server: *QuicServer,
    peer_addr: std.posix.sockaddr,
    peer_addr_len: std.posix.socklen_t,

    dcid: ConnectionId,
    dcid_len: u8,
    peer_cid: ConnectionId,
    peer_cid_len: u8,
    local_cid: ConnectionId,
    local_cid_len: u8,

    send_packet_number: u64,
    next_expected_packet_number: u64,
    state: QuicConnState,
    tls_mode: QuicTlsMode,
    tls_state: QuicTlsState,
    tls_compat: bool,
    version: u32,
    crypto_recv_offset: u64,
    crypto_send_offset: u64,
    crypto_rx: std.ArrayListUnmanaged(u8),
    crypto_tx: std.ArrayListUnmanaged(u8),

    state_mu: std.Thread.Mutex,
    recv_cond: std.Thread.Condition,

    streams: std.AutoHashMap(u64, *QuicStream),
    next_local_stream_id: u64,
    next_remote_stream_id: u64,

    local_max_data: u64,
    local_data_buffered: u64,
    peer_max_data: u64,
    peer_data_buffered: u64,
    path_mtu: usize,

    sent_packets: std.AutoHashMap(u64, *SentPacket),
    sent_order: std.ArrayListUnmanaged(u64),
    bytes_in_flight: usize,
    congestion_window: usize,
    ssthresh: usize,
    smoothed_rtt_ms: i64,
    rtt_var_ms: i64,
    min_rtt_ms: i64,
    has_rtt_sample: bool,
    pto_count: u8,
    recovery_mode: bool,
    last_ack_ms: i64,
    largest_acked: u64,
    received_ranges: std.ArrayListUnmanaged(PacketRange),
    peer_ack_pending: bool,
    peer_ack_first_send_ms: i64,

    closed: bool,

    pub fn init(
        allocator: std.mem.Allocator,
        socket: std.posix.socket_t,
        server: *QuicServer,
        peer_addr: std.posix.sockaddr,
        peer_addr_len: std.posix.socklen_t,
        peer_cid: ConnectionId,
        peer_cid_len: u8,
        tls_mode: QuicTlsMode,
    ) !QuicConn {
        var local_cid: ConnectionId = undefined;
        std.crypto.random.bytes(&local_cid);

        var self = QuicConn{
            .allocator = allocator,
            .socket = socket,
            .server = server,
            .peer_addr = peer_addr,
            .peer_addr_len = peer_addr_len,
            .dcid = peer_cid,
            .dcid_len = if (peer_cid_len == 0) 8 else peer_cid_len,
            .peer_cid = peer_cid,
            .peer_cid_len = if (peer_cid_len == 0) 8 else peer_cid_len,
            .local_cid = local_cid,
            .local_cid_len = 8,
            .version = SUPPORTED_QUIC_VERSION,
            .send_packet_number = 0,
            .next_expected_packet_number = 0,
            .state = .pre_init,
            .tls_mode = tls_mode,
            .tls_state = .waiting_for_client_hello,
            .tls_compat = true,
            .crypto_recv_offset = 0,
            .crypto_send_offset = 0,
            .crypto_rx = .{},
            .crypto_tx = .{},
            .state_mu = .{},
            .recv_cond = .{},
            .streams = std.AutoHashMap(u64, *QuicStream).init(allocator),
            .next_local_stream_id = if (SERVICE_STREAM_ID == 0) DEFAULT_STREAM_ID_STEP else SERVICE_STREAM_ID + DEFAULT_STREAM_ID_STEP,
            .next_remote_stream_id = DEFAULT_REMOTE_STREAM_ID_START,
            .local_max_data = DEFAULT_LOCAL_MAX_DATA,
            .local_data_buffered = 0,
            .peer_max_data = DEFAULT_PEER_MAX_DATA,
            .peer_data_buffered = 0,
            .path_mtu = DEFAULT_PATH_MTU,
            .sent_packets = std.AutoHashMap(u64, *SentPacket).init(allocator),
            .sent_order = .{},
            .bytes_in_flight = 0,
            .congestion_window = DEFAULT_INITIAL_CWND,
            .ssthresh = std.math.maxInt(usize),
            .smoothed_rtt_ms = 0,
            .rtt_var_ms = 0,
            .min_rtt_ms = std.math.maxInt(i64),
            .has_rtt_sample = false,
            .pto_count = 0,
            .recovery_mode = false,
            .last_ack_ms = 0,
            .largest_acked = 0,
            .received_ranges = .{},
            .peer_ack_pending = false,
            .peer_ack_first_send_ms = 0,
            .closed = false,
        };

        const service_stream = try allocator.create(QuicStream);
        service_stream.* = QuicStream.init(
            SERVICE_STREAM_ID,
            DEFAULT_PEER_MAX_STREAM_DATA,
            DEFAULT_LOCAL_MAX_STREAM_DATA,
        );
        try self.streams.put(SERVICE_STREAM_ID, service_stream);
        return self;
    }

    pub fn deinit(self: *QuicConn) void {
        self.state_mu.lock();
        self.closed = true;
        self.state = .closed;
        self.crypto_rx.deinit(self.allocator);
        self.crypto_tx.deinit(self.allocator);
        var it = self.streams.valueIterator();
        while (it.next()) |entry| {
            const stream = entry.*;
            stream.deinit(self.allocator);
            self.allocator.destroy(stream);
        }
        self.streams.clearAndFree();
        var sent_it = self.sent_packets.valueIterator();
        while (sent_it.next()) |entry| {
            const packet = entry.*;
            packet.deinit(self.allocator);
            self.allocator.destroy(packet);
        }
        self.sent_packets.clearAndFree();
        self.sent_order.deinit(self.allocator);
        self.received_ranges.deinit(self.allocator);
        self.state_mu.unlock();
        self.recv_cond.broadcast();
    }

    pub fn openStream(self: *QuicConn) !u64 {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        if (self.state == .closed or self.closed) return error.ConnectionClosed;
        return self.allocateLocalStreamLocked();
    }

    fn allocateLocalStreamLocked(self: *QuicConn) !u64 {
        const stream_id = self.next_local_stream_id;
        if ((stream_id & STREAM_ID_PARITY_MASK) != (SERVICE_STREAM_ID & STREAM_ID_PARITY_MASK)) {
            return error.InvalidStream;
        }
        self.next_local_stream_id += DEFAULT_STREAM_ID_STEP;
        _ = try self.createStreamIfMissing(stream_id);
        return stream_id;
    }

    fn ensureRemoteStreamState(self: *QuicConn, stream_id: u64) !*QuicStream {
        if (stream_id == SERVICE_STREAM_ID) return self.createStreamIfMissing(SERVICE_STREAM_ID);

        if (self.streams.get(stream_id)) |stream| {
            if ((stream_id & STREAM_ID_PARITY_MASK) != (self.next_remote_stream_id & STREAM_ID_PARITY_MASK)) {
                return error.InvalidStream;
            }
            if (stream.state == .closed) return error.InvalidStream;
            return stream;
        }

        if ((stream_id & STREAM_ID_PARITY_MASK) != (self.next_remote_stream_id & STREAM_ID_PARITY_MASK)) return error.InvalidStream;
        if (stream_id != self.next_remote_stream_id) return error.InvalidStream;

        const stream = try self.createStreamIfMissing(stream_id);
        self.next_remote_stream_id += DEFAULT_STREAM_ID_STEP;
        return stream;
    }

    fn ensureLocalStreamState(self: *QuicConn, stream_id: u64) !*QuicStream {
        if (stream_id == SERVICE_STREAM_ID) return self.createStreamIfMissing(SERVICE_STREAM_ID);

        if ((stream_id & STREAM_ID_PARITY_MASK) != (self.next_local_stream_id & STREAM_ID_PARITY_MASK)) {
            return error.InvalidStream;
        }

        if (self.streams.get(stream_id)) |stream| {
            if ((stream_id & STREAM_ID_PARITY_MASK) != (self.next_local_stream_id & STREAM_ID_PARITY_MASK)) {
                return error.InvalidStream;
            }
            if (stream.state == .closed) return error.InvalidStream;
            return stream;
        }

        if (stream_id != self.next_local_stream_id) return error.InvalidStream;

        const stream = try self.createStreamIfMissing(stream_id);
        self.next_local_stream_id += DEFAULT_STREAM_ID_STEP;
        return stream;
    }

    fn createStreamIfMissing(self: *QuicConn, stream_id: u64) !*QuicStream {
        if (self.streams.get(stream_id)) |stream| return stream;

        const stream = try self.allocator.create(QuicStream);
        stream.* = QuicStream.init(stream_id, DEFAULT_PEER_MAX_STREAM_DATA, DEFAULT_LOCAL_MAX_STREAM_DATA);
        try self.streams.put(stream_id, stream);
        return stream;
    }

    fn rttEstimateMs(self: *const QuicConn) i64 {
        if (!self.has_rtt_sample) return PTO_BASE_MS;
        if (self.smoothed_rtt_ms <= 0) return PTO_BASE_MS;
        return @max(PTO_BASE_MS, self.smoothed_rtt_ms + 4 * self.rtt_var_ms);
    }

    fn ptoDelayMs(self: *const QuicConn) i64 {
        const backoff = @as(i64, @intCast(1 << @as(u6, self.pto_count)));
        const delay = self.rttEstimateMs() * backoff;
        return @min(delay, PTO_MAX_BACKOFF);
    }

    fn maxSendPayload(self: *const QuicConn) usize {
        const estimated_overhead = 1 + 8 + 4 + 1 + 10 + 10 + 10;
        if (self.path_mtu <= estimated_overhead) return 1;
        return self.path_mtu - estimated_overhead;
    }

    fn varIntLen(v: u64) usize {
        return switch (v) {
            0...(0x3f) => 1,
            0x40...(0x3fff) => 2,
            0x4000...(0x3fffffff) => 4,
            else => 8,
        };
    }

    fn receivedPacketRangeIndex(self: *const QuicConn, packet_number: u64) ?usize {
        for (self.received_ranges.items, 0..) |r, idx| {
            if (packet_number < r.start) return idx;
            if (packet_number <= r.end) return null;
        }
        return self.received_ranges.items.len;
    }

    fn registerReceivedPacket(self: *QuicConn, packet_number: u64) void {
        const insert_idx = self.receivedPacketRangeIndex(packet_number) orelse {
            self.peer_ack_pending = true;
            return;
        };

        const can_prepend = if (insert_idx > 0) blk: {
            const prev_end = self.received_ranges.items[insert_idx - 1].end;
            break :blk (prev_end == std.math.maxInt(u64) or packet_number <= prev_end + 1);
        } else
            false;
        const can_append = if (insert_idx < self.received_ranges.items.len)
            if (packet_number == std.math.maxInt(u64))
                false
            else
                packet_number + 1 >= self.received_ranges.items[insert_idx].start
        else
            false;
        if (can_prepend and can_append) {
            const prev = insert_idx - 1;
            const next = insert_idx;
            self.received_ranges.items[prev].end = self.received_ranges.items[next].end;
            _ = self.received_ranges.swapRemove(next);
        } else if (can_prepend) {
            self.received_ranges.items[insert_idx - 1].end = packet_number;
        } else if (can_append) {
            self.received_ranges.items[insert_idx].start = packet_number;
        } else {
            self.received_ranges.insert(self.allocator, insert_idx, .{
                .start = packet_number,
                .end = packet_number,
            }) catch |err| {
                _ = err;
                return;
            };
        }
        self.peer_ack_pending = true;
        if (self.peer_ack_first_send_ms == 0) self.peer_ack_first_send_ms = std.time.milliTimestamp();
    }

    fn startsWith(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        return std.mem.eql(u8, haystack[0..needle.len], needle);
    }

    fn dropPrefix(list: *std.ArrayListUnmanaged(u8), len: usize) void {
        if (len == 0 or list.items.len <= len) {
            list.clearRetainingCapacity();
            return;
        }

        const remaining = list.items[len..];
        std.mem.copyForwards(u8, list.items[0..remaining.len], remaining);
        list.shrinkRetainingCapacity(list.items.len - len);
    }

    fn isHandshakeActive(self: *const QuicConn) bool {
        return self.tls_mode == .placeholder and self.tls_state != .established;
    }

    fn markTlsEstablished(self: *QuicConn) void {
        if (self.tls_mode == .disabled or self.tls_state == .established) return;
        self.tls_state = .established;
        self.state = .connected;
        self.tls_compat = true;
        self.recv_cond.signal();
    }

    fn queueCryptoFrame(self: *QuicConn, payload: []const u8) !void {
        if (payload.len == 0) return;
        if (self.state == .closed or self.state == .draining) return;

        const frame_overhead = 1 + 8 + 1 + 1;
        const max_payload = if (self.maxSendPayload() > frame_overhead)
            self.maxSendPayload() - frame_overhead
        else
            0;
        if (max_payload == 0) return;

        var tx_payload = try self.allocator.alloc(u8, self.maxSendPayload());
        defer self.allocator.free(tx_payload);

        var offset = self.crypto_send_offset;
        var idx: usize = 0;
        while (idx < payload.len) {
            const remaining = payload.len - idx;
            const chunk_len = @min(remaining, max_payload);
            const chunk = payload[idx .. idx + chunk_len];

            const frame_len = try self.makeCryptoFrame(
                tx_payload,
                offset,
                chunk,
            );
            _ = try self.emitPacketWithPayload(tx_payload[0..frame_len], chunk.len);
            self.crypto_send_offset += @as(u64, chunk_len);
            offset += @as(u64, chunk_len);
            idx += chunk_len;
        }
    }

    fn onCryptoFrame(self: *QuicConn, frame_offset: u64, payload: []const u8) !void {
        if (self.tls_mode == .disabled) return;
        if (frame_offset != self.crypto_recv_offset) return;
        try self.crypto_rx.appendSlice(self.allocator, payload);
        self.crypto_recv_offset += @as(u64, payload.len);

        if (self.tls_state == .waiting_for_client_hello) {
            if (startsWith(self.crypto_rx.items, TLS_PLACEHOLDER_MAGIC_CLIENT)) {
                dropPrefix(&self.crypto_rx, TLS_PLACEHOLDER_MAGIC_CLIENT.len);
                self.tls_state = .sent_server_hello;
                self.tls_compat = false;
                try self.crypto_tx.appendSlice(self.allocator, TLS_PLACEHOLDER_MAGIC_SERVER);
                try self.queueCryptoFrame(TLS_PLACEHOLDER_MAGIC_SERVER);
            }
        }

        if (self.tls_state == .sent_server_hello and startsWith(self.crypto_rx.items, TLS_PLACEHOLDER_MAGIC_FINISH)) {
            dropPrefix(&self.crypto_rx, TLS_PLACEHOLDER_MAGIC_FINISH.len);
            self.markTlsEstablished();
        }
    }

    fn buildAckFrame(self: *QuicConn, out: []u8) !usize {
        if (!self.peer_ack_pending or self.received_ranges.items.len == 0) return 0;
        const now_ms = std.time.milliTimestamp();
        if (now_ms < 0) return 0;
        if (self.peer_ack_first_send_ms > 0 and now_ms - self.peer_ack_first_send_ms < ACK_COALESCE_WINDOW_MS) {
            return 0;
        }

        const count = self.received_ranges.items.len;
        const latest = self.received_ranges.items[count - 1];
        const largest = latest.end;
        const first_range = latest.end - latest.start;

        var off: usize = 0;
        out[off] = FRAME_ACK;
        off += 1;
        off += encodeVarInt(out[off..], largest) catch return error.FrameTooLarge;
        off += encodeVarInt(out[off..], 0) catch return error.FrameTooLarge;
        off += encodeVarInt(out[off..], if (count > 1) count - 1 else 0) catch return error.FrameTooLarge;
        off += encodeVarInt(out[off..], first_range) catch return error.FrameTooLarge;

        if (count > 1) {
            var i: usize = count - 1;
            while (true) {
                const current = self.received_ranges.items[i];
                if (i == 0) break;
                const prev = self.received_ranges.items[i - 1];
                off += encodeVarInt(out[off..], current.start - prev.end - 1) catch return error.FrameTooLarge;
                off += encodeVarInt(out[off..], prev.end - prev.start) catch return error.FrameTooLarge;
                if (i == 1) break;
                i -= 1;
            }
        }
        return off;
    }

    fn markAckFrameSent(self: *QuicConn) void {
        self.peer_ack_pending = false;
        self.peer_ack_first_send_ms = 0;
    }

    fn maybeRetransmit(self: *QuicConn) !void {
        if (self.state == .closed or self.state == .draining) return;
        if (self.sent_order.items.len == 0) return;

        const now_ms = std.time.milliTimestamp();
        const pto_ms = self.ptoDelayMs();
        if (now_ms < 0) return;

        var due_idx: usize = 0;
        while (due_idx < self.sent_order.items.len) {
            const pn = self.sent_order.items[due_idx];
            const rec = self.sent_packets.get(pn) orelse {
                due_idx += 1;
                continue;
            };
            const age = now_ms - rec.sent_at_ms;
            if (age < pto_ms) break;

            if (rec.retransmit_count >= 2) {
                // Conservative: stop retransmitting the oldest packet endlessly.
                self.pto_count = @min(self.pto_count + 1, 6);
                break;
            }

            self.congestionLossAdjustment();
            _ = std.posix.sendto(
                self.socket,
                rec.wire,
                0,
                &self.peer_addr,
                self.peer_addr_len,
            ) catch {};
            rec.sent_at_ms = now_ms;
            rec.retransmit_count +%= 1;
            self.pto_count +%= 1;
            return;
        }
    }

    fn onAckPacket(self: *QuicConn, packet_number: u64) void {
        const rec = self.sent_packets.get(packet_number) orelse return;
        const now_ms = std.time.milliTimestamp();
        if (now_ms >= 0) {
            self.onRttSample(@as(usize, @intCast(now_ms - rec.sent_at_ms)));
            self.last_ack_ms = now_ms;
            self.pto_count = 0;
            self.recovery_mode = false;
        }

        if (self.bytes_in_flight >= rec.size) {
            self.bytes_in_flight -= rec.size;
        } else {
            self.bytes_in_flight = 0;
        }
        if (self.peer_data_buffered >= rec.payload_size) {
            self.peer_data_buffered -= rec.payload_size;
        } else {
            self.peer_data_buffered = 0;
        }

        if (self.congestion_window < self.ssthresh) {
            self.congestion_window += rec.size;
        } else if (rec.size > 0) {
            const inc = @max(@as(usize, 1), (DEFAULT_SMTT * DEFAULT_SMTT) / self.congestion_window);
            self.congestion_window += inc;
        }

        self.largest_acked = @max(self.largest_acked, rec.packet_number);

        rec.deinit(self.allocator);
        self.allocator.destroy(rec);
        _ = self.sent_packets.remove(packet_number);
        if (self.sent_order.len > 0) {
            var remove_i: usize = 0;
            while (remove_i < self.sent_order.len) : (remove_i += 1) {
                if (self.sent_order.items[remove_i] == packet_number) {
                    _ = self.sent_order.swapRemove(remove_i);
                    break;
                }
            }
        }
    }

    fn onRttSample(self: *QuicConn, rtt_sample_ms: usize) void {
        if (rtt_sample_ms == 0) return;
        const sample = @as(i64, @intCast(rtt_sample_ms));
        if (!self.has_rtt_sample) {
            self.has_rtt_sample = true;
            self.smoothed_rtt_ms = sample;
            self.rtt_var_ms = @max(sample / 2, 1);
            self.min_rtt_ms = sample;
            return;
        }

        self.min_rtt_ms = @min(self.min_rtt_ms, sample);
        const err = if (sample > self.smoothed_rtt_ms)
            sample - self.smoothed_rtt_ms
        else
            self.smoothed_rtt_ms - sample;
        self.rtt_var_ms = (3 * self.rtt_var_ms + err) / 4;
        self.smoothed_rtt_ms = (7 * self.smoothed_rtt_ms + sample) / 8;
    }

    fn congestionLossAdjustment(self: *QuicConn) void {
        if (self.recovery_mode) return;
        self.recovery_mode = true;
        const new_ssthresh = @max(
            DEFAULT_SMTT * 2,
            self.congestion_window / 2,
        );
        self.ssthresh = new_ssthresh;
        self.congestion_window = new_ssthresh;
        self.pto_count = 1;
    }

    pub fn recv(self: *QuicConn, out: []u8) !usize {
        while (true) {
            self.state_mu.lock();
            defer self.state_mu.unlock();

            try self.maybeRetransmit();

            const stream = self.streams.get(SERVICE_STREAM_ID);
            if (stream) |svc| {
                if (svc.recv_buffer.items.len != 0) {
                    const n = @min(out.len, svc.recv_buffer.items.len);
                    if (n == 0) return 0;
                    @memcpy(out[0..n], svc.recv_buffer.items[0..n]);
                    const remaining = svc.recv_buffer.items.len - n;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, svc.recv_buffer.items[0..remaining], svc.recv_buffer.items[n..]);
                    }
                    svc.recv_buffer.shrinkRetainingCapacity(remaining);
                    self.local_data_buffered = if (self.local_data_buffered > n)
                        self.local_data_buffered - n
                    else
                        0;
                    if (svc.state == .half_closed_remote and svc.fin_recv and svc.recv_buffer.items.len == 0) {
                        svc.state = .closed;
                    }
                    return n;
                }
            }

            if (self.state == .closed or self.closed or self.state == .draining) return error.ConnectionClosed;
            self.recv_cond.wait(&self.state_mu);
        }
    }

    pub fn recvWithTimeout(self: *QuicConn, out: []u8, timeout_ms: i64) !usize {
        if (timeout_ms <= 0) return error.Timeout;
        const deadline = std.time.milliTimestamp() + timeout_ms;

        while (true) {
            self.state_mu.lock();

            try self.maybeRetransmit();

            const stream = self.streams.get(SERVICE_STREAM_ID);
            if (stream) |svc| {
                if (svc.recv_buffer.items.len != 0) {
                    const n = @min(out.len, svc.recv_buffer.items.len);
                    if (n == 0) {
                        self.state_mu.unlock();
                        return 0;
                    }

                    @memcpy(out[0..n], svc.recv_buffer.items[0..n]);
                    const remaining = svc.recv_buffer.items.len - n;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, svc.recv_buffer.items[0..remaining], svc.recv_buffer.items[n..]);
                    }
                    svc.recv_buffer.shrinkRetainingCapacity(remaining);
                    self.local_data_buffered = if (self.local_data_buffered > n)
                        self.local_data_buffered - n
                    else
                        0;
                    if (svc.state == .half_closed_remote and svc.fin_recv and svc.recv_buffer.items.len == 0) {
                        svc.state = .closed;
                    }

                    self.state_mu.unlock();
                    return n;
                }
            }

            if (self.state == .closed or self.closed or self.state == .draining) {
                self.state_mu.unlock();
                return error.ConnectionClosed;
            }

            const now_ms = std.time.milliTimestamp();
            const remaining_ms = deadline - now_ms;
            if (remaining_ms <= 0) {
                self.state_mu.unlock();
                return error.Timeout;
            }

            const timeout_ns = @as(u64, @intCast(@max(@as(i64, 1), remaining_ms))) * std.time.ns_per_ms;
            self.recv_cond.timedWait(&self.state_mu, timeout_ns) catch |err| {
                self.state_mu.unlock();
                if (err == error.Timeout) return error.Timeout;
                return err;
            };
            self.state_mu.unlock();
        }
    }

    fn canSend(self: *QuicConn, stream: *QuicStream, n: u64) bool {
        if (!stream.canSendBytes(n)) return false;
        if (self.peer_data_buffered + n > self.peer_max_data) return false;
        const n_usize = @as(usize, @intCast(n));
        if (self.bytes_in_flight + n_usize > self.congestion_window) return false;
        if (self.state == .draining or self.state == .closed) return false;
        return true;
    }

    fn peerAddrMatches(self: *QuicConn, peer_addr: std.posix.sockaddr, peer_len: std.posix.socklen_t) bool {
        const prev_len = @as(usize, self.peer_addr_len);
        const next_len = @as(usize, peer_len);
        if (prev_len != next_len) return false;
        if (prev_len == 0) return true;
        return std.mem.eql(
            u8,
            std.mem.asBytes(&self.peer_addr)[0..prev_len],
            std.mem.asBytes(&peer_addr)[0..next_len],
        );
    }

    fn canAcceptPeerAddr(self: *QuicConn, peer_addr: std.posix.sockaddr, peer_len: std.posix.socklen_t) bool {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        if (self.state == .connected) return self.peerAddrMatches(peer_addr, peer_len);
        return true;
    }

    fn emitPacketWithPayload(
        self: *QuicConn,
        frame_payload: []const u8,
        retransmit_payload: usize,
    ) !usize {
        if (frame_payload.len == 0) return 0;
        const use_long_header = self.state != .connected;
        const packet_type = if (self.state == .pre_init or self.state == .handshake)
            PacketType.handshake
        else
            PacketType.one_rtt;
        const packet_number = self.send_packet_number;
        const now_ms = std.time.milliTimestamp();
        if (now_ms < 0) return 0;

        const cap = @max(self.path_mtu, 64);
        var packet = try self.allocator.alloc(u8, cap);
        errdefer self.allocator.free(packet);
        const off = encodePacketHeader(
            packet,
            use_long_header,
            self.version,
            self.dcid[0..@as(usize, self.dcid_len)],
            self.local_cid[0..@as(usize, self.local_cid_len)],
            packet_number,
            packet_type,
        ) catch return error.FrameTooLarge;
        self.send_packet_number +%= 1;

        if (off + frame_payload.len > packet.len) return error.FrameTooLarge;
        @memcpy(packet[off .. off + frame_payload.len], frame_payload);
        const sent_len = off + frame_payload.len;

        const sent = try std.posix.sendto(
            self.socket,
            packet[0..sent_len],
            0,
            &self.peer_addr,
            self.peer_addr_len,
        );

        if (retransmit_payload > 0) {
            var raw = try self.allocator.alloc(u8, sent_len);
            @memcpy(raw, packet[0..sent_len]);
            const rec = try self.allocator.create(SentPacket);
            rec.* = SentPacket.init(packet_number, raw, now_ms, retransmit_payload);
            try self.sent_packets.put(packet_number, rec);
            try self.sent_order.append(self.allocator, packet_number);
            self.bytes_in_flight += sent_len;
        }
        return sent;
    }

    fn sendQueuedAckLocked(self: *QuicConn) !void {
        if (self.peer_ack_pending) {
            var ack_buf: [256]u8 = undefined;
            const ack_len = self.buildAckFrame(&ack_buf) catch 0;
            if (ack_len > 0) {
                const header_overhead = packetHeaderOverhead(self);
                if (self.path_mtu <= header_overhead) return;
                if (ack_len + header_overhead > self.path_mtu) return;
                _ = try self.emitPacketWithPayload(ack_buf[0..ack_len], 0);
                self.markAckFrameSent();
            }
        }
    }

    fn makeStreamFrame(
        self: *QuicConn,
        out: []u8,
        stream_id: u64,
        stream_offset: u64,
        payload: []const u8,
        use_offset: bool,
    ) !usize {
        var off: usize = 0;
        var frame_type: u8 = 0x0a;
        if (use_offset) frame_type |= 0x04;

        if (off >= out.len) return error.FrameTooLarge;
        out[off] = frame_type;
        off += 1;
        off += encodeVarInt(out[off..], stream_id) catch return error.FrameTooLarge;
        if (use_offset) off += encodeVarInt(out[off..], stream_offset) catch return error.FrameTooLarge;
        off += encodeVarInt(out[off..], @as(u64, payload.len)) catch return error.FrameTooLarge;
        if (off + payload.len > out.len) return error.FrameTooLarge;
        @memcpy(out[off .. off + payload.len], payload);
        off += payload.len;
        return off;
    }

    fn makeCryptoFrame(
        self: *QuicConn,
        out: []u8,
        crypto_offset: u64,
        payload: []const u8,
    ) !usize {
        _ = self;
        var off: usize = 0;
        if (off >= out.len) return error.FrameTooLarge;
        out[off] = FRAME_CRYPTO;
        off += 1;
        off += encodeVarInt(out[off..], crypto_offset) catch return error.FrameTooLarge;
        off += encodeVarInt(out[off..], @as(u64, payload.len)) catch return error.FrameTooLarge;
        if (off + payload.len > out.len) return error.FrameTooLarge;
        @memcpy(out[off .. off + payload.len], payload);
        off += payload.len;
        return off;
    }

    pub fn sendOnStream(self: *QuicConn, stream_id: u64, data: []const u8) !usize {
        if (data.len == 0) return 0;

        self.state_mu.lock();
        defer self.state_mu.unlock();

        try self.maybeRetransmit();
        if (self.state == .closed or self.state == .draining) return error.ConnectionClosed;
        if (self.tls_mode == .placeholder and self.tls_state != .established and stream_id == SERVICE_STREAM_ID) {
            return error.HandshakeInProgress;
        }
        const stream = if (stream_id == SERVICE_STREAM_ID)
            try self.createStreamIfMissing(stream_id)
        else
            try self.ensureLocalStreamState(stream_id);
        if (stream.state == .closed or stream.state == .half_closed_local) return error.StreamClosed;

        if (self.state == .pre_init) {
            self.state = if (self.tls_mode == .disabled) .connected else .handshake;
        }

        var offset: usize = 0;
        var sent_total: usize = 0;
        const max_payload = self.maxSendPayload();
        const ack_headroom = if (self.peer_ack_pending) 64 else 0;
        const chunk_budget = if (max_payload > ack_headroom) max_payload - ack_headroom else max_payload;

        while (offset < data.len) {
            const remaining = data.len - offset;
            const chunk_len = @min(remaining, chunk_budget);
            const chunk = data[offset .. offset + chunk_len];
            const chunk_u64 = @as(u64, chunk_len);
            if (!self.canSend(stream, chunk_u64)) return if (sent_total == 0) error.FlowControl else sent_total;

            const frame_offset = stream.send_offset;
            const sent_chunk = self.sendStreamPacket(stream_id, frame_offset, chunk, frame_offset != 0) catch |err| {
                if (sent_total == 0) return err;
                return sent_total;
            };
            if (sent_chunk > 0) {
                stream.markSent(chunk_u64);
                self.peer_data_buffered += chunk_u64;
                sent_total += sent_chunk;
            }
            offset += chunk_len;
        }
        if (sent_total == 0 and self.peer_ack_pending) {
            try self.sendQueuedAckLocked();
        }

        return sent_total;
    }

    fn sendStreamPacket(
        self: *QuicConn,
        stream_id: u64,
        stream_offset: u64,
        payload: []const u8,
        use_offset: bool,
    ) !usize {
        const payload_cap = @max(self.path_mtu, 64);
        var payload_buf = try self.allocator.alloc(u8, payload_cap);
        defer self.allocator.free(payload_buf);
        var frame_off: usize = 0;
        var stream_frame_len: usize = 0;
        var ack_was_staged = false;

        if (self.peer_ack_pending) {
            var ack_buf: [256]u8 = undefined;
            const ack_len = self.buildAckFrame(&ack_buf) catch 0;
            const header_overhead = 1 + @as(usize, self.local_cid_len) + 4;
            if (self.path_mtu > header_overhead and
                ack_len > 0 and
                frame_off + ack_len <= self.path_mtu - header_overhead)
            {
                @memcpy(payload_buf[frame_off .. frame_off + ack_len], ack_buf[0..ack_len]);
                frame_off += ack_len;
                ack_was_staged = true;
            }
        }

        stream_frame_len = try self.makeStreamFrame(
            payload_buf[frame_off..],
            stream_id,
            stream_offset,
            payload,
            use_offset,
        );
        frame_off += stream_frame_len;

        const payload_for_send = payload_buf[0..frame_off];
        const sent = try self.emitPacketWithPayload(payload_for_send, payload.len);
        if (ack_was_staged) self.markAckFrameSent();
        return sent;
    }

    pub fn send(self: *QuicConn, data: []const u8) !usize {
        return self.sendOnStream(SERVICE_STREAM_ID, data);
    }

    fn applyStreamPayload(self: *QuicConn, stream: *QuicStream, offset: u64, payload: []const u8) !void {
        if (offset != stream.recv_offset) return error.StreamNotInOrder;
        const len = @as(u64, payload.len);
        if (!stream.canReceiveBytes(len)) return error.FlowControl;
        if (self.local_data_buffered + len > self.local_max_data) return error.FlowControl;
        try stream.recv_buffer.appendSlice(self.allocator, payload);
        stream.markReceived(len);
        self.local_data_buffered += len;
    }

    fn onStreamFrame(
        self: *QuicConn,
        stream_id: u64,
        has_offset: bool,
        is_fin: bool,
        frame_offset: u64,
        payload: []const u8,
    ) !void {
        if (self.state == .closed or self.state == .draining) return;

        const stream = try self.ensureRemoteStreamState(stream_id);

        const offset = if (has_offset) frame_offset else stream.recv_offset;
        if (payload.len > 0) {
            self.applyStreamPayload(stream, offset, payload) catch |err| {
                if (err == error.StreamNotInOrder or err == error.FlowControl) return;
                return err;
            };
        }

        if (is_fin and !stream.fin_recv) {
            stream.fin_recv = true;
            switch (stream.state) {
                .idle => stream.state = .half_closed_remote,
                .open => stream.state = .half_closed_remote,
                .half_closed_local => stream.state = .closed,
                else => {},
            }
        }

        if (stream.state == .idle) stream.state = .open;
        if (stream_id == SERVICE_STREAM_ID or stream.recv_buffer.items.len > 0 or is_fin) {
            self.recv_cond.signal();
        }
    }

    fn applyConnectionClose(self: *QuicConn) void {
        self.state = .draining;
        self.closed = true;
    }

    fn applyFrameMaxData(self: *QuicConn, value: u64) void {
        self.peer_max_data = value;
    }

    fn applyFrameMaxStreamData(self: *QuicConn, stream_id: u64, max_data: u64) !void {
        const stream = try self.createStreamIfMissing(stream_id);
        stream.send_max_data = max_data;
    }

    fn ackPacketRanges(
        self: *QuicConn,
        largest: u64,
        first_len: u64,
    ) void {
        if (largest + 1 < first_len + 1) return;
        const start = largest + 1 - (first_len + 1);
        var pn = start;
        while (pn <= largest) : (pn += 1) {
            self.onAckPacket(pn);
            if (pn == std.math.maxInt(u64)) break;
        }
    }

    fn parseAckFrame(self: *QuicConn, payload: []const u8, off: *usize, with_ecn: bool) !void {
        const largest = try decodeVarInt(payload[off.*..]);
        off.* += largest.bytes;
        const ack_delay = try decodeVarInt(payload[off.*..]);
        off.* += ack_delay.bytes;
        _ = ack_delay;
        const range_count = try decodeVarInt(payload[off.*..]);
        off.* += range_count.bytes;

        const first = try decodeVarInt(payload[off.*..]);
        off.* += first.bytes;
        if (first.value > largest.value) return error.InvalidFrame;

        self.ackPacketRanges(largest.value, first.value);
        var max_pn = largest.value;

        var i: u64 = 0;
        while (i < range_count.value) : (i += 1) {
            const gap = try decodeVarInt(payload[off.*..]);
            off.* += gap.bytes;
            const ack_range = try decodeVarInt(payload[off.*..]);
            off.* += ack_range.bytes;
            if (gap.value + 1 > max_pn) return error.InvalidFrame;
            max_pn -= (gap.value + 1);
            if (max_pn + 1 < ack_range.value + 1) return error.InvalidFrame;
            const start = max_pn + 1 - (ack_range.value + 1);
            var pn = start;
            while (pn <= max_pn) : (pn += 1) {
                self.onAckPacket(pn);
                if (pn == std.math.maxInt(u64)) break;
            }
            if (max_pn == 0) break;
            max_pn -= 1;
        }

        if (!with_ecn) return;
        const ecn_ce = try decodeVarInt(payload[off.*..]);
        off.* += ecn_ce.bytes;
        const ecn_nce = try decodeVarInt(payload[off.*..]);
        off.* += ecn_nce.bytes;
        const ecn_m = try decodeVarInt(payload[off.*..]);
        off.* += ecn_m.bytes;
        _ = ecn_ce;
        _ = ecn_nce;
        _ = ecn_m;
    }

    fn parseAndApplyFrames(self: *QuicConn, payload: []const u8) !void {
        var off: usize = 0;
        while (off < payload.len) {
            const frame_type = payload[off];
            off += 1;

            if (frame_type == FRAME_PADDING) continue;

            if ((frame_type & FRAME_STREAM_MASK) == @intFromEnum(FrameType.stream)) {
                const has_offset = (frame_type & 0x04) != 0;
                const has_len = (frame_type & 0x02) != 0;
                const is_fin = (frame_type & 0x01) != 0;

                if (self.tls_mode == .placeholder and self.tls_state != .established) {
                    return error.HandshakeInProgress;
                }

                const stream_id_vi = try decodeVarInt(payload[off..]);
                off += stream_id_vi.bytes;
                const stream_id = stream_id_vi.value;

                var frame_offset: u64 = 0;
                if (has_offset) {
                    const off_vi = try decodeVarInt(payload[off..]);
                    off += off_vi.bytes;
                    frame_offset = off_vi.value;
                }

                var data_len: usize = payload.len - off;
                if (has_len) {
                    const data_len_vi = try decodeVarInt(payload[off..]);
                    off += data_len_vi.bytes;
                    if (data_len_vi.value > std.math.maxInt(usize)) return error.InvalidFrame;
                    data_len = @intCast(data_len_vi.value);
                }

                if (off + data_len > payload.len) return error.InvalidFrame;
                const data = payload[off .. off + data_len];
                off += data_len;

                try self.onStreamFrame(stream_id, has_offset, is_fin, frame_offset, data);
                continue;
            }

            switch (frame_type) {
                @intFromEnum(FrameType.ping) => {},
                @intFromEnum(FrameType.ack) => try self.parseAckFrame(payload, &off, false),
                @intFromEnum(FrameType.ack_ecn) => {
                    try self.parseAckFrame(payload, &off, true);
                },
                @intFromEnum(FrameType.crypto) => {
                    const stream_offset = try decodeVarInt(payload[off..]);
                    off += stream_offset.bytes;
                    const data_len = try decodeVarInt(payload[off..]);
                    off += data_len.bytes;
                    if (data_len.value > std.math.maxInt(usize)) return error.InvalidFrame;
                    const data_len_usize = @intCast(data_len.value);
                    if (off + data_len_usize > payload.len) return error.InvalidFrame;
                    const data = payload[off .. off + data_len_usize];
                    off += data_len_usize;
                    try self.onCryptoFrame(stream_offset.value, data);
                    if (self.tls_state != .established) {
                        self.tls_compat = false;
                    }
                },
                @intFromEnum(FrameType.max_data) => {
                    const max_data = try decodeVarInt(payload[off..]);
                    off += max_data.bytes;
                    self.applyFrameMaxData(max_data.value);
                },
                @intFromEnum(FrameType.max_stream_data) => {
                    const stream_vi = try decodeVarInt(payload[off..]);
                    off += stream_vi.bytes;
                    const max_data = try decodeVarInt(payload[off..]);
                    off += max_data.bytes;
                    try self.applyFrameMaxStreamData(stream_vi.value, max_data.value);
                },
                @intFromEnum(FrameType.connection_close) => {
                    const frame_err = try decodeVarInt(payload[off..]);
                    off += frame_err.bytes;
                    const frame_ty = try decodeVarInt(payload[off..]);
                    off += frame_ty.bytes;
                    const reason_len = try decodeVarInt(payload[off..]);
                    off += reason_len.bytes;
                    if (reason_len.value > std.math.maxInt(usize)) return error.InvalidFrame;
                    const reason_len_usize = @intCast(reason_len.value);
                    _ = frame_err;
                    _ = frame_ty;
                    if (off + reason_len_usize > payload.len) return error.InvalidFrame;
                    off += reason_len_usize;
                    self.applyConnectionClose();
                    return;
                },
                @intFromEnum(FrameType.connection_close_app) => {
                    const frame_err = try decodeVarInt(payload[off..]);
                    off += frame_err.bytes;
                    const reason_len = try decodeVarInt(payload[off..]);
                    off += reason_len.bytes;
                    if (reason_len.value > std.math.maxInt(usize)) return error.InvalidFrame;
                    const reason_len_usize = @intCast(reason_len.value);
                    _ = frame_err;
                    if (off + reason_len_usize > payload.len) return error.InvalidFrame;
                    off += reason_len_usize;
                    self.applyConnectionClose();
                    return;
                },
                @intFromEnum(FrameType.handshake_done) => self.markTlsEstablished(),
                else => return error.UnsupportedFrame,
            }
        }
    }

    fn applyPacket(self: *QuicConn, header: PacketHeader) void {
        switch (header.packet_type) {
            .initial => self.state = if (self.tls_mode == .disabled) .connected else .handshake,
            .zero_rtt => if (self.state == .pre_init) self.state = .handshake,
            .handshake => self.state = if (self.tls_mode == .disabled) .connected else .handshake,
            .one_rtt => if (self.state == .pre_init) self.state = if (self.tls_mode == .disabled) .connected else .handshake else {},
            .retry => self.state = if (self.tls_mode == .disabled) .connected else .handshake,
        }
        if (header.version != 0) self.version = header.version;
    }

    pub fn onPacketPayload(self: *QuicConn, header: PacketHeader, payload: []const u8) !void {
        self.state_mu.lock();
        defer self.state_mu.unlock();
        if (self.state == .closed) return error.ConnectionClosed;
        self.registerReceivedPacket(header.packet_number);
        try self.maybeRetransmit();
        if (self.tls_mode == .disabled and self.tls_state != .established) {
            self.markTlsEstablished();
        }
        if (payload.len == 0) {
            if (self.peer_ack_pending) _ = self.sendQueuedAckLocked() catch {};
            return;
        }
        const result = self.parseAndApplyFrames(payload);
        if (self.peer_ack_pending) _ = self.sendQueuedAckLocked() catch {};
        return result;
    }
};

pub const QuicServer = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    running: std.atomic.Value(bool),
    connections: std.AutoHashMap(ConnectionId, *QuicConn),
    conn_mu: std.Thread.Mutex,
    pending: std.ArrayList(*QuicConn),
    worker: std.Thread,
    tls_mode: QuicTlsMode,

    pub fn init(
        allocator: std.mem.Allocator,
        bind_addr: std.net.Address,
        cert_path: []const u8,
        key_path: []const u8,
    ) !QuicServer {
        const tls_mode: QuicTlsMode = if (cert_path.len > 0 and key_path.len > 0) .placeholder else .disabled;

        const sock = try std.posix.socket(bind_addr.any.family, std.posix.SOCK.DGRAM, 0);
        errdefer std.posix.close(sock);
        try std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );
        const addr = bind_addr.any;
        try std.posix.bind(sock, &addr, bind_addr.getOsSockLen());
        var tv = std.posix.timeval{
            .sec = 0,
            .usec = 100_000,
        };
        try std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        );

        var server = QuicServer{
            .allocator = allocator,
            .socket = sock,
            .running = std.atomic.Value(bool).init(true),
            .connections = std.AutoHashMap(ConnectionId, *QuicConn).init(allocator),
            .conn_mu = .{},
            .pending = std.ArrayList(*QuicConn).init(allocator),
            .worker = undefined,
            .tls_mode = tls_mode,
        };

        server.worker = try std.Thread.spawn(.{}, pumpLoop, .{&server});
        return server;
    }

    pub fn deinit(self: *QuicServer) void {
        self.running.store(false, .release);
        self.worker.join();
        std.posix.close(self.socket);

        self.conn_mu.lock();
        defer self.conn_mu.unlock();
        var it = self.connections.valueIterator();
        while (it.next()) |entry| {
            const conn = entry.*;
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.clearAndFree();
        self.pending.deinit();
    }

    pub fn accept(self: *QuicServer) !*QuicConn {
        while (self.running.load(.acquire)) {
            self.conn_mu.lock();
            if (self.pending.items.len > 0) {
                const conn = self.pending.orderedRemove(0);
                self.conn_mu.unlock();
                return conn;
            }
            self.conn_mu.unlock();
            std.time.sleep(1_000_000);
        }
        return error.ServerStopped;
    }

    fn registerIncoming(
        self: *QuicServer,
        peer_addr: std.posix.sockaddr,
        peer_addr_len: std.posix.socklen_t,
        header: PacketHeader,
    ) !*QuicConn {
        const conn = try self.allocator.create(QuicConn);
        errdefer self.allocator.destroy(conn);

        conn.* = try QuicConn.init(
            self.allocator,
            self.socket,
            self,
            peer_addr,
            peer_addr_len,
            header.dcid,
            header.dcid_len,
            self.tls_mode,
        );
        try self.connections.put(conn.dcid, conn);
        try self.pending.append(conn);
        return conn;
    }

    fn handlePacket(self: *QuicServer, packet: []const u8, peer_addr: std.posix.sockaddr, peer_len: std.posix.socklen_t) void {
        const header = parsePacketHeader(packet) catch return;
        self.conn_mu.lock();
        defer self.conn_mu.unlock();

        var conn: ?*QuicConn = self.connections.get(header.dcid);
        if (conn == null and header.scid_len > 0) {
            var it = self.connections.valueIterator();
            while (it.next()) |entry| {
                const candidate = entry.*;
                const candidate_len = @as(usize, candidate.local_cid_len);
                if (candidate_len == header.scid_len and std.mem.eql(
                    u8,
                    candidate.local_cid[0..candidate_len],
                    header.scid[0..header.scid_len],
                )) {
                    conn = candidate;
                    break;
                }
            }
        }

        if (conn) |known| {
            if (known.state == .closed) return;
            if (!known.canAcceptPeerAddr(peer_addr, peer_len)) {
                known.applyConnectionClose();
                return;
            }
            known.peer_addr = peer_addr;
            known.peer_addr_len = peer_len;
            if (header.packet_number >= known.next_expected_packet_number) {
                known.next_expected_packet_number = header.packet_number + 1;
            }
            known.applyPacket(header);
            known.onPacketPayload(header, packet[header.payload_offset..]) catch {};
            return;
        }

        if (!header.is_long) return;
        if (self.running.load(.acquire) == false) return;
        conn = self.registerIncoming(peer_addr, peer_len, header) catch return;
        if (conn) |fresh| {
            if (fresh.state == .closed) return;
            if (!fresh.canAcceptPeerAddr(peer_addr, peer_len)) {
                fresh.applyConnectionClose();
                return;
            }
            fresh.peer_addr = peer_addr;
            fresh.peer_addr_len = peer_len;
            if (header.packet_number >= fresh.next_expected_packet_number) {
                fresh.next_expected_packet_number = header.packet_number + 1;
            }
            fresh.applyPacket(header);
            fresh.onPacketPayload(header, packet[header.payload_offset..]) catch {};
        }
    }
};

fn pumpLoop(server: *QuicServer) void {
    while (server.running.load(.acquire)) {
        var buf: [64 * 1024]u8 = undefined;
        var src_addr: std.posix.sockaddr align(4) = undefined;
        var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        const n = recvFromPumpSocket(server.socket, &buf, &src_addr, &src_len) catch |err| {
            if (!server.running.load(.acquire)) return;
            if (
                err == error.WouldBlock or
                err == error.TimedOut or
                err == error.Interrupted or
                err == error.BadFileDescriptor
            ) continue;
            _ = err;
            continue;
        };
        if (n == 0) continue;
        server.handlePacket(buf[0..n], src_addr, src_len);
    }
}

const PumpRecvError = error{
    WouldBlock,
    TimedOut,
    Interrupted,
    BadFileDescriptor,
};

fn recvFromPumpSocket(
    fd: std.posix.socket_t,
    buf: []u8,
    src_addr: *std.posix.sockaddr,
    src_len: *std.posix.socklen_t,
) PumpRecvError!usize {
    const rc = std.c.recvfrom(
        fd,
        @ptrCast(buf.ptr),
        buf.len,
        0,
        src_addr,
        src_len,
    );
    if (rc >= 0) return @intCast(rc);

    const err = std.posix.errno(rc);
    switch (err) {
        .SUCCESS => unreachable,
        .AGAIN, .WOULDBLOCK => return error.WouldBlock,
        .INTR => return error.Interrupted,
        .TIMEDOUT => return error.TimedOut,
        .BADF => return error.BadFileDescriptor,
        .CONNREFUSED => return error.BadFileDescriptor,
        .CONNRESET => return error.BadFileDescriptor,
        .CONNABORTED => return error.BadFileDescriptor,
        .NOTCONN => return error.BadFileDescriptor,
        else => return error.BadFileDescriptor,
    }
}

fn parsePacketHeader(data: []const u8) !PacketHeader {
    if (data.len < 1) return error.InvalidPacket;
    const first = data[0];
    if ((first & QUIC_LONG_HEADER) != 0 and (first & QUIC_LONG_FIXED_BIT) == 0) return error.InvalidPacket;

    if ((first & QUIC_LONG_HEADER) != 0) {
        if (data.len < 6) return error.InvalidPacket;
        if ((first & QUIC_LONG_FIXED_BIT) == 0) return error.InvalidPacket;
        if ((first & QUIC_LONG_RESERVED_MASK) != 0) return error.InvalidPacket;

        const packet_type_value = (first >> 4) & 0x03;
        const packet_type = switch (packet_type_value) {
            0x00 => PacketType.initial,
            0x01 => PacketType.zero_rtt,
            0x02 => PacketType.handshake,
            0x03 => PacketType.retry,
        };

        const version = std.mem.readInt(u32, data[1..5], .big);
        var off: usize = 5;

        if (off >= data.len) return error.InvalidPacket;
        const dcid_len = data[off];
        if (dcid_len > @sizeOf(ConnectionId)) return error.InvalidPacket;
        off += 1;
        if (off + dcid_len > data.len) return error.InvalidPacket;
        var dcid = std.mem.zeroes(ConnectionId);
        if (dcid_len > 0) @memcpy(dcid[0..dcid_len], data[off .. off + dcid_len]);
        off += dcid_len;

        if (off >= data.len) return error.InvalidPacket;
        const scid_len = data[off];
        if (scid_len > @sizeOf(ConnectionId)) return error.InvalidPacket;
        off += 1;
        if (off + scid_len > data.len) return error.InvalidPacket;
        var scid = std.mem.zeroes(ConnectionId);
        if (scid_len > 0) @memcpy(scid[0..scid_len], data[off .. off + scid_len]);
        off += scid_len;

        if (packet_type == .initial or packet_type == .retry) {
            const token_len = try decodeVarInt(data[off..]);
            off += token_len.bytes;
            const token_len_usize = if (token_len.value > std.math.maxInt(usize))
                return error.InvalidPacket
            else
                @intCast(token_len.value);
            if (off + token_len_usize > data.len) return error.InvalidPacket;
            off += token_len_usize;
        }

        const pn_len = try packetNumberLenFromField(first & QUIC_SHORT_PACKET_NUMBER_MASK);
        if (off + pn_len > data.len) return error.InvalidPacket;
        const packet_number = readPacketNumber(data[off .. off + pn_len]);
        off += pn_len;

        return PacketHeader{
            .is_long = true,
            .packet_type = packet_type,
            .version = version,
            .dcid = dcid,
            .dcid_len = if (dcid_len == 0) DEFAULT_CONNECTION_ID_LEN else dcid_len,
            .scid = scid,
            .scid_len = scid_len,
            .packet_number = packet_number,
            .packet_number_len = @intCast(pn_len),
            .payload_offset = off,
        };
    }

    if ((first & QUIC_SHORT_FIXED_BIT) == 0) return error.InvalidPacket;
    if ((first & QUIC_SHORT_RESERVED_BITS) != 0) return error.InvalidPacket;

    const pn_len = try packetNumberLenFromField(first & QUIC_SHORT_PACKET_NUMBER_MASK);
    const dcid_len: usize = DEFAULT_CONNECTION_ID_LEN;
    if (data.len < 1 + dcid_len + pn_len) return error.InvalidPacket;
    var dcid = std.mem.zeroes(ConnectionId);
    @memcpy(dcid[0..], data[1 .. 1 + dcid_len]);
    const off = 1 + dcid_len;
    const packet_number = readPacketNumber(data[off .. off + pn_len]);

    return PacketHeader{
        .is_long = false,
        .packet_type = PacketType.one_rtt,
        .version = 0,
        .dcid = dcid,
        .dcid_len = @intCast(dcid_len),
        .scid = std.mem.zeroes(ConnectionId),
        .scid_len = 0,
        .packet_number = packet_number,
        .packet_number_len = @intCast(pn_len),
        .payload_offset = off + pn_len,
    };
}

fn packetNumberLenFromField(field: u8) !usize {
    return switch (field & 0x03) {
        0x00 => 1,
        0x01 => 2,
        0x02 => 4,
        0x03 => 8,
        else => error.InvalidPacket,
    };
}

fn packetNumberFieldFromLen(len: usize) !u8 {
    return switch (len) {
        1 => 0x00,
        2 => 0x01,
        4 => 0x02,
        8 => 0x03,
        else => error.InvalidPacket,
    };
}

fn writePacketNumber(dst: []u8, packet_number: u64, len: usize) ![]u8 {
    if (dst.len < len) return error.FrameTooLarge;
    const start = dst.len - len;
    switch (len) {
        1 => dst[dst.len - 1] = @truncate(packet_number),
        2 => {
            dst[start] = @truncate(packet_number >> 8);
            dst[start + 1] = @truncate(packet_number);
        },
        4 => std.mem.writeInt(u32, dst[start .. start + 4], @truncate(packet_number), .big),
        8 => std.mem.writeInt(u64, dst[start .. start + 8], packet_number, .big),
        else => return error.InvalidPacket,
    }
    return dst[dst.len - len .. dst.len];
}

fn packetHeaderOverhead(conn: *const QuicConn) usize {
    if (conn.state == .connected) {
        return 1 + @as(usize, conn.dcid_len) + QUIC_PACKET_NUMBER_BYTES_4;
    }
    return 1 + QUIC_PACKET_NUMBER_BYTES_4 + 1 + @as(usize, conn.dcid_len) + 1 + @as(usize, conn.local_cid_len) + 1 + QUIC_PACKET_NUMBER_BYTES_4;
}

fn encodePacketHeader(
    out: []u8,
    use_long: bool,
    version: u32,
    dcid: []const u8,
    scid: []const u8,
    packet_number: u64,
    packet_type: PacketType,
) !usize {
    var off: usize = 0;
    const packet_number_len = QUIC_PACKET_NUMBER_BYTES_4;
    const packet_number_field = try packetNumberFieldFromLen(packet_number_len);

    if (use_long) {
        const token_space = if (packet_type == .initial or packet_type == .retry) @as(usize, 1) else @as(usize, 0);
        if (out.len < 1 + 4 + 1 + dcid.len + 1 + scid.len + token_space + packet_number_len) return error.FrameTooLarge;
        const type_bits: u8 = switch (packet_type) {
            .initial => 0x00,
            .zero_rtt => 0x10,
            .handshake => 0x20,
            .retry => 0x30,
            .one_rtt => 0x20,
        };
        out[off] = QUIC_LONG_HEADER | QUIC_LONG_FIXED_BIT | type_bits | packet_number_field;
        off += 1;
        std.mem.writeInt(u32, out[off .. off + 4], version, .big);
        off += 4;
        out[off] = @as(u8, @intCast(dcid.len));
        off += 1;
        @memcpy(out[off .. off + dcid.len], dcid);
        off += dcid.len;
        out[off] = @as(u8, @intCast(scid.len));
        off += 1;
        @memcpy(out[off .. off + scid.len], scid);
        off += scid.len;
        if (packet_type == .initial or packet_type == .retry) {
            out[off] = 0;
            off += 1;
        }
    } else {
        if (out.len < 1 + dcid.len + packet_number_len) return error.FrameTooLarge;
        out[off] = QUIC_SHORT_FIXED_BIT | packet_number_field;
        off += 1;
        @memcpy(out[off .. off + dcid.len], dcid);
        off += dcid.len;
    }

    const packet_number_bytes = try writePacketNumber(
        out[off .. off + packet_number_len],
        packet_number,
        packet_number_len,
    );
    off += packet_number_bytes.len;
    return off;
}

fn readPacketNumber(data: []const u8) u64 {
    var v: u64 = 0;
    for (data) |b| v = (v << 8) | @as(u64, b);
    return v;
}

fn encodeVarInt(dst: []u8, v: u64) !usize {
    if (dst.len < 1) return error.FrameTooLarge;
    if (v < 0x40) {
        dst[0] = @truncate(v);
        return 1;
    }
    if (v < 0x4000) {
        if (dst.len < 2) return error.FrameTooLarge;
        dst[0] = @truncate((v >> 8) | 0x40);
        dst[1] = @truncate(v);
        return 2;
    }
    if (v < 0x40000000) {
        if (dst.len < 4) return error.FrameTooLarge;
        dst[0] = @truncate((v >> 24) | 0x80);
        dst[1] = @truncate(v >> 16);
        dst[2] = @truncate(v >> 8);
        dst[3] = @truncate(v);
        return 4;
    }
    if (dst.len < 8) return error.FrameTooLarge;
    dst[0] = @truncate((v >> 56) | 0xc0);
    dst[1] = @truncate(v >> 48);
    dst[2] = @truncate(v >> 40);
    dst[3] = @truncate(v >> 32);
    dst[4] = @truncate(v >> 24);
    dst[5] = @truncate(v >> 16);
    dst[6] = @truncate(v >> 8);
    dst[7] = @truncate(v);
    return 8;
}

fn decodeVarInt(data: []const u8) !VarInt {
    if (data.len == 0) return error.MalformedVarInt;
    const first = data[0];
    const prefix = first >> 6;
    switch (prefix) {
        0x00 => return VarInt{ .value = @as(u64, first & 0x3f), .bytes = 1 },
        0x01 => {
            if (data.len < 2) return error.MalformedVarInt;
            const value = (@as(u64, first & 0x3f) << 8) | @as(u64, data[1]);
            if (value < 0x40) {
                return error.MalformedVarInt;
            }
            return VarInt{ .value = value, .bytes = 2 };
        },
        0x02 => {
            if (data.len < 4) return error.MalformedVarInt;
            const value = (@as(u64, first & 0x3f) << 24) |
                (@as(u64, data[1]) << 16) |
                (@as(u64, data[2]) << 8) |
                @as(u64, data[3]);
            if (value < 0x4000) {
                return error.MalformedVarInt;
            }
            return VarInt{ .value = value, .bytes = 4 };
        },
        0x03 => {
            if (data.len < 8) return error.MalformedVarInt;
            const value = (@as(u64, first & 0x3f) << 56) |
                (@as(u64, data[1]) << 48) |
                (@as(u64, data[2]) << 40) |
                (@as(u64, data[3]) << 32) |
                (@as(u64, data[4]) << 24) |
                (@as(u64, data[5]) << 16) |
                (@as(u64, data[6]) << 8) |
                @as(u64, data[7]);
            if (value < 0x4000_0000) {
                return error.MalformedVarInt;
            }
            return VarInt{ .value = value, .bytes = 8 };
        },
        else => return error.MalformedVarInt,
    }
}

pub const QuicError = error{
    ConnectionClosed,
    FrameTooLarge,
    HandshakeInProgress,
    Timeout,
    FlowControl,
    InvalidStream,
    StreamClosed,
    StreamNotInOrder,
    MalformedVarInt,
    InvalidFrame,
    InvalidPacket,
    UnsupportedFrame,
    ServerStopped,
};

test "quic varint roundtrips for RFC9000-compatible lengths" {
    var buf: [16]u8 = undefined;

    var n = try encodeVarInt(&buf, 0x3f);
    try std.testing.expectEqual(@as(usize, 1), n);
    const a = try decodeVarInt(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 0x3f), a.value);

    n = try encodeVarInt(&buf, 0x40);
    try std.testing.expectEqual(@as(usize, 2), n);
    const b = try decodeVarInt(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 0x40), b.value);

    n = try encodeVarInt(&buf, 0x4000);
    try std.testing.expectEqual(@as(usize, 4), n);
    const c = try decodeVarInt(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 0x4000), c.value);

    n = try encodeVarInt(&buf, 0x4000_0000);
    try std.testing.expectEqual(@as(usize, 8), n);
    const d = try decodeVarInt(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), d.value);
}

test "quic varint rejects non-canonical encodings" {
    var bad: [2]u8 = .{
        0x40,
        0x01,
    };
    try std.testing.expectError(error.MalformedVarInt, decodeVarInt(&bad));

    var bad4: [4]u8 = .{
        0x80,
        0x00,
        0x00,
        0x01,
    };
    try std.testing.expectError(error.MalformedVarInt, decodeVarInt(&bad4));

    var bad8: [8]u8 = .{
        0xc0,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
    };
    try std.testing.expectError(error.MalformedVarInt, decodeVarInt(&bad8));
}

test "quic long and short headers are parseable after RFC-style encoding" {
    var wire: [256]u8 = undefined;
    var dcid: [DEFAULT_CONNECTION_ID_LEN]u8 = .{9} ** DEFAULT_CONNECTION_ID_LEN;
    var scid: [DEFAULT_CONNECTION_ID_LEN]u8 = .{8} ** DEFAULT_CONNECTION_ID_LEN;

    const encoded = try encodePacketHeader(
        &wire,
        true,
        SUPPORTED_QUIC_VERSION,
        &dcid,
        &scid,
        10,
        .initial,
    );
    const parsed_long = try parsePacketHeader(wire[0..encoded]);
    try std.testing.expect(parsed_long.is_long);
    try std.testing.expect(parsed_long.version == SUPPORTED_QUIC_VERSION);
    try std.testing.expectEqual(PacketType.initial, parsed_long.packet_type);

    const short_len = try encodePacketHeader(
        wire[0..],
        false,
        SUPPORTED_QUIC_VERSION,
        &dcid,
        &.{},
        10,
        .one_rtt,
    );
    const parsed_short = try parsePacketHeader(wire[0..short_len]);
    try std.testing.expect(!parsed_short.is_long);
    try std.testing.expectEqual(PacketType.one_rtt, parsed_short.packet_type);
    try std.testing.expectEqual(DEFAULT_CONNECTION_ID_LEN, parsed_short.dcid_len);
}

test "quic short header rejects reserved bits" {
    var wire: [64]u8 = undefined;
    const dcid = [_]u8{0} ** DEFAULT_CONNECTION_ID_LEN;
    const short_len = try encodePacketHeader(
        &wire,
        false,
        SUPPORTED_QUIC_VERSION,
        &dcid,
        &.{},
        5,
        .one_rtt,
    );

    var bad = wire;
    bad[0] |= QUIC_SHORT_RESERVED_BITS;
    try std.testing.expectError(error.InvalidPacket, parsePacketHeader(bad[0..short_len]));
}
