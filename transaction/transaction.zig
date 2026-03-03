const std = @import("std");
const types = @import("types");
const encoding = @import("encoding");

// ── Wire-format structures ───────────────────────────────────────────────────

pub const MessageHeader = struct {
    /// Number of signatures required to consider this transaction valid.
    num_required_signatures: u8,
    /// Number of read-only accounts that require signatures.
    num_readonly_signed_accounts: u8,
    /// Number of read-only accounts that do NOT require signatures.
    num_readonly_unsigned_accounts: u8,
};

/// A compiled instruction referencing account keys by index.
pub const CompiledInstruction = struct {
    /// Index into `Message.account_keys` for the program to invoke.
    program_id_index: u8,
    /// Indices into `Message.account_keys` for each account the instruction uses.
    accounts: []const u8,
    /// Opaque instruction data.
    data: []const u8,
};

pub const Message = struct {
    header: MessageHeader,
    account_keys: []const types.Pubkey,
    recent_blockhash: types.Hash,
    instructions: []const CompiledInstruction,
};

pub const Transaction = struct {
    signatures: []const types.Signature,
    message: Message,

    /// Serialize just the message portion of this transaction, matching wire format.
    pub fn messageBytes(self: *const Transaction, buf: []u8) ![]u8 {
        var off: usize = 0;

        // Message header
        buf[off]     = self.message.header.num_required_signatures;
        buf[off + 1] = self.message.header.num_readonly_signed_accounts;
        buf[off + 2] = self.message.header.num_readonly_unsigned_accounts;
        off += 3;

        // Account keys
        off += encoding.writeCompactU16(@intCast(self.message.account_keys.len), buf[off..]);
        for (self.message.account_keys) |key| {
            @memcpy(buf[off..][0..32], &key.bytes);
            off += 32;
        }

        // Recent blockhash
        @memcpy(buf[off..][0..32], &self.message.recent_blockhash.bytes);
        off += 32;

        // Instructions
        off += encoding.writeCompactU16(@intCast(self.message.instructions.len), buf[off..]);
        for (self.message.instructions) |ix| {
            buf[off] = ix.program_id_index;
            off += 1;

            off += encoding.writeCompactU16(@intCast(ix.accounts.len), buf[off..]);
            @memcpy(buf[off..][0..ix.accounts.len], ix.accounts);
            off += ix.accounts.len;

            off += encoding.writeCompactU16(@intCast(ix.data.len), buf[off..]);
            @memcpy(buf[off..][0..ix.data.len], ix.data);
            off += ix.data.len;
        }

        return buf[0..off];
    }
};

// ── Serialization ────────────────────────────────────────────────────────────

/// Serialize `tx` into `buf` using the Solana wire format.
/// Layout:
///   [compact-u16: num_signatures]
///   [[64]u8 each: signatures]
///   [u8: num_required_signatures]
///   [u8: num_readonly_signed_accounts]
///   [u8: num_readonly_unsigned_accounts]
///   [compact-u16: num_account_keys]
///   [[32]u8 each: account_keys]
///   [[32]u8: recent_blockhash]
///   [compact-u16: num_instructions]
///   for each instruction:
///     [u8: program_id_index]
///     [compact-u16: num_accounts] [u8 each: account_indices]
///     [compact-u16: data_len]     [u8 each: data]
///
/// Returns the number of bytes written.
pub fn serialize(tx: Transaction, buf: []u8) !usize {
    var off: usize = 0;

    // Signatures
    off += encoding.writeCompactU16(@intCast(tx.signatures.len), buf[off..]);
    for (tx.signatures) |sig| {
        @memcpy(buf[off..][0..64], &sig.bytes);
        off += 64;
    }

    // Message header
    buf[off]     = tx.message.header.num_required_signatures;
    buf[off + 1] = tx.message.header.num_readonly_signed_accounts;
    buf[off + 2] = tx.message.header.num_readonly_unsigned_accounts;
    off += 3;

    // Account keys
    off += encoding.writeCompactU16(@intCast(tx.message.account_keys.len), buf[off..]);
    for (tx.message.account_keys) |key| {
        @memcpy(buf[off..][0..32], &key.bytes);
        off += 32;
    }

    // Recent blockhash
    @memcpy(buf[off..][0..32], &tx.message.recent_blockhash.bytes);
    off += 32;

    // Instructions
    off += encoding.writeCompactU16(@intCast(tx.message.instructions.len), buf[off..]);
    for (tx.message.instructions) |ix| {
        buf[off] = ix.program_id_index;
        off += 1;

        off += encoding.writeCompactU16(@intCast(ix.accounts.len), buf[off..]);
        @memcpy(buf[off..][0..ix.accounts.len], ix.accounts);
        off += ix.accounts.len;

        off += encoding.writeCompactU16(@intCast(ix.data.len), buf[off..]);
        @memcpy(buf[off..][0..ix.data.len], ix.data);
        off += ix.data.len;
    }

    return off;
}

pub const DeserializeError = error{
    InvalidMessage,
};

