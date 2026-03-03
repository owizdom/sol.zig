const std = @import("std");
const types = @import("types");

const Ed25519 = std.crypto.sign.Ed25519;

pub const KeyPair = struct {
    inner: Ed25519.KeyPair,

    /// Generate a random Ed25519 keypair.
    pub fn generate() KeyPair {
        return .{ .inner = Ed25519.KeyPair.generate() };
    }

    /// Derive a keypair deterministically from a 32-byte seed.
    pub fn fromSeed(seed: [32]u8) !KeyPair {
        return .{ .inner = try Ed25519.KeyPair.generateDeterministic(seed) };
    }

    /// Return the public key as a Pubkey.
    pub fn publicKey(self: KeyPair) types.Pubkey {
        return .{ .bytes = self.inner.public_key.bytes };
    }

    /// Sign a message. Returns a 64-byte Signature.
    pub fn sign(self: KeyPair, msg: []const u8) !types.Signature {
        const sig = try self.inner.sign(msg, null);
        return .{ .bytes = sig.toBytes() };
    }
};

/// Verify an Ed25519 signature. Returns true iff valid.
pub fn verifySignature(pubkey: types.Pubkey, message: []const u8, sig: types.Signature) bool {
    const pk = Ed25519.PublicKey.fromBytes(pubkey.bytes) catch return false;
    const zig_sig = Ed25519.Signature.fromBytes(sig.bytes);
    zig_sig.verify(message, pk) catch return false;
    return true;
}

/// Backward-compatible alias for older call sites.
pub fn verify(pubkey: types.Pubkey, msg: []const u8, sig: types.Signature) bool {
    return verifySignature(pubkey, msg, sig);
}

test "generate, sign, verify" {
    const kp = KeyPair.generate();
    const msg = "hello solana";
    const sig = try kp.sign(msg);
    try std.testing.expect(verify(kp.publicKey(), msg, sig));
    // Wrong message must fail
    try std.testing.expect(!verify(kp.publicKey(), "wrong message", sig));
}

test "fromSeed is deterministic" {
    const seed = [_]u8{0xBE} ** 32;
    const kp1 = try KeyPair.fromSeed(seed);
    const kp2 = try KeyPair.fromSeed(seed);
    try std.testing.expectEqualSlices(u8, &kp1.publicKey().bytes, &kp2.publicKey().bytes);
}

test "different seeds produce different keys" {
    const kp1 = try KeyPair.fromSeed([_]u8{1} ** 32);
    const kp2 = try KeyPair.fromSeed([_]u8{2} ** 32);
    try std.testing.expect(!std.mem.eql(u8, &kp1.publicKey().bytes, &kp2.publicKey().bytes));
}
