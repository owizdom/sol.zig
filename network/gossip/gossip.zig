// Gossip protocol: CRDS (Cluster Replicated Data Store) over UDP.
// Push/pull dissemination of node contact info, votes, slot state, etc.
const std = @import("std");
const types   = @import("types");
const keypair = @import("keypair");
const metrics = @import("metrics");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{
    InvalidPacket,
    UnsupportedMessage,
    NoData,
    InvalidSignature,
    BufferTooSmall,
};
const RecvError = error{
    WouldBlock,
    TimedOut,
    Interrupted,
    BadFileDescriptor,
};

// ── CRDS value types ─────────────────────────────────────────────────────────

pub const CrdsValueKind = enum(u8) {
    contact_info  = 0,
    vote          = 1,
    lowest_slot   = 2,
    snapshot_hashes = 3,
    epoch_slots   = 4,
    account_hash  = 5,
    ping          = 6,
    pong          = 7,
    node_instance = 8,
};

pub const ContactInfo = struct {
    id:          types.Pubkey,
    wallclock:   u64,
    gossip:      std.net.Address,
    tvu:         std.net.Address,  // Turbine recv
    tpu:         std.net.Address,  // Transaction recv
    tpu_fwd:     std.net.Address,
    repair:      std.net.Address,
    serve_repair: std.net.Address,
    shred_version: u16,
};

pub const EpochSlots = struct {
    from:         types.Pubkey,
    slots:        std.array_list.Managed(types.Slot),
    wallclock:    u64,

    pub fn init(allocator: std.mem.Allocator, from: types.Pubkey) EpochSlots {
        return .{
            .from      = from,
            .slots     = std.array_list.Managed(types.Slot).init(allocator),
            .wallclock = @intCast(std.time.milliTimestamp()),
        };
    }

    pub fn deinit(self: *EpochSlots) void {
        self.slots.deinit();
    }
};

pub const SnapshotHash = struct {
    from:      types.Pubkey,
    slot:      types.Slot,
    hash:      types.Hash,
    wallclock: u64,
};

pub const CrdsValue = union(CrdsValueKind) {
    contact_info:    ContactInfo,
    vote:            VoteCrds,
    lowest_slot:     LowestSlot,
    snapshot_hashes: SnapshotHash,
    epoch_slots:     EpochSlots,
    account_hash:    AccountHash,
    ping:            Ping,
    pong:            Pong,
    node_instance:   NodeInstance,
};

pub const VoteCrds = struct {
    from:      types.Pubkey,
    vote:      []const u8,  // serialized vote tx
    wallclock: u64,
    slot:      types.Slot,
};

pub const LowestSlot = struct {
    from:      types.Pubkey,
    root:      types.Slot,
    lowest:    types.Slot,
    wallclock: u64,
};

pub const AccountHash = struct {
    slot:      types.Slot,
    hash:      types.Hash,
    wallclock: u64,
};

pub const Ping = struct {
    from:  types.Pubkey,
    token: [32]u8,
};

pub const Pong = struct {
    from:  types.Pubkey,
    hash:  [32]u8,
};

pub const NodeInstance = struct {
    from:         types.Pubkey,
    wallclock:    u64,
    timestamp:    u64,
    token:        u64,
};

// ── CRDS table ───────────────────────────────────────────────────────────────

/// Maps pubkey -> ContactInfo for known peers.
pub const CrdsTable = struct {
    contacts:  std.AutoHashMap([32]u8, ContactInfo),
    mu:        std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CrdsTable {
        return .{
            .contacts  = std.AutoHashMap([32]u8, ContactInfo).init(allocator),
            .mu        = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CrdsTable) void {
        self.contacts.deinit();
    }

    pub fn upsertContact(self: *CrdsTable, ci: ContactInfo) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.contacts.put(ci.id.bytes, ci);
    }

    pub fn getPeers(self: *CrdsTable, out: *std.array_list.Managed(ContactInfo)) !void {
        self.mu.lock();
        defer self.mu.unlock();
        var it = self.contacts.valueIterator();
        while (it.next()) |ci| try out.append(ci.*);
    }

    pub fn count(self: *CrdsTable) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.contacts.count();
    }
};

// ── Gossip message types ──────────────────────────────────────────────────────