pub fn deserialize(buf: []const u8, allocator: std.mem.Allocator) !Transaction {
    var off: usize = 0;
    var used: usize = 0;

    const sig_count_u16 = try encoding.readCompactU16(buf[off..], &used);
    off += used;
    const sig_count = @as(usize, sig_count_u16);

    if (sig_count > (buf.len - off) / 64) return error.InvalidMessage;
    var signatures = try allocator.alloc(types.Signature, sig_count);
    errdefer allocator.free(signatures);

    var i: usize = 0;
    while (i < sig_count) : (i += 1) {
        if (off + 64 > buf.len) return error.InvalidMessage;
        @memcpy(&signatures[i].bytes, buf[off .. off + 64]);
        off += 64;
    }

    if (off + 3 > buf.len) return error.InvalidMessage;
    const header = MessageHeader{
        .num_required_signatures = buf[off],
        .num_readonly_signed_accounts = buf[off + 1],
        .num_readonly_unsigned_accounts = buf[off + 2],
    };
    off += 3;

    const account_count_u16 = try encoding.readCompactU16(buf[off..], &used);
    off += used;
    const account_count = @as(usize, account_count_u16);

    if (off + (account_count * 32) > buf.len) return error.InvalidMessage;
    var account_keys = try allocator.alloc(types.Pubkey, account_count);
    errdefer allocator.free(account_keys);

    i = 0;
    while (i < account_count) : (i += 1) {
        @memcpy(&account_keys[i].bytes, buf[off .. off + 32]);
        off += 32;
    }

    if (off + 32 > buf.len) return error.InvalidMessage;
    var blockhash = types.Hash{ .bytes = [_]u8{0} ** 32 };
    @memcpy(&blockhash.bytes, buf[off .. off + 32]);
    off += 32;

    const ix_count_u16 = try encoding.readCompactU16(buf[off..], &used);
    off += used;
    const ix_count = @as(usize, ix_count_u16);

    var instructions = try allocator.alloc(CompiledInstruction, ix_count);
    errdefer allocator.free(instructions);

    i = 0;
    while (i < ix_count) : (i += 1) {
        if (off >= buf.len) return error.InvalidMessage;

        const program_id_index = buf[off];
        off += 1;

        const account_len_u16 = try encoding.readCompactU16(buf[off..], &used);
        off += used;
        const account_len = @as(usize, account_len_u16);
        if (off + account_len > buf.len) return error.InvalidMessage;
        const account_slice = try allocator.alloc(u8, account_len);
        @memcpy(account_slice, buf[off .. off + account_len]);
        off += account_len;

        const data_len_u16 = try encoding.readCompactU16(buf[off..], &used);
        off += used;
        const data_len = @as(usize, data_len_u16);
        if (off + data_len > buf.len) return error.InvalidMessage;
        const data = try allocator.alloc(u8, data_len);
        @memcpy(data, buf[off .. off + data_len]);
        off += data_len;

        instructions[i] = .{
            .program_id_index = program_id_index,
            .accounts = account_slice,
            .data = data,
        };
    }

    return Transaction{
        .signatures = signatures,
        .message = .{
            .header = header,
            .account_keys = account_keys,
            .recent_blockhash = blockhash,
            .instructions = instructions,
        },
    };
}

pub fn free(self: Transaction, allocator: std.mem.Allocator) void {
    allocator.free(self.signatures);
    allocator.free(self.message.account_keys);
    for (self.message.instructions) |ix| {
        allocator.free(ix.accounts);
        allocator.free(ix.data);
    }
    allocator.free(self.message.instructions);
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "serialize minimal transaction (1 sig, 1 key, 0 instructions)" {
    const sig       = types.Signature{ .bytes = [_]u8{0} ** 64 };
    const key       = types.Pubkey{   .bytes = [_]u8{1} ** 32 };
    const blockhash = types.Hash{     .bytes = [_]u8{2} ** 32 };

    const tx = Transaction{
        .signatures = &[_]types.Signature{sig},
        .message = .{
            .header = .{
                .num_required_signatures      = 1,
                .num_readonly_signed_accounts   = 0,
                .num_readonly_unsigned_accounts = 0,
            },
            .account_keys    = &[_]types.Pubkey{key},
            .recent_blockhash = blockhash,
            .instructions    = &[_]CompiledInstruction{},
        },
    };

    var buf: [512]u8 = undefined;
    const len = try serialize(tx, &buf);

    // Byte-by-byte layout verification:
    //  0        compact-u16(1)  = 0x01
    //  1..64    64-byte zero signature
    //  65       num_required_signatures = 1
    //  66       num_readonly_signed     = 0
    //  67       num_readonly_unsigned   = 0
    //  68       compact-u16(1) account keys
    //  69..100  32-byte account key (all 0x01)
    //  101..132 32-byte blockhash (all 0x02)
    //  133      compact-u16(0) instructions
    //  total = 134 bytes

    try std.testing.expectEqual(@as(usize, 134), len);
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);   // 1 signature
    try std.testing.expectEqual(@as(u8, 0x00), buf[1]);   // sig byte 0
    try std.testing.expectEqual(@as(u8, 0x01), buf[65]);  // num_required_signatures
    try std.testing.expectEqual(@as(u8, 0x00), buf[66]);  // num_readonly_signed
    try std.testing.expectEqual(@as(u8, 0x00), buf[67]);  // num_readonly_unsigned
    try std.testing.expectEqual(@as(u8, 0x01), buf[68]);  // 1 account key
    try std.testing.expectEqual(@as(u8, 0x01), buf[69]);  // key[0] byte 0
    try std.testing.expectEqual(@as(u8, 0x02), buf[101]); // blockhash byte 0
    try std.testing.expectEqual(@as(u8, 0x00), buf[133]); // 0 instructions
}

