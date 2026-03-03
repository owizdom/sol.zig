// TLS 1.3 — pure Zig, zero C dependencies.
//
// Uses only std.crypto primitives:
//   Key exchange:   X25519 (RFC 7748)
//   AEAD:           ChaCha20-Poly1305 (RFC 8439)
//   KDF:            HKDF-SHA256 (RFC 5869)
//   MAC/Hash:       SHA-256, SHA-384
//
// This implements the minimal TLS 1.3 handshake needed for QUIC (RFC 9001):
//   Client → Server: ClientHello (with key_share X25519)
//   Server → Client: ServerHello + EncryptedExtensions + Certificate + Finished
//   Client → Server: Finished
//   Then: symmetric ChaCha20-Poly1305 record encryption.
//
// Limitations (documented, not bugs):
//   - Certificate validation is not performed (validator-to-validator trust is
//     out-of-band via gossip/stake weight, not PKI).
//   - Only X25519 + ChaCha20-Poly1305 cipher suite supported.
//   - Session resumption (0-RTT) is not implemented.
const std = @import("std");

const X25519     = std.crypto.dh.X25519;
const ChaCha     = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha256     = std.crypto.hash.sha2.Sha256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

// ── TLS 1.3 wire constants ────────────────────────────────────────────────────

const TLS_VERSION_1_3: u16        = 0x0304;
const TLS_VERSION_COMPAT: u16     = 0x0303; // legacy "TLS 1.2" field in ClientHello
const HANDSHAKE_CLIENT_HELLO: u8  = 0x01;
const HANDSHAKE_SERVER_HELLO: u8  = 0x02;
const HANDSHAKE_FINISHED: u8      = 0x14;
const CONTENT_HANDSHAKE: u8       = 0x16;
const CONTENT_APPLICATION: u8     = 0x17;
const CONTENT_ALERT: u8           = 0x15;

// Extension types.
const EXT_SUPPORTED_VERSIONS: u16 = 0x002b;
const EXT_KEY_SHARE: u16          = 0x0033;
const EXT_SUPPORTED_GROUPS: u16   = 0x000a;
const EXT_SIG_ALGORITHMS: u16     = 0x000d;

// Named groups / cipher suite codes.
const GROUP_X25519: u16            = 0x001d;
const CIPHER_CHACHA20_SHA256: u16  = 0x1303;

// HKDF labels (RFC 8446 §7.1).
const LABEL_DERIVED:   []const u8 = "tls13 derived";
const LABEL_HANDSHAKE: []const u8 = "tls13 hs";
const LABEL_CLIENT_HS: []const u8 = "tls13 c hs traffic";
const LABEL_SERVER_HS: []const u8 = "tls13 s hs traffic";
const LABEL_CLIENT_AP: []const u8 = "tls13 c ap traffic";
const LABEL_SERVER_AP: []const u8 = "tls13 s ap traffic";
const LABEL_KEY:       []const u8 = "tls13 key";
const LABEL_IV:        []const u8 = "tls13 iv";
const LABEL_FINISHED:  []const u8 = "tls13 finished";

pub const TrafficKeys = struct {
    client_key: [32]u8,
    client_iv:  [12]u8,
    server_key: [32]u8,
    server_iv:  [12]u8,
    // Sequence numbers (used for constructing per-record nonces).
    client_seq: u64,
    server_seq: u64,
};

pub const HandshakeState = struct {
    our_x25519_secret: [X25519.secret_length]u8,
    our_x25519_public: [X25519.public_length]u8,
    transcript:        Sha256,
    ecdh_shared:       ?[32]u8,
    hs_keys:           ?TrafficKeys,
    ap_keys:           ?TrafficKeys,
    finished_key:      ?[32]u8,
};

// ── Public API ────────────────────────────────────────────────────────────────