pub const GossipMsgKind = enum(u32) {
    pull_request  = 0,
    pull_response = 1,
    push_message  = 2,
    prune_message = 3,
    ping          = 4,
    pong          = 5,
    signed_push   = 6, // push_message with Ed25519 signature header
};

/// Serialized gossip packet (variable length, max ~1280 bytes for UDP).
pub const MAX_GOSSIP_PACKET: usize = 1280;
const GOSSIP_CONTACT_INFO_BYTES: usize = 39;
const MAX_CONTACTS_PER_PUSH: usize = (MAX_GOSSIP_PACKET - 8) / GOSSIP_CONTACT_INFO_BYTES;
const GOSSIP_PING_BYTES: usize = 68;
const GOSSIP_PRUNE_ENTRY_BYTES: usize = 32;
const GOSSIP_PULL_RESPONSE_ENTRY_BYTES: usize = 68;

fn bloomSeed(pubkey: []const u8) [32]u8 {
    var sha = Sha256.init(.{});
    sha.update(pubkey);
    var digest: [32]u8 = undefined;
    sha.final(&digest);
    return digest;
}

fn bloomMatch(filter: [32]u8, pubkey: []const u8) bool {
    const digest = bloomSeed(pubkey);
    const marker = std.mem.readInt(u32, digest[0..4], .little);
    const bit = marker % 256;
    return (filter[bit / 8] & (@as(u8, 1) << @intCast(bit % 8))) != 0;
}

fn bloomAdd(filter: *[32]u8, pubkey: []const u8) void {
    const digest = bloomSeed(pubkey);
    const marker = std.mem.readInt(u32, digest[0..4], .little);
    const bit = marker % 256;
    filter[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
}

fn buildBloomFilter(contacts: []const ContactInfo) [32]u8 {
    var filter = [_]u8{0} ** 32;
    for (contacts) |peer| {
        bloomAdd(&filter, &peer.id.bytes);
    }
    return filter;
}

fn encodeSocketAddr(addr: std.net.Address, out: []u8) void {
    @memset(out, 0);
    const ip = addr.in.sa.addr;
    out[0..4].* = @bitCast(ip);
}

// ── Signed push (Phase 4a: mainnet wire compatibility) ───────────────────────
//
// Format (signed_push = kind 6):
//   [4]  kind = 6 (u32 LE)
//   [64] Ed25519 signature over bytes[100..]
//   [32] signer pubkey
//   [4]  n_values (u32 LE)
//   [n × contact_info_bytes] CrdsValue payloads
const SIGNED_PUSH_HDR: usize = 4 + 64 + 32 + 4; // kind + sig + pubkey + n_values

/// Verify a CrdsValue signature.  Returns true iff the signature is valid.
pub fn verifyCrdsSignature(data: []const u8, sig: types.Signature, pubkey: types.Pubkey) bool {
    return keypair.verifySignature(pubkey, data, sig);
}

/// Serialize a signed push packet.  Returns the number of bytes written, or error.
pub fn serializeSignedPush(kp: keypair.KeyPair, ci: ContactInfo, buf: []u8) !usize {
    // Reserve header area; we'll fill the sig after serializing body.
    if (buf.len < SIGNED_PUSH_HDR + GOSSIP_CONTACT_INFO_BYTES) return error.BufferTooSmall;

    const body_start = SIGNED_PUSH_HDR;

    // kind
    std.mem.writeInt(u32, buf[0..4], @intFromEnum(GossipMsgKind.signed_push), .little);
    // sig placeholder (64 bytes) — filled below
    @memset(buf[4..68], 0);
    // pubkey
    @memcpy(buf[68..100], &kp.publicKey().bytes);
    // n_values = 1
    std.mem.writeInt(u32, buf[100..104], 1, .little);

    // CrdsValue (same layout as serializePush body)
    var off: usize = body_start;
    buf[off] = @intFromEnum(CrdsValueKind.contact_info); off += 1;
    @memcpy(buf[off..][0..32], &ci.id.bytes); off += 32;
    std.mem.writeInt(u16, buf[off..][0..2], ci.shred_version, .little); off += 2;
    const gip = ci.gossip.in.sa.addr;
    buf[off..][0..4].* = @bitCast(gip); off += 4;
    std.mem.writeInt(u16, buf[off..][0..2], ci.gossip.getPort(), .little); off += 2;

    // Sign bytes [100..off] (n_values + CrdsValue data).
    const signed_region = buf[100..off];
    const sig = try kp.sign(signed_region);
    @memcpy(buf[4..68], &sig.bytes);

    return off;
}

/// Deserialize a signed push packet, verifying the Ed25519 signature.
pub fn deserializeSignedPush(buf: []const u8, out: *std.array_list.Managed(ContactInfo)) !void {
    if (buf.len < SIGNED_PUSH_HDR) return error.InvalidPacket;
    const kind = try readMessageKind(buf);
    if (kind != .signed_push) return error.UnsupportedMessage;

    var sig_bytes: [64]u8 = undefined;
    @memcpy(&sig_bytes, buf[4..68]);
    const sig = types.Signature{ .bytes = sig_bytes };

    var pub_bytes: [32]u8 = undefined;
    @memcpy(&pub_bytes, buf[68..100]);
    const pubkey = types.Pubkey{ .bytes = pub_bytes };

    // Verify signature over bytes[100..end].
    const signed_region = buf[100..];
    if (!verifyCrdsSignature(signed_region, sig, pubkey)) return error.InvalidSignature;

    // Parse n_values + CrdsValue entries.
    const n = std.mem.readInt(u32, buf[100..104], .little);
    if (n == 0) return;
    if (n > MAX_CONTACTS_PER_PUSH) return error.InvalidPacket;

    var off: usize = 104;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (off + 1 > buf.len) return error.InvalidPacket;
        const vkind = buf[off]; off += 1;
        if (vkind != @intFromEnum(CrdsValueKind.contact_info)) return error.InvalidPacket;
        if (off + GOSSIP_CONTACT_INFO_BYTES - 1 > buf.len) return error.InvalidPacket;
        var ci: ContactInfo = undefined;
        ci.id.bytes = buf[off..][0..32].*; off += 32;
        ci.shred_version = std.mem.readInt(u16, buf[off..][0..2], .little); off += 2;
        const ip_bytes = buf[off..][0..4].*; off += 4;
        const port = std.mem.readInt(u16, buf[off..][0..2], .little); off += 2;
        ci.gossip = std.net.Address.initIp4(ip_bytes, port);
        ci.tvu = ci.gossip; ci.tpu = ci.gossip;
        ci.tpu_fwd = ci.gossip; ci.repair = ci.gossip; ci.serve_repair = ci.gossip;
        ci.wallclock = @intCast(std.time.milliTimestamp());
        try out.append(ci);
    }
}

