// Turbine: stake-weighted broadcast tree for shred propagation.
// Leader sends shreds to layer-0 nodes; they retransmit to layer-1, etc.
const std = @import("std");
const types  = @import("types");
const shred  = @import("net/shred");
const gossip = @import("net/gossip");

pub const MAX_TURBINE_FANOUT: usize = 200;
pub const TURBINE_LAYER_SIZE: usize = MAX_TURBINE_FANOUT;

// ── Turbine tree node ─────────────────────────────────────────────────────────

pub const TurbineNode = struct {
    pubkey:   types.Pubkey,
    addr:     std.net.Address,   // TVU (Turbine recv) address
    stake:    u64,
};

// ── Weighted peer list ────────────────────────────────────────────────────────

/// Build a stake-weighted, deterministically shuffled list of turbine peers
/// for a given slot and shred index. Uses SHA256(slot ++ shred_index ++ leader_id)
/// as the seed for ordering.
pub fn buildRetransmitPeers(
    leader_id:   types.Pubkey,
    slot:        types.Slot,
    shred_index: u32,
    peers:       []const TurbineNode,
    out:         *std.array_list.Managed(TurbineNode),
) !void {
    if (peers.len == 0) return;

    // Derive shuffle seed.
    var seed_buf: [72]u8 = undefined;
    std.mem.writeInt(u64, seed_buf[0..8],   slot, .little);
    std.mem.writeInt(u32, seed_buf[8..12],  shred_index, .little);
    @memcpy(seed_buf[12..44], &leader_id.bytes);
    @memset(seed_buf[44..], 0);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&seed_buf, &h, .{});

    // Fisher-Yates shuffle using the seed.
    var indices = try out.allocator.alloc(usize, peers.len);
    defer out.allocator.free(indices);
    for (indices, 0..) |*idx, i| idx.* = i;

    // Use 8 bytes of hash as RNG seed.
    var rng_state = std.mem.readInt(u64, h[0..8], .little);
    var i = indices.len;
    while (i > 1) {
        i -= 1;
        rng_state ^= rng_state << 13;
        rng_state ^= rng_state >> 7;
        rng_state ^= rng_state << 17;
        const j = rng_state % (i + 1);
        const tmp = indices[i];
        indices[i] = indices[j];
        indices[j] = tmp;
    }

    for (indices) |idx| try out.append(peers[idx]);
}

// ── Layer calculator ──────────────────────────────────────────────────────────

pub const LayerInfo = struct {
    layer:        usize,
    layer_start:  usize,
    layer_end:    usize,
};

/// Which turbine layer is node at `node_idx` in, given fanout?
pub fn getLayer(node_idx: usize, fanout: usize) LayerInfo {
    if (node_idx == 0) return .{ .layer = 0, .layer_start = 0, .layer_end = 0 };
    var layer: usize = 0;
    var start: usize = 1;
    var size:  usize = fanout;
    while (node_idx >= start + size) {
        start += size;
        size  *= fanout;
        layer += 1;
    }
    return .{ .layer = layer + 1, .layer_start = start, .layer_end = start + size - 1 };
}

/// Children of `node_idx` in the turbine tree.
pub fn children(node_idx: usize, fanout: usize, total: usize, out: []usize) usize {
    var n: usize = 0;
    var child = node_idx * fanout + 1;
    while (child <= node_idx * fanout + fanout and child < total and n < out.len) : (child += 1) {
        out[n] = child;
        n += 1;
    }
    return n;
}

// ── Turbine sender ────────────────────────────────────────────────────────────

pub const TurbineSender = struct {
    sock:      std.posix.socket_t,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bind_addr: std.net.Address) !TurbineSender {
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        errdefer std.posix.close(sock);
        const a = bind_addr.any;
        try std.posix.bind(sock, &a, bind_addr.getOsSockLen());
        return .{ .sock = sock, .allocator = allocator };
    }

    pub fn deinit(self: *TurbineSender) void {
        std.posix.close(self.sock);
    }

    /// Broadcast shreds to the first layer of the turbine tree.
    pub fn broadcast(
        self:        *TurbineSender,
        shreds:      []const shred.Shred,
        layer0_peers: []const TurbineNode,
    ) !void {
        for (shreds) |*sh| {
            for (layer0_peers) |peer| {
                const dest = peer.addr.any;
                _ = std.posix.sendto(
                    self.sock, &sh.data, 0, &dest, peer.addr.getOsSockLen(),
                ) catch continue;
            }
        }
    }
};

// ── Turbine receiver ──────────────────────────────────────────────────────────