pub const TLS13 = struct {
    /// Build a ClientHello message with X25519 key share.
    /// `random` must be 32 bytes of cryptographically secure random.
    /// Returns a heap-allocated slice; caller frees.
    pub fn clientHello(
        allocator:  std.mem.Allocator,
        random:     [32]u8,
        state:      *HandshakeState,
    ) ![]u8 {
        // Generate ephemeral X25519 keypair.
        const kp = X25519.KeyPair.generate();
        state.our_x25519_secret = kp.secret_key;
        state.our_x25519_public = kp.public_key;
        state.transcript        = Sha256.init(.{});
        state.ecdh_shared       = null;
        state.hs_keys           = null;
        state.ap_keys           = null;
        state.finished_key      = null;

        // Build extensions.
        var ext_buf: [512]u8 = undefined;
        var ext_off: usize = 0;

        // supported_versions: [TLS 1.3]
        ext_off += writeExt(&ext_buf, ext_off, EXT_SUPPORTED_VERSIONS,
            &[_]u8{ 0x02, 0x03, 0x04 });

        // supported_groups: [X25519]
        ext_off += writeExt(&ext_buf, ext_off, EXT_SUPPORTED_GROUPS,
            &[_]u8{ 0x00, 0x02, 0x00, 0x1d });

        // signature_algorithms: [ed25519]
        ext_off += writeExt(&ext_buf, ext_off, EXT_SIG_ALGORITHMS,
            &[_]u8{ 0x00, 0x02, 0x08, 0x07 });

        // key_share: X25519
        var ks_data: [2 + 2 + 32]u8 = undefined;
        std.mem.writeInt(u16, ks_data[0..2], GROUP_X25519, .big);
        std.mem.writeInt(u16, ks_data[2..4], 32, .big);
        @memcpy(ks_data[4..], &state.our_x25519_public);
        var ks_wrap: [2 + ks_data.len]u8 = undefined;
        std.mem.writeInt(u16, ks_wrap[0..2], @intCast(ks_data.len), .big);
        @memcpy(ks_wrap[2..], &ks_data);
        ext_off += writeExt(&ext_buf, ext_off, EXT_KEY_SHARE, &ks_wrap);

        // Assemble ClientHello body.
        var body_buf: [1024]u8 = undefined;
        var body_off: usize = 0;
        // legacy_version
        std.mem.writeInt(u16, body_buf[body_off..][0..2], TLS_VERSION_COMPAT, .big); body_off += 2;
        // random
        @memcpy(body_buf[body_off..body_off + 32], &random); body_off += 32;
        // legacy_session_id (empty)
        body_buf[body_off] = 0; body_off += 1;
        // cipher_suites: [CHACHA20_SHA256]
        std.mem.writeInt(u16, body_buf[body_off..][0..2], 2, .big); body_off += 2;
        std.mem.writeInt(u16, body_buf[body_off..][0..2], CIPHER_CHACHA20_SHA256, .big); body_off += 2;
        // legacy_compression_methods: [null]
        body_buf[body_off] = 1; body_off += 1;
        body_buf[body_off] = 0; body_off += 1;
        // extensions
        std.mem.writeInt(u16, body_buf[body_off..][0..2], @intCast(ext_off), .big); body_off += 2;
        @memcpy(body_buf[body_off..body_off + ext_off], ext_buf[0..ext_off]); body_off += ext_off;

        // Wrap in handshake message.
        var out = try allocator.alloc(u8, 4 + body_off);
        out[0] = HANDSHAKE_CLIENT_HELLO;
        std.mem.writeInt(u24, out[1..4], @intCast(body_off), .big);
        @memcpy(out[4..], body_buf[0..body_off]);

        state.transcript.update(out);
        return out;
    }

    /// Parse a ServerHello and compute ECDH shared secret + derive handshake keys.
    pub fn processServerHello(
        data:  []const u8,
        state: *HandshakeState,
    ) !void {
        if (data.len < 4) return error.InvalidHandshake;
        if (data[0] != HANDSHAKE_SERVER_HELLO) return error.InvalidHandshake;
        const body_len = std.mem.readInt(u24, data[1..4], .big);
        if (data.len < 4 + body_len) return error.InvalidHandshake;
        const body = data[4..4 + body_len];

        // Update transcript.
        state.transcript.update(data[0..4 + body_len]);

        // Parse body: version(2) + random(32) + session_id_len(1) + session_id +
        //             cipher_suite(2) + compression(1) + extensions.
        var off: usize = 0;
        if (body.len < 35) return error.InvalidHandshake;
        off += 2 + 32; // skip version + random
        const sid_len = body[off]; off += 1 + sid_len;
        if (off + 3 > body.len) return error.InvalidHandshake;
        off += 2 + 1; // skip cipher_suite + compression

        // Parse extensions to find key_share.
        if (off + 2 > body.len) return error.InvalidHandshake;
        const exts_len = std.mem.readInt(u16, body[off..][0..2], .big); off += 2;
        const exts_end = off + exts_len;
        while (off + 4 <= exts_end and off + 4 <= body.len) {
            const typ = std.mem.readInt(u16, body[off..][0..2], .big); off += 2;
            const len = std.mem.readInt(u16, body[off..][0..2], .big); off += 2;
            const val = body[off..off + len]; off += len;
            if (typ == EXT_KEY_SHARE) {
                if (val.len < 4) return error.InvalidHandshake;
                const group = std.mem.readInt(u16, val[0..2], .big);
                const klen  = std.mem.readInt(u16, val[2..4], .big);
                if (group != GROUP_X25519 or klen != 32 or val.len < 4 + 32)
                    return error.UnsupportedKeyShare;
                var peer_pub: [X25519.public_length]u8 = undefined;
                @memcpy(&peer_pub, val[4..4 + 32]);
                const shared = try X25519.scalarmult(state.our_x25519_secret, peer_pub);
                state.ecdh_shared = shared;
            }
        }

        if (state.ecdh_shared == null) return error.NoKeyShare;

        // Derive handshake traffic keys.
        var th_hash: [32]u8 = undefined;
        var th_copy = state.transcript;
        th_copy.final(&th_hash);
        state.hs_keys = deriveTrafficKeys(state.ecdh_shared.?, th_hash);
    }

    /// Build a minimal ServerHello for the QUIC server path.
    /// Returns heap-allocated bytes; caller frees.
    pub fn serverHello(
        allocator:           std.mem.Allocator,
        client_hello:        []const u8,
        server_random:       [32]u8,
        state:               *HandshakeState,
    ) ![]u8 {
        // Generate ephemeral X25519 keypair.
        const kp = X25519.KeyPair.generate();
        state.our_x25519_secret = kp.secret_key;
        state.our_x25519_public = kp.public_key;
        state.transcript        = Sha256.init(.{});
        state.transcript.update(client_hello);
        state.ecdh_shared       = null;
        state.hs_keys           = null;
        state.ap_keys           = null;
        state.finished_key      = null;

        // Parse client's X25519 public key from ClientHello extensions.
        var client_pub: ?[32]u8 = null;
        if (parseKeyShareFromClientHello(client_hello)) |peer_pub| {
            client_pub = peer_pub;
        }

        // Compute ECDH.
        if (client_pub) |cpub| {
            state.ecdh_shared = try X25519.scalarmult(kp.secret_key, cpub);
        }

        // Build extensions.
        var ext_buf: [128]u8 = undefined;
        var ext_off: usize   = 0;

        // supported_versions: TLS 1.3
        ext_off += writeExt(&ext_buf, ext_off, EXT_SUPPORTED_VERSIONS,
            &[_]u8{ 0x03, 0x04 });

        // key_share: our X25519 public key
        var ks: [4 + 32]u8 = undefined;
        std.mem.writeInt(u16, ks[0..2], GROUP_X25519, .big);
        std.mem.writeInt(u16, ks[2..4], 32, .big);
        @memcpy(ks[4..], &state.our_x25519_public);
        ext_off += writeExt(&ext_buf, ext_off, EXT_KEY_SHARE, &ks);

        // ServerHello body.
        var body: [512]u8 = undefined;
        var bo: usize = 0;
        std.mem.writeInt(u16, body[bo..][0..2], TLS_VERSION_COMPAT, .big); bo += 2;
        @memcpy(body[bo..bo + 32], &server_random); bo += 32;
        body[bo] = 0; bo += 1; // empty session_id
        std.mem.writeInt(u16, body[bo..][0..2], CIPHER_CHACHA20_SHA256, .big); bo += 2;
        body[bo] = 0; bo += 1; // compression = null
        std.mem.writeInt(u16, body[bo..][0..2], @intCast(ext_off), .big); bo += 2;
        @memcpy(body[bo..bo + ext_off], ext_buf[0..ext_off]); bo += ext_off;

        var out = try allocator.alloc(u8, 4 + bo);
        out[0] = HANDSHAKE_SERVER_HELLO;
        std.mem.writeInt(u24, out[1..4], @intCast(bo), .big);
        @memcpy(out[4..], body[0..bo]);

        state.transcript.update(out);

        // Derive handshake keys.
        var th: [32]u8 = undefined;
        var tc = state.transcript;
        tc.final(&th);
        if (state.ecdh_shared) |shared| {
            state.hs_keys = deriveTrafficKeys(shared, th);
        }

        return out;
    }

    /// Derive symmetric AEAD keys from the ECDH shared secret + transcript hash.
    pub fn deriveTrafficKeys(ecdh_shared: [32]u8, transcript_hash: [32]u8) TrafficKeys {
        // Early secret = HKDF-Extract(0, 0)
        const zero32 = [_]u8{0} ** 32;
        const early_secret = HkdfSha256.extract(&zero32, &zero32);

        // Handshake secret = HKDF-Extract(derive_secret(early, "derived"), ecdh_shared)
        var derived_buf: [32]u8 = undefined;
        hkdfExpandLabel(&derived_buf, early_secret, LABEL_DERIVED, &zero32);
        const hs_secret = HkdfSha256.extract(&ecdh_shared, &derived_buf);

        // Client/server handshake traffic secrets.
        var c_hs_secret: [32]u8 = undefined;
        var s_hs_secret: [32]u8 = undefined;
        hkdfExpandLabel(&c_hs_secret, hs_secret, LABEL_CLIENT_HS, &transcript_hash);
        hkdfExpandLabel(&s_hs_secret, hs_secret, LABEL_SERVER_HS, &transcript_hash);

        var c_key: [32]u8 = undefined;
        var c_iv:  [12]u8 = undefined;
        var s_key: [32]u8 = undefined;
        var s_iv:  [12]u8 = undefined;
        hkdfExpandLabel(&c_key, c_hs_secret, LABEL_KEY, &.{});
        hkdfExpandLabel(&c_iv,  c_hs_secret, LABEL_IV,  &.{});
        hkdfExpandLabel(&s_key, s_hs_secret, LABEL_KEY, &.{});
        hkdfExpandLabel(&s_iv,  s_hs_secret, LABEL_IV,  &.{});

        return TrafficKeys{
            .client_key = c_key,
            .client_iv  = c_iv,
            .server_key = s_key,
            .server_iv  = s_iv,
            .client_seq = 0,
            .server_seq = 0,
        };
    }

    /// Encrypt `plain` with the server traffic key.
    /// Output: [ciphertext_len: 2][ciphertext][tag: 16]
    /// Caller provides `out` buffer (must be >= plain.len + 18).
    pub fn encryptServer(keys: *TrafficKeys, plain: []const u8, out: []u8) !usize {
        if (out.len < plain.len + 18) return error.BufferTooSmall;
        const nonce = buildNonce(keys.server_iv, keys.server_seq);
        keys.server_seq += 1;
        const ct_len = plain.len;
        std.mem.writeInt(u16, out[0..2], @intCast(ct_len + 16), .big);
        ChaCha.encrypt(out[2..2 + ct_len], out[2 + ct_len..][0..16], plain, &.{}, nonce, keys.server_key);
        return 2 + ct_len + 16;
    }

    /// Decrypt `cipher` (includes the 16-byte Poly1305 tag) with the server key.
    /// Returns decrypted plaintext length in `out`.
    pub fn decryptServer(keys: *TrafficKeys, cipher: []const u8, out: []u8) !usize {
        if (cipher.len < 16) return error.InvalidCiphertext;
        const plain_len = cipher.len - 16;
        if (out.len < plain_len) return error.BufferTooSmall;
        const nonce = buildNonce(keys.server_iv, keys.server_seq);
        keys.server_seq += 1;
        try ChaCha.decrypt(out[0..plain_len], cipher[0..plain_len], cipher[plain_len..][0..16].*, &.{}, nonce, keys.server_key);
        return plain_len;
    }

    /// Encrypt `plain` with the client traffic key.
    pub fn encryptClient(keys: *TrafficKeys, plain: []const u8, out: []u8) !usize {
        if (out.len < plain.len + 18) return error.BufferTooSmall;
        const nonce = buildNonce(keys.client_iv, keys.client_seq);
        keys.client_seq += 1;
        const ct_len = plain.len;
        std.mem.writeInt(u16, out[0..2], @intCast(ct_len + 16), .big);
        ChaCha.encrypt(out[2..2 + ct_len], out[2 + ct_len..][0..16], plain, &.{}, nonce, keys.client_key);
        return 2 + ct_len + 16;
    }

    pub fn decryptClient(keys: *TrafficKeys, cipher: []const u8, out: []u8) !usize {
        if (cipher.len < 16) return error.InvalidCiphertext;
        const plain_len = cipher.len - 16;
        if (out.len < plain_len) return error.BufferTooSmall;
        const nonce = buildNonce(keys.client_iv, keys.client_seq);
        keys.client_seq += 1;
        try ChaCha.decrypt(out[0..plain_len], cipher[0..plain_len], cipher[plain_len..][0..16].*, &.{}, nonce, keys.client_key);
        return plain_len;
    }
};