// ── Push helpers ────────────────────────────────────────────────────────────

/// Simple push payload: kind(4) + n_values(4) + [ContactInfo serialized].
pub fn serializePush(ci: ContactInfo, buf: []u8) usize {
    var off: usize = 0;
    std.mem.writeInt(u32, buf[off..][0..4], @intFromEnum(GossipMsgKind.push_message), .little);
    off += 4;
    std.mem.writeInt(u32, buf[off..][0..4], 1, .little); // 1 value
    off += 4;
    buf[off] = @intFromEnum(CrdsValueKind.contact_info);
    off += 1;
    @memcpy(buf[off..][0..32], &ci.id.bytes);
    off += 32;
    std.mem.writeInt(u16, buf[off..][0..2], ci.shred_version, .little);
    off += 2;
    // Encode gossip address (ip4 + port).
    const gip = ci.gossip.in.sa.addr;
    buf[off..][0..4].* = @bitCast(gip); off += 4;
    std.mem.writeInt(u16, buf[off..][0..2], ci.gossip.getPort(), .little); off += 2;
    return off;
}

pub fn deserializePush(buf: []const u8, out: *std.array_list.Managed(ContactInfo)) !void {
    const kind = try readMessageKind(buf);
    if (kind != .push_message) return error.UnsupportedMessage;
    if (buf.len < 8) return error.InvalidPacket;
    const n_u32 = std.mem.readInt(u32, buf[4..8], .little);
    const n = @as(usize, n_u32);
    if (n == 0) return;
    if (n > MAX_CONTACTS_PER_PUSH) return error.InvalidPacket;
    if (n > std.math.maxInt(usize) / GOSSIP_CONTACT_INFO_BYTES) return error.InvalidPacket;
    if (n * GOSSIP_CONTACT_INFO_BYTES > buf.len - 8) return error.InvalidPacket;

    var off: usize = 8;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const vkind = buf[off]; off += 1;
        if (vkind != @intFromEnum(CrdsValueKind.contact_info)) return error.InvalidPacket;
        if (off + GOSSIP_CONTACT_INFO_BYTES - 1 > buf.len) return error.InvalidPacket;
        var ci: ContactInfo = undefined;
        ci.id.bytes = buf[off..][0..32].*; off += 32;
        ci.shred_version = std.mem.readInt(u16, buf[off..][0..2], .little); off += 2;
        const ip_bytes = buf[off..][0..4].*; off += 4;
        const port = std.mem.readInt(u16, buf[off..][0..2], .little); off += 2;
        ci.gossip = std.net.Address.initIp4(ip_bytes, port);
        ci.tvu    = ci.gossip;
        ci.tpu    = ci.gossip;
        ci.tpu_fwd   = ci.gossip;
        ci.repair    = ci.gossip;
        ci.serve_repair = ci.gossip;
        ci.wallclock = @intCast(std.time.milliTimestamp());
        try out.append(ci);
    }

    if (off != buf.len) return error.InvalidPacket;
}