test "serialize only message bytes" {
    const sig       = types.Signature{ .bytes = [_]u8{0} ** 64 };
    const key       = types.Pubkey{   .bytes = [_]u8{1} ** 32 };
    const blockhash = types.Hash{     .bytes = [_]u8{2} ** 32 };

    var tx = Transaction{
        .signatures = &[_]types.Signature{sig},
        .message = .{
            .header = .{
                .num_required_signatures      = 1,
                .num_readonly_signed_accounts   = 0,
                .num_readonly_unsigned_accounts = 0,
            },
            .account_keys    = &[_]types.Pubkey{key},
            .recent_blockhash = blockhash,
            .instructions    = &[_]CompiledInstruction{},
        },
    };

    var buf: [512]u8 = undefined;
    const msg = try tx.messageBytes(&buf);

    // Wire message prefix should exclude signatures and start at message header.
    // 0     num_required_signatures = 1
    // 1     num_readonly_signed     = 0
    // 2     num_readonly_unsigned   = 0
    // 3     compact-u16(1) account keys
    // 4..35 first pubkey bytes
    // 36..67 blockhash bytes
    // 68    compact-u16(0) instructions
    try std.testing.expectEqual(@as(usize, 69), msg.len);
    try std.testing.expectEqual(@as(u8, 0x01), msg[0]);
    try std.testing.expectEqual(@as(u8, 0x00), msg[1]);
    try std.testing.expectEqual(@as(u8, 0x00), msg[2]);
    try std.testing.expectEqual(@as(u8, 0x01), msg[3]);
    try std.testing.expectEqual(@as(u8, 0x01), msg[4]);
    try std.testing.expectEqual(@as(u8, 0x02), msg[36]);
    try std.testing.expectEqual(@as(u8, 0x00), msg[68]);
}

test "serialize transfer instruction" {
    const system_program = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    const sender   = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    const receiver = types.Pubkey{ .bytes = [_]u8{2} ** 32 };

    var ix_data: [12]u8 = undefined;
    std.mem.writeInt(u32, ix_data[0..4], 2, .little);             // transfer tag
    std.mem.writeInt(u64, ix_data[4..12], 500_000_000, .little);  // 0.5 SOL

    const ix = CompiledInstruction{
        .program_id_index = 2,
        .accounts = &[_]u8{ 0, 1 },
        .data = &ix_data,
    };

    const tx = Transaction{
        .signatures = &[_]types.Signature{.{ .bytes = [_]u8{0} ** 64 }},
        .message = .{
            .header = .{
                .num_required_signatures      = 1,
                .num_readonly_signed_accounts   = 0,
                .num_readonly_unsigned_accounts = 1,
            },
            .account_keys    = &[_]types.Pubkey{ sender, receiver, system_program },
            .recent_blockhash = types.Hash.ZERO,
            .instructions    = &[_]CompiledInstruction{ix},
        },
    };

    var buf: [512]u8 = undefined;
    const len = try serialize(tx, &buf);
    try std.testing.expect(len > 134); // larger than minimal due to instruction
}

test "deserialize round-trip transaction bytes" {
    const system_program = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    const sender = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    const receiver = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    const sig = types.Signature{ .bytes = [_]u8{4} ** 64 };
    var ix_data: [12]u8 = undefined;
    std.mem.writeInt(u32, ix_data[0..4], 2, .little);
    std.mem.writeInt(u64, ix_data[4..12], 50, .little);
    const ix = CompiledInstruction{
        .program_id_index = 2,
        .accounts = &[_]u8{0, 1},
        .data = &ix_data,
    };

    const tx = Transaction{
        .signatures = &[_]types.Signature{sig},
        .message = .{
            .header = .{
                .num_required_signatures = 1,
                .num_readonly_signed_accounts = 0,
                .num_readonly_unsigned_accounts = 1,
            },
            .account_keys = &[_]types.Pubkey{ sender, receiver, system_program },
            .recent_blockhash = types.Hash.ZERO,
            .instructions = &[_]CompiledInstruction{ix},
        },
    };

    var buf: [512]u8 = undefined;
    const n = try serialize(tx, &buf);
    const decoded = try deserialize(buf[0..n], std.testing.allocator);
    defer free(decoded, std.testing.allocator);

    try std.testing.expectEqual(tx.message.account_keys.len, decoded.message.account_keys.len);
    try std.testing.expectEqual(tx.message.instructions.len, decoded.message.instructions.len);
    try std.testing.expectEqual(tx.message.header.num_required_signatures, decoded.message.header.num_required_signatures);
}