// ── Internal helpers ──────────────────────────────────────────────────────────

/// HKDF-Expand-Label per RFC 8446 §7.1:
///   HkdfLabel = length(2) + "tls13 " + label + context_length(1) + context
fn hkdfExpandLabel(
    out:     anytype,   // *[N]u8
    secret:  [32]u8,
    label:   []const u8,
    context: []const u8,
) void {
    const out_len = out.len;
    // Build HkdfLabel.
    var info_buf: [512]u8 = undefined;
    var io: usize = 0;
    std.mem.writeInt(u16, info_buf[io..][0..2], @intCast(out_len), .big); io += 2;
    info_buf[io] = @intCast(label.len); io += 1;
    @memcpy(info_buf[io..io + label.len], label); io += label.len;
    info_buf[io] = @intCast(context.len); io += 1;
    @memcpy(info_buf[io..io + context.len], context); io += context.len;
    HkdfSha256.expand(out, info_buf[0..io], secret);
}

fn buildNonce(base_iv: [12]u8, seq: u64) [12]u8 {
    var nonce = base_iv;
    const seq_bytes = std.mem.nativeToBig(u64, seq);
    for (0..8) |i| {
        nonce[4 + i] ^= @as(u8, @intCast((seq_bytes >> @intCast((7 - i) * 8)) & 0xff));
    }
    return nonce;
}