pub fn deserializePing(buf: []const u8, out: *Ping) !void {
    if (buf.len != GOSSIP_PING_BYTES) return error.InvalidPacket;
    const kind = try readMessageKind(buf);
    if (kind != .ping) return error.UnsupportedMessage;

    var off: usize = 4;
    out.from.bytes = buf[off..][0..32].*;
    off += 32;
    out.token = buf[off..][0..32].*;
}

pub fn deserializePong(buf: []const u8, out: *Pong) !void {
    if (buf.len != GOSSIP_PING_BYTES) return error.InvalidPacket;
    const kind = try readMessageKind(buf);
    if (kind != .pong) return error.UnsupportedMessage;

    var off: usize = 4;
    out.from.bytes = buf[off..][0..32].*;
    off += 32;
    out.hash = buf[off..][0..32].*;
}

pub fn deserializePrune(buf: []const u8) !void {
    if (buf.len < 8) return error.InvalidPacket;
    const kind = try readMessageKind(buf);
    if (kind != .prune_message) return error.UnsupportedMessage;

    const n_u32 = std.mem.readInt(u32, buf[4..8], .little);
    const n = @as(usize, n_u32);
    if (n > std.math.maxInt(usize) / GOSSIP_PRUNE_ENTRY_BYTES) return error.InvalidPacket;

    const expected = 8 + n * GOSSIP_PRUNE_ENTRY_BYTES;
    if (expected != buf.len) return error.InvalidPacket;

    var off: usize = 8;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (off + GOSSIP_PRUNE_ENTRY_BYTES > buf.len) return error.InvalidPacket;
        off += GOSSIP_PRUNE_ENTRY_BYTES;
    }
}

fn readMessageKind(buf: []const u8) !GossipMsgKind {
    if (buf.len < 4) return error.InvalidPacket;
    return std.meta.intToEnum(GossipMsgKind, std.mem.readInt(u32, buf[0..4], .little));
}