pub const TurbineReceiver = struct {
    sock:       std.posix.socket_t,
    allocator:  std.mem.Allocator,
    // Outbound retransmit socket (same as recv in simplified impl).

    pub fn init(allocator: std.mem.Allocator, bind_addr: std.net.Address) !TurbineReceiver {
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        errdefer std.posix.close(sock);
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        const a = bind_addr.any;
        try std.posix.bind(sock, &a, bind_addr.getOsSockLen());
        const flags = try std.posix.fcntl(sock, std.posix.F.GETFL, 0);
        var o_flags: std.posix.O = @bitCast(@as(u32, @intCast(flags)));
        o_flags.NONBLOCK = true;
        _ = try std.posix.fcntl(sock, std.posix.F.SETFL, @as(usize, @intCast(@as(u32, @bitCast(o_flags)))));
        return .{ .sock = sock, .allocator = allocator };
    }

    pub fn deinit(self: *TurbineReceiver) void {
        std.posix.close(self.sock);
    }

    /// Receive one shred. Returns null on timeout/error.
    pub fn recvShred(self: *TurbineReceiver) ?shred.Shred {
        var buf: [shred.SHRED_SIZE]u8 = undefined;
        var src: std.posix.sockaddr = undefined;
        var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        const n = recvFromSocket(self.sock, &buf, 0, &src, &src_len) catch return null;
        if (n != shred.SHRED_SIZE) return null;
        return .{ .data = buf };
    }

    /// Retransmit a shred to downstream turbine children.
    pub fn retransmit(
        self:     *TurbineReceiver,
        sh:       *const shred.Shred,
        children_addrs: []const TurbineNode,
    ) void {
        for (children_addrs) |c| {
            const dest = c.addr.any;
            _ = std.posix.sendto(self.sock, &sh.data, 0, &dest, c.addr.getOsSockLen()) catch {};
        }
    }
};

fn recvFromSocket(
    sock: std.posix.socket_t,
    buf: []u8,
    flags: u32,
    src_addr: *std.posix.sockaddr,
    src_len: *std.posix.socklen_t,
) error{ WouldBlock, TimedOut, Interrupted, BadFileDescriptor }!usize {
    const rc = std.c.recvfrom(
        sock,
        @ptrCast(buf.ptr),
        buf.len,
        flags,
        src_addr,
        src_len,
    );
    if (rc >= 0) return @intCast(rc);

    const err = std.posix.errno(rc);
    switch (err) {
        .SUCCESS => unreachable,
        .AGAIN => return error.WouldBlock,
        .INTR => return error.Interrupted,
        .TIMEDOUT => return error.TimedOut,
        .BADF,
        .CONNREFUSED,
        .CONNRESET,
        .CONNABORTED,
        .NOTCONN => return error.BadFileDescriptor,
        else => return error.BadFileDescriptor,
    }
}

test "turbine layer calculation" {
    // Node 0: layer 0
    try std.testing.expectEqual(@as(usize, 0), getLayer(0, 200).layer);
    // Node 1: layer 1 (first child of root)
    try std.testing.expectEqual(@as(usize, 1), getLayer(1, 200).layer);
    // Node 200: still layer 1
    try std.testing.expectEqual(@as(usize, 1), getLayer(200, 200).layer);
    // Node 201: layer 2
    try std.testing.expectEqual(@as(usize, 2), getLayer(201, 200).layer);
}

test "build retransmit peers shuffles deterministically" {
    const leader = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    const peers = [_]TurbineNode{
        .{ .pubkey = .{ .bytes = [_]u8{1} ** 32 }, .addr = std.net.Address.initIp4(.{127,0,0,1}, 1001), .stake = 100 },
        .{ .pubkey = .{ .bytes = [_]u8{2} ** 32 }, .addr = std.net.Address.initIp4(.{127,0,0,1}, 1002), .stake = 200 },
        .{ .pubkey = .{ .bytes = [_]u8{3} ** 32 }, .addr = std.net.Address.initIp4(.{127,0,0,1}, 1003), .stake = 150 },
    };

    var out1 = std.array_list.Managed(TurbineNode).init(std.testing.allocator);
    defer out1.deinit();
    var out2 = std.array_list.Managed(TurbineNode).init(std.testing.allocator);
    defer out2.deinit();

    try buildRetransmitPeers(leader, 42, 0, &peers, &out1);
    try buildRetransmitPeers(leader, 42, 0, &peers, &out2);

    try std.testing.expectEqual(out1.items.len, out2.items.len);
    for (out1.items, out2.items) |a, b| {
        try std.testing.expect(a.pubkey.eql(b.pubkey));
    }
}