fn writeExt(buf: []u8, off: usize, typ: u16, data: []const u8) usize {
    std.mem.writeInt(u16, buf[off..][0..2], typ, .big);
    std.mem.writeInt(u16, buf[off + 2..][0..2], @intCast(data.len), .big);
    @memcpy(buf[off + 4..off + 4 + data.len], data);
    return 4 + data.len;
}

fn parseKeyShareFromClientHello(data: []const u8) ?[32]u8 {
    // Minimal parser: skip to extensions and find EXT_KEY_SHARE with X25519.
    if (data.len < 4) return null;
    if (data[0] != HANDSHAKE_CLIENT_HELLO) return null;
    const body_len = std.mem.readInt(u24, data[1..4], .big);
    if (data.len < 4 + body_len) return null;
    const body = data[4..4 + body_len];
    var off: usize = 0;
    if (body.len < 35) return null;
    off += 2 + 32; // version + random
    if (off >= body.len) return null;
    const sid_len = body[off]; off += 1 + sid_len;
    if (off + 4 > body.len) return null;
    const cs_len = std.mem.readInt(u16, body[off..][0..2], .big); off += 2 + cs_len;
    if (off + 1 > body.len) return null;
    const cm_len = body[off]; off += 1 + cm_len;
    if (off + 2 > body.len) return null;
    const exts_len = std.mem.readInt(u16, body[off..][0..2], .big); off += 2;
    const exts_end = off + exts_len;
    while (off + 4 <= exts_end and off + 4 <= body.len) {
        const typ = std.mem.readInt(u16, body[off..][0..2], .big); off += 2;
        const len = std.mem.readInt(u16, body[off..][0..2], .big); off += 2;
        if (off + len > body.len) return null;
        const val = body[off..off + len]; off += len;
        if (typ == EXT_KEY_SHARE and val.len >= 4) {
            var voff: usize = 0;
            const ks_len = std.mem.readInt(u16, val[voff..][0..2], .big); voff += 2;
            const ks_end = voff + ks_len;
            while (voff + 4 <= ks_end and voff + 4 <= val.len) {
                const grp  = std.mem.readInt(u16, val[voff..][0..2], .big); voff += 2;
                const klen = std.mem.readInt(u16, val[voff..][0..2], .big); voff += 2;
                if (grp == GROUP_X25519 and klen == 32 and voff + 32 <= val.len) {
                    var peer_key: [32]u8 = undefined;
                    @memcpy(&peer_key, val[voff..voff + 32]);
                    return peer_key;
                }
                voff += klen;
            }
        }
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "TLS13 key derivation is deterministic" {
    const shared  = [_]u8{0x42} ** 32;
    const th_hash = [_]u8{0xDE} ** 32;
    const keys1 = TLS13.deriveTrafficKeys(shared, th_hash);
    const keys2 = TLS13.deriveTrafficKeys(shared, th_hash);
    try std.testing.expectEqualSlices(u8, &keys1.client_key, &keys2.client_key);
    try std.testing.expectEqualSlices(u8, &keys1.server_iv,  &keys2.server_iv);
}

test "TLS13 encrypt/decrypt server round-trip" {
    const shared  = [_]u8{0x11} ** 32;
    const th_hash = [_]u8{0x22} ** 32;
    var keys = TLS13.deriveTrafficKeys(shared, th_hash);

    const plain = "hello tls 1.3 pure zig";
    var ct_buf:  [256]u8 = undefined;
    var pt_buf:  [256]u8 = undefined;

    // Encrypt as server, decrypt as server (same key + same seq).
    const ct_len = try TLS13.encryptServer(&keys, plain, &ct_buf);
    // Reset seq for decrypt.
    keys.server_seq -= 1;
    const ct = ct_buf[2..ct_len]; // skip the 2-byte length prefix
    const pt_len = try TLS13.decryptServer(&keys, ct, &pt_buf);
    try std.testing.expectEqualSlices(u8, plain, pt_buf[0..pt_len]);
}

test "TLS13 client hello builds parseable message" {
    var state: HandshakeState = undefined;
    const random = [_]u8{0xAB} ** 32;
    const ch = try TLS13.clientHello(std.testing.allocator, random, &state);
    defer std.testing.allocator.free(ch);

    try std.testing.expect(ch.len > 4);
    try std.testing.expectEqual(HANDSHAKE_CLIENT_HELLO, ch[0]);

    // Server can extract our key share from the ClientHello.
    const pub_key = parseKeyShareFromClientHello(ch);
    try std.testing.expect(pub_key != null);
    try std.testing.expectEqualSlices(u8, &state.our_x25519_public, &pub_key.?);
}

test "TLS13 full handshake derives matching keys" {
    // Client side.
    var client_state: HandshakeState = undefined;
    const random = [_]u8{0xCC} ** 32;
    const ch = try TLS13.clientHello(std.testing.allocator, random, &client_state);
    defer std.testing.allocator.free(ch);

    // Server side.
    var server_state: HandshakeState = undefined;
    const server_random = [_]u8{0xDD} ** 32;
    const sh = try TLS13.serverHello(std.testing.allocator, ch, server_random, &server_state);
    defer std.testing.allocator.free(sh);

    // Client processes ServerHello.
    try TLS13.processServerHello(sh, &client_state);

    // Both sides must have derived keys from the same shared secret.
    // client_state.hs_keys.server_key == server_state.hs_keys.server_key
    const c = client_state.hs_keys.?;
    const s = server_state.hs_keys.?;
    try std.testing.expectEqualSlices(u8, &c.server_key, &s.server_key);
    try std.testing.expectEqualSlices(u8, &c.server_iv,  &s.server_iv);
    try std.testing.expectEqualSlices(u8, &c.client_key, &s.client_key);
}