fn recvFromSocket(
    sock: std.posix.socket_t,
    buf: []u8,
    flags: u32,
    src_addr: *std.posix.sockaddr,
    src_len: *std.posix.socklen_t,
) RecvError!usize {
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

// ── GossipNode ───────────────────────────────────────────────────────────────

pub const GossipNode = struct {
    kp:        keypair.KeyPair,
    my_info:   ContactInfo,
    crds:      CrdsTable,
    sock:      std.posix.socket_t,
    pull_seed: u64,
    allocator: std.mem.Allocator,
    running:   std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        kp:        keypair.KeyPair,
        bind_addr: std.net.Address,
        shred_ver: u16,
    ) !GossipNode {
        const sock = try std.posix.socket(
            std.posix.AF.INET, std.posix.SOCK.DGRAM, 0,
        );
        errdefer std.posix.close(sock);

        // Allow address reuse.
        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        // Bind.
        const addr = bind_addr.any;
        try std.posix.bind(sock, &addr, bind_addr.getOsSockLen());

        const my_info = ContactInfo{
            .id           = kp.publicKey(),
            .wallclock    = @intCast(std.time.milliTimestamp()),
            .gossip       = bind_addr,
            .tvu          = bind_addr,
            .tpu          = bind_addr,
            .tpu_fwd      = bind_addr,
            .repair       = bind_addr,
            .serve_repair  = bind_addr,
            .shred_version = shred_ver,
        };

        return .{
            .kp        = kp,
            .my_info   = my_info,
            .crds      = CrdsTable.init(allocator),
            .sock      = sock,
            .pull_seed = @bitCast(@as(u64, @intCast(std.time.milliTimestamp()))),
            .allocator = allocator,
            .running   = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *GossipNode) void {
        self.running.store(false, .release);
        std.posix.close(self.sock);
        self.crds.deinit();
    }

    /// Build and serialize a pull request packet to request entries from peer.
    pub fn sendPullRequest(self: *GossipNode, dest: std.net.Address) !void {
        var peers = std.array_list.Managed(ContactInfo).init(self.allocator);
        defer peers.deinit();
        try self.crds.getPeers(&peers);

        const bloom_filter = buildBloomFilter(peers.items);

        var buf: [MAX_GOSSIP_PACKET]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], @intFromEnum(GossipMsgKind.pull_request), .little);
        @memcpy(buf[4..36], &bloom_filter);
        @memcpy(buf[36..68], &self.my_info.id.bytes);

        const dest_os = dest.any;
        _ = try std.posix.sendto(self.sock, buf[0..68], 0, &dest_os, dest.getOsSockLen());
        _ = metrics.GLOBAL.gossip_messages_sent.fetchAdd(1, .monotonic);
    }

    /// Update the address this node advertises to the network.
    /// Call this after discovering your public IP so devnet validators can reach you.
    pub fn setAdvertisedAddr(self: *GossipNode, addr: std.net.Address) void {
        self.my_info.gossip       = addr;
        self.my_info.tvu          = addr;
        self.my_info.tpu          = addr;
        self.my_info.tpu_fwd      = addr;
        self.my_info.repair       = addr;
        self.my_info.serve_repair = addr;
        self.my_info.wallclock    = @intCast(std.time.milliTimestamp());
    }

    /// Add a peer directly as a gossip contact.
    pub fn seedPeer(self: *GossipNode, peer: std.net.Address) !void {
        const peer_id = peerIdFromAddress(peer);
        const ci = ContactInfo{
            .id = .{ .bytes = peer_id },
            .wallclock = @intCast(std.time.milliTimestamp()),
            .gossip = peer,
            .tvu = peer,
            .tpu = peer,
            .tpu_fwd = peer,
            .repair = peer,
            .serve_repair = peer,
            .shred_version = 0,
        };
        try self.crds.upsertContact(ci);
    }

    /// Seed gossip node with a list of peer endpoints.
    pub fn seedPeers(self: *GossipNode, peers: []const std.net.Address) void {
        for (peers) |peer| {
            self.seedPeer(peer) catch {};
        }
    }

    /// Handle an inbound pull request and reply with up-to-16 CRDS entries.
    pub fn handlePullRequest(self: *GossipNode, from_addr: std.net.Address, buf: []const u8) !void {
        if (buf.len < 68) return error.InvalidPacket;
        const kind = try readMessageKind(buf);
        if (kind != .pull_request) return error.UnsupportedMessage;

        const bloom_filter: [32]u8 = buf[4..36].*;
        const from_pubkey: [32]u8 = buf[36..68].*;
        _ = from_pubkey;

        var peers = std.array_list.Managed(ContactInfo).init(self.allocator);
        defer peers.deinit();
        try self.crds.getPeers(&peers);

        var out_buf: [MAX_GOSSIP_PACKET]u8 = undefined;
        std.mem.writeInt(u32, out_buf[0..4], @intFromEnum(GossipMsgKind.pull_response), .little);
        @memcpy(out_buf[4..36], &self.my_info.id.bytes);

        var entry_count: u32 = 0;
        var off: usize = 40;
        for (peers.items) |peer| {
            if (bloomMatch(bloom_filter, &peer.id.bytes)) continue;
            if (entry_count == 16) break;

            const base = off;
            @memcpy(out_buf[base .. base + 32], &peer.id.bytes);
            std.mem.writeInt(u16, @as(*[2]u8, @ptrCast(&out_buf[base + 32])), peer.gossip.getPort(), .little);
            std.mem.writeInt(u16, @as(*[2]u8, @ptrCast(&out_buf[base + 34])), 0, .little);
            encodeSocketAddr(peer.gossip, out_buf[base + 36 .. base + 68]);

            off += GOSSIP_PULL_RESPONSE_ENTRY_BYTES;
            if (off > out_buf.len) return error.InvalidPacket;
            entry_count += 1;
        }

        std.mem.writeInt(u32, out_buf[36..40], entry_count, .little);
        const to = from_addr.any;
        _ = try std.posix.sendto(self.sock, out_buf[0..off], 0, &to, from_addr.getOsSockLen());
        _ = metrics.GLOBAL.gossip_messages_sent.fetchAdd(1, .monotonic);
    }

    /// Handle an inbound pull response and insert unseen peers.
    pub fn handlePullResponse(self: *GossipNode, buf: []const u8) !void {
        if (buf.len < 40) return error.InvalidPacket;
        const kind = try readMessageKind(buf);
        if (kind != .pull_response) return error.UnsupportedMessage;

        const count = std.mem.readInt(u32, buf[36..40], .little);
        var off: usize = 40;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (off + GOSSIP_PULL_RESPONSE_ENTRY_BYTES > buf.len) return error.InvalidPacket;

            const entry = buf[off .. off + GOSSIP_PULL_RESPONSE_ENTRY_BYTES];
            const port = std.mem.readInt(u16, entry[32..34], .little);
            const ip: [4]u8 = entry[36..40].*;
            const addr = std.net.Address.initIp4(ip, port);
            const ci = ContactInfo{
                .id = .{ .bytes = entry[0..32].* },
                .wallclock = @intCast(std.time.milliTimestamp()),
                .gossip = addr,
                .tvu = addr,
                .tpu = addr,
                .tpu_fwd = addr,
                .repair = addr,
                .serve_repair = addr,
                .shred_version = 0,
            };
            if (self.crds.contacts.get(ci.id.bytes) != null) {
                off += GOSSIP_PULL_RESPONSE_ENTRY_BYTES;
                continue;
            }
            try self.crds.upsertContact(ci);

            off += GOSSIP_PULL_RESPONSE_ENTRY_BYTES;
        }
    }

    /// Receive one gossip packet, update CRDS.
    pub fn recvOnce(self: *GossipNode) !void {
        var buf: [MAX_GOSSIP_PACKET]u8 = undefined;
        var src_addr: std.posix.sockaddr align(4) = undefined;
        var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        const n = recvFromSocket(
            self.sock,
            &buf,
            std.posix.MSG.DONTWAIT,
            &src_addr,
            &src_len,
        ) catch |err| {
            if (err == error.WouldBlock) return error.NoData;
            if (err == error.BadFileDescriptor) return error.NoData;
            return err;
        };
        _ = metrics.GLOBAL.gossip_messages_recv.fetchAdd(1, .monotonic);
        if (n < 8) return error.InvalidPacket;

        const kind = readMessageKind(buf[0..n]) catch |e| {
            if (e != error.InvalidPacket and e != error.UnsupportedMessage) return e;
            return;
        };

        const from_addr = std.net.Address.initPosix(&src_addr);

        var contacts = std.array_list.Managed(ContactInfo).init(self.allocator);
        defer contacts.deinit();

        switch (kind) {
            .push_message => {
                deserializePush(buf[0..n], &contacts) catch |e| {
                    if (e != error.InvalidPacket and e != error.UnsupportedMessage) return e;
                    return;
                };
                for (contacts.items) |ci| try self.crds.upsertContact(ci);
            },
            .signed_push => {
                deserializeSignedPush(buf[0..n], &contacts) catch |e| {
                    if (e != error.InvalidPacket and e != error.UnsupportedMessage and
                        e != error.InvalidSignature) return e;
                    return; // drop packets with bad signatures
                };
                for (contacts.items) |ci| try self.crds.upsertContact(ci);
            },
            .ping => {
                var ping: Ping = undefined;
                deserializePing(buf[0..n], &ping) catch |e| {
                    if (e != error.InvalidPacket and e != error.UnsupportedMessage) return e;
                    return;
                };
            },
            .pong => {
                var pong: Pong = undefined;
                deserializePong(buf[0..n], &pong) catch |e| {
                    if (e != error.InvalidPacket and e != error.UnsupportedMessage) return e;
                    return;
                };
            },
            .prune_message => {
                deserializePrune(buf[0..n]) catch |e| {
                    if (e != error.InvalidPacket and e != error.UnsupportedMessage) return e;
                    return;
                };
            },
            .pull_request => try self.handlePullRequest(from_addr, buf[0..n]),
            .pull_response => try self.handlePullResponse(buf[0..n]),
        }
    }

    /// Push our ContactInfo to a peer (signed).
    pub fn pushToPeer(self: *GossipNode, peer: std.net.Address) !void {
        var buf: [MAX_GOSSIP_PACKET]u8 = undefined;
        const len = serializeSignedPush(self.kp, self.my_info, &buf) catch {
            // Fall back to unsigned push if signing fails (should not happen).
            const ulen = serializePush(self.my_info, &buf);
            const dest2 = peer.any;
            _ = try std.posix.sendto(self.sock, buf[0..ulen], 0, &dest2, peer.getOsSockLen());
            _ = metrics.GLOBAL.gossip_messages_sent.fetchAdd(1, .monotonic);
            return;
        };
        const dest = peer.any;
        _ = try std.posix.sendto(self.sock, buf[0..len], 0, &dest, peer.getOsSockLen());
        _ = metrics.GLOBAL.gossip_messages_sent.fetchAdd(1, .monotonic);
    }

    /// Background push loop: push our info every second.
    pub fn runPushLoop(self: *GossipNode) void {
        self.running.store(true, .release);
        var i: usize = 0;

        while (self.running.load(.acquire)) {
            // Drain any inbound packets each cycle to keep CRDS progressing.
            var recv_count: usize = 0;
            while (recv_count < 16) : (recv_count += 1) {
                self.recvOnce() catch |err| {
                    if (err == error.NoData) {} else return;
                };
            }

            // Push to all known peers.
            var peers = std.array_list.Managed(ContactInfo).init(self.allocator);
            self.crds.getPeers(&peers) catch {};
            defer peers.deinit();

            for (peers.items) |peer| {
                self.pushToPeer(peer.gossip) catch {};
            }

            if (i % 10 == 0 and peers.items.len > 0) {
                const idx = self.pull_seed % peers.items.len;
                self.pull_seed +%= 1;
                self.sendPullRequest(peers.items[idx].gossip) catch {};
            }

            i += 1;
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    }

    /// Spawns background gossip thread. Caller must call deinit() to stop.
    pub fn start(self: *GossipNode) !std.Thread {
        return std.Thread.spawn(.{}, GossipNode.runPushLoop, .{self});
    }
};

fn peerIdFromAddress(addr: std.net.Address) [32]u8 {
    const ip_bytes: [4]u8 = @bitCast(addr.in.sa.addr);
    var port_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &port_bytes, addr.getPort(), .big);

    var hasher = Sha256.init(.{});
    hasher.update("sig-gossip-peer");
    hasher.update(&ip_bytes);
    hasher.update(&port_bytes);

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

test "crds table upsert" {
    var table = CrdsTable.init(std.testing.allocator);
    defer table.deinit();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8000);
    const ci = ContactInfo{
        .id           = .{ .bytes = [_]u8{1} ** 32 },
        .wallclock    = 0,
        .gossip       = addr,
        .tvu          = addr,
        .tpu          = addr,
        .tpu_fwd      = addr,
        .repair       = addr,
        .serve_repair  = addr,
        .shred_version = 1,
    };
    try table.upsertContact(ci);
    try std.testing.expectEqual(@as(usize, 1), table.count());
}

test "push serialize/deserialize roundtrip" {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 9000);
    const ci = ContactInfo{
        .id           = .{ .bytes = [_]u8{0xBB} ** 32 },
        .wallclock    = 0,
        .gossip       = addr,
        .tvu          = addr,
        .tpu          = addr,
        .tpu_fwd      = addr,
        .repair       = addr,
        .serve_repair  = addr,
        .shred_version = 42,
    };
    var buf: [MAX_GOSSIP_PACKET]u8 = undefined;
    const len = serializePush(ci, &buf);

    var out = std.array_list.Managed(ContactInfo).init(std.testing.allocator);
    defer out.deinit();
    try deserializePush(buf[0..len], &out);

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(ci.id.eql(out.items[0].id));
    try std.testing.expectEqual(@as(u16, 42), out.items[0].shred_version);
}

test "recv dispatch ignores unsupported message types" {
    var payload: [MAX_GOSSIP_PACKET]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], @intFromEnum(GossipMsgKind.pull_request), .little);
    std.mem.writeInt(u32, payload[4..8], 0, .little);
    var out = std.array_list.Managed(ContactInfo).init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.UnsupportedMessage, deserializePush(payload[0..8], &out));
}

test "gossip replay fixtures through recv path" {
    const port_push = 19991;
    const port_recv = 19992;

    var node_push = try GossipNode.init(
        std.testing.allocator,
        keypair.KeyPair.generate(),
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port_push),
        0,
    );
    defer node_push.deinit();

    var node_recv = try GossipNode.init(
        std.testing.allocator,
        keypair.KeyPair.generate(),
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port_recv),
        0,
    );
    defer node_recv.deinit();

    // Replay a push packet fixture from peer A to peer B.
    try node_push.pushToPeer(node_recv.my_info.gossip);
    try node_recv.recvOnce();
    try std.testing.expectEqual(@as(usize, 1), node_recv.crds.count());

    // Compose a ping fixture (message kind + peer + token).
    var ping_payload: [GOSSIP_PING_BYTES]u8 = undefined;
    std.mem.writeInt(u32, ping_payload[0..4], @intFromEnum(GossipMsgKind.ping), .little);
    @memcpy(ping_payload[4..36], &node_recv.my_info.id.bytes);
    std.mem.writeInt(u32, ping_payload[36..40], 0, .little);
    std.mem.writeInt(u32, ping_payload[40..44], 0, .little);
    std.mem.writeInt(u32, ping_payload[44..48], 0, .little);
    std.mem.writeInt(u32, ping_payload[48..52], 0, .little);
    std.mem.writeInt(u32, ping_payload[52..56], 0, .little);
    std.mem.writeInt(u32, ping_payload[56..60], 0, .little);
    std.mem.writeInt(u32, ping_payload[60..68], 0, .little);
    const peer = node_recv.my_info.gossip.any;
    _ = try std.posix.sendto(node_push.sock, ping_payload[0..], 0, &peer, node_recv.my_info.gossip.getOsSockLen());
    try node_recv.recvOnce();
    try std.testing.expectEqual(@as(usize, 1), node_recv.crds.count());

    // Compose a prune fixture with 2 entries.
    var prune_payload: [8 + GOSSIP_PRUNE_ENTRY_BYTES * 2]u8 = undefined;
    std.mem.writeInt(u32, prune_payload[0..4], @intFromEnum(GossipMsgKind.prune_message), .little);
    std.mem.writeInt(u32, prune_payload[4..8], 2, .little);
    @memcpy(prune_payload[8..40], &node_recv.my_info.id.bytes);
    @memcpy(prune_payload[40..72], &node_push.my_info.id.bytes);
    _ = try std.posix.sendto(node_push.sock, prune_payload[0..], 0, &peer, node_recv.my_info.gossip.getOsSockLen());
    try node_recv.recvOnce();
    try std.testing.expectEqual(@as(usize, 1), node_recv.crds.count());
}

test "pull request/response exchanges CRDS entries" {
    var node_a = try GossipNode.init(
        std.testing.allocator,
        keypair.KeyPair.generate(),
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 22001),
        0,
    );
    defer node_a.deinit();

    var node_b = try GossipNode.init(
        std.testing.allocator,
        keypair.KeyPair.generate(),
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 22002),
        0,
    );
    defer node_b.deinit();

    try node_a.crds.upsertContact(node_b.my_info);
    try node_b.crds.upsertContact(node_a.my_info);

    var request: [68]u8 = undefined;
    std.mem.writeInt(u32, request[0..4], @intFromEnum(GossipMsgKind.pull_request), .little);
    @memset(request[4..36], 0);
    @memcpy(request[36..68], &node_a.my_info.id.bytes);

    const peer = node_a.my_info.gossip.any;
    _ = try std.posix.sendto(node_b.sock, request[0..], 0, &peer, node_a.my_info.gossip.getOsSockLen());

    const expected = node_a.crds.count() + 1;
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        node_a.recvOnce() catch |e| {
            if (e == error.NoData) {
                std.Thread.sleep(1000);
                continue;
            }
            return e;
        };
        if (node_a.crds.count() >= expected) break;
        std.Thread.sleep(1000);
    }

    try std.testing.expect(node_a.crds.count() >= expected);
}
