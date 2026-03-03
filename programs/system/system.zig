const std = @import("std");
const types = @import("types");

/// The System Program lives at the all-zero pubkey in this implementation.
pub const ID: types.Pubkey = .{ .bytes = [_]u8{0} ** 32 };

pub const AccountRef = types.AccountRef;

pub const Error = error{
    InvalidInstruction,
    InvalidAccountLayout,
    NotEnoughFunds,
    AccountNotWritable,
    AccountNotSigner,
};

/// System instruction discriminants.
pub const InstructionTag = enum(u32) {
    create_account = 0,
    assign = 1,
    transfer = 2,
    create_account_with_seed = 3,
    advance_nonce_account = 4,
    withdraw_nonce_account = 5,
    initialize_nonce_account = 6,
    authorize_nonce_account = 7,
    allocate = 8,
    allocate_with_seed = 9,
    assign_with_seed = 10,
    transfer_with_seed = 11,
    upgrade_nonce_account = 12,
};

fn readInstructionTag(data: []const u8) !InstructionTag {
    if (data.len < 4) return error.InvalidInstruction;
    const tag = std.mem.readInt(u32, data[0..4], .little);
    return @enumFromInt(tag);
}

fn readCreateAccount(data: []const u8) !struct {
    lamports: u64,
    space: u64,
    owner: types.Pubkey,
} {
    if (data.len < 52) return error.InvalidInstruction;
    return .{
        .lamports = std.mem.readInt(u64, data[4..12], .little),
        .space = std.mem.readInt(u64, data[12..20], .little),
        .owner = .{ .bytes = data[20..52].* },
    };
}

fn readCreateAccountWithSeed(data: []const u8) !struct {
    lamports: u64,
    space: u64,
    owner: types.Pubkey,
} {
    if (data.len < 56) return error.InvalidInstruction;
    const seed_len = std.mem.readInt(u32, data[52..56], .little);
    const seed_end = 56 + @as(usize, seed_len);
    if (seed_end + 32 > data.len) return error.InvalidInstruction;
    return .{
        .lamports = std.mem.readInt(u64, data[4..12], .little),
        .space = std.mem.readInt(u64, data[12..20], .little),
        .owner = .{ .bytes = data[seed_end..][0..32].* },
    };
}

fn readAllocateWithSeed(data: []const u8) !struct {
    space: u64,
    owner: types.Pubkey,
} {
    if (data.len < 40) return error.InvalidInstruction;

    const seed_len = std.mem.readInt(u32, data[32..36], .little);
    const space_off = 36 + @as(usize, seed_len);
    const owner_off = space_off + 8;
    if (owner_off + 32 > data.len) return error.InvalidInstruction;

    var space_bytes: [8]u8 = undefined;
    @memcpy(&space_bytes, data[space_off .. space_off + 8]);

    return .{
        .space = std.mem.readInt(u64, &space_bytes, .little),
        .owner = .{ .bytes = data[owner_off..][0..32].* },
    };
}

fn readAssignWithSeed(data: []const u8) !types.Pubkey {
    if (data.len < 36) return error.InvalidInstruction;
    const seed_len = std.mem.readInt(u32, data[32..36], .little);
    const end = 36 + @as(usize, seed_len) + 32;
    if (data.len < end) return error.InvalidInstruction;
    return .{ .bytes = data[end - 32 ..][0..32].* };
}

fn reallocZeroed(allocator: std.mem.Allocator, account: *AccountRef, new_len: usize) !void {
    if (account.data.*.len > 0) allocator.free(account.data.*);
    const next = try allocator.alloc(u8, new_len);
    @memset(next, 0);
    account.data.* = next;
}

pub fn execute(
    accounts: []AccountRef,
    ix_data: []const u8,
    recent_bh: types.Hash,
    allocator: std.mem.Allocator,
) !void {
    if (accounts.len < 1) return error.InvalidAccountLayout;

    const tag = try readInstructionTag(ix_data);
    switch (tag) {
        .create_account => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (!accounts[0].is_signer or !accounts[1].is_signer) return error.AccountNotSigner;
            if (!accounts[0].is_writable or !accounts[1].is_writable) return error.AccountNotWritable;

            const parsed = try readCreateAccount(ix_data);
            if (accounts[1].data.*.len != 0) return error.InvalidAccountLayout;
            if (accounts[0].lamports.* < parsed.lamports) return error.NotEnoughFunds;

            accounts[0].lamports.* -= parsed.lamports;
            accounts[1].lamports.* += parsed.lamports;

            try reallocZeroed(allocator, &accounts[1], @intCast(parsed.space));
            accounts[1].owner.* = parsed.owner;
        },
        .assign => {
            if (accounts.len < 1) return error.InvalidAccountLayout;
            if (!accounts[0].is_signer) return error.AccountNotSigner;
            if (!accounts[0].is_writable) return error.AccountNotWritable;
            if (ix_data.len < 36) return error.InvalidInstruction;

            accounts[0].owner.* = .{ .bytes = ix_data[4..36].* };
        },
        .transfer => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (!accounts[0].is_writable or !accounts[1].is_writable) return error.AccountNotWritable;
            if (ix_data.len < 12) return error.InvalidInstruction;

            const amount = std.mem.readInt(u64, ix_data[4..12], .little);
            if (accounts[0].lamports.* < amount) return error.NotEnoughFunds;

            accounts[0].lamports.* -= amount;
            accounts[1].lamports.* = accounts[1].lamports.* +| amount;
        },
        .create_account_with_seed => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (!accounts[0].is_signer) return error.AccountNotSigner;
            if (!accounts[1].is_writable) return error.AccountNotWritable;

            const parsed = try readCreateAccountWithSeed(ix_data);
            if (accounts[0].lamports.* < parsed.lamports) return error.NotEnoughFunds;

            accounts[0].lamports.* -= parsed.lamports;
            accounts[1].lamports.* += parsed.lamports;
            try reallocZeroed(allocator, &accounts[1], @intCast(parsed.space));
            accounts[1].owner.* = parsed.owner;
        },
        .advance_nonce_account => {
            if (!accounts[0].is_writable) return error.AccountNotWritable;
            if (accounts[0].data.*.len < 68) return error.InvalidAccountLayout;
            std.mem.copyForwards(u8, accounts[0].data.*[36..68], &recent_bh.bytes);
        },
        .withdraw_nonce_account => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (!accounts[0].is_writable or !accounts[1].is_writable) return error.AccountNotWritable;
            if (ix_data.len < 12) return error.InvalidInstruction;

            const amount = std.mem.readInt(u64, ix_data[4..12], .little);
            if (accounts[0].lamports.* < amount) return error.NotEnoughFunds;

            accounts[0].lamports.* -= amount;
            accounts[1].lamports.* += amount;
        },
        .initialize_nonce_account => {
            if (!accounts[0].is_writable) return error.AccountNotWritable;
            if (accounts[0].data.*.len < 76) {
                try reallocZeroed(allocator, &accounts[0], 76);
            }
            @memset(accounts[0].data.*[0..76], 0);
            std.mem.writeInt(u32, accounts[0].data.*[0..4], 0, .little);
        },
        .authorize_nonce_account => {
            if (!accounts[0].is_writable) return error.AccountNotWritable;
            if (ix_data.len < 36) return error.InvalidInstruction;
            if (accounts[0].data.*.len < 36) return error.InvalidAccountLayout;

            @memcpy(accounts[0].data.*[4..36], ix_data[4..36]);
        },
        .allocate => {
            if (!accounts[0].is_signer) return error.AccountNotSigner;
            if (!accounts[0].is_writable) return error.AccountNotWritable;
            if (ix_data.len < 12) return error.InvalidInstruction;

            const space = std.mem.readInt(u64, ix_data[4..12], .little);
            try reallocZeroed(allocator, &accounts[0], @intCast(space));
        },
        .allocate_with_seed => {
            if (!accounts[0].is_signer) return error.AccountNotSigner;
            if (!accounts[0].is_writable) return error.AccountNotWritable;

            const parsed = try readAllocateWithSeed(ix_data);
            try reallocZeroed(allocator, &accounts[0], @intCast(parsed.space));
            accounts[0].owner.* = parsed.owner;
        },
        .assign_with_seed => {
            if (!accounts[0].is_signer) return error.AccountNotSigner;
            if (!accounts[0].is_writable) return error.AccountNotWritable;

            accounts[0].owner.* = try readAssignWithSeed(ix_data);
        },
        .transfer_with_seed => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (!accounts[0].is_writable or !accounts[1].is_writable) return error.AccountNotWritable;
            if (ix_data.len < 12) return error.InvalidInstruction;

            const amount = std.mem.readInt(u64, ix_data[4..12], .little);
            if (accounts[0].lamports.* < amount) return error.NotEnoughFunds;

            accounts[0].lamports.* -= amount;
            accounts[1].lamports.* = accounts[1].lamports.* +| amount;
        },
        .upgrade_nonce_account => {
            if (!accounts[0].is_writable) return error.AccountNotWritable;
            if (accounts[0].data.*.len < 4) return error.InvalidAccountLayout;
            if (std.mem.readInt(u32, accounts[0].data.*[0..4], .little) != 1) return error.InvalidInstruction;
        },
    }
}

/// Encode a transfer instruction into a 12-byte payload.
pub fn encodeTransfer(lamports: u64, buf: *[12]u8) void {
    std.mem.writeInt(u32, buf[0..4], @intFromEnum(InstructionTag.transfer), .little);
    std.mem.writeInt(u64, buf[4..12], lamports, .little);
}

/// Encode a CreateAccount instruction into a 52-byte payload.
pub fn encodeCreateAccount(lamports: u64, space: u64, owner: types.Pubkey, buf: *[52]u8) void {
    std.mem.writeInt(u32, buf[0..4], @intFromEnum(InstructionTag.create_account), .little);
    std.mem.writeInt(u64, buf[4..12], lamports, .little);
    std.mem.writeInt(u64, buf[12..20], space, .little);
    @memcpy(buf[20..52], &owner.bytes);
}

fn allocateBuf(allocator: std.mem.Allocator, count: usize) ![]u8 {
    return try allocator.alloc(u8, count);
}

test "system program is available" {
    try std.testing.expectEqual(@as(u8, 0), ID.bytes[0]);
}

test "system create account allocates zeroed data" {
    var payer: u64 = 10;
    var acct2: u64 = 0;
    var payer_owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    var acct_owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };

    var new_data = try allocateBuf(std.testing.allocator, 0);
    defer std.testing.allocator.free(new_data);
    var payer_data = try allocateBuf(std.testing.allocator, 0);
    defer std.testing.allocator.free(payer_data);
    var refs = [_]AccountRef{
        .{ .key = .{ .bytes = [_]u8{1} ** 32 }, .lamports = &payer, .data = &payer_data, .owner = &payer_owner, .executable = false, .is_signer = true, .is_writable = true },
        .{ .key = .{ .bytes = [_]u8{2} ** 32 }, .lamports = &acct2, .data = &new_data, .owner = &acct_owner, .executable = false, .is_signer = true, .is_writable = true },
    };

    var buf: [52]u8 = undefined;
    const new_owner = types.Pubkey{ .bytes = [_]u8{3} ** 32 };
    encodeCreateAccount(4, 8, new_owner, &buf);
    try execute(&refs, buf[0..], .{ .bytes = [_]u8{0} ** 32 }, std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 6), refs[0].lamports.*);
    try std.testing.expectEqual(@as(u64, 4), refs[1].lamports.*);
    try std.testing.expectEqual(@as(usize, 8), refs[1].data.*.len);
    try std.testing.expectEqual(@as(u8, 0), refs[1].data.*[0]);
}

test "system assign requires signer" {
    var lamports: u64 = 4;
    var owner = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    var data = try allocateBuf(std.testing.allocator, 4);
    defer std.testing.allocator.free(data);

    var ref = AccountRef{
        .key = .{ .bytes = [_]u8{7} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = true,
    };

    var buf: [36]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], @intFromEnum(InstructionTag.assign), .little);
    const new_owner = types.Pubkey{ .bytes = [_]u8{9} ** 32 };
    @memcpy(buf[4..36], &new_owner.bytes);

    try std.testing.expectError(error.AccountNotSigner, execute(&[_]AccountRef{ref}, &buf, .{ .bytes = [_]u8{0} ** 32 }, std.testing.allocator));

    ref.is_signer = true;
    try execute(&[_]AccountRef{ref}, buf[0..], .{ .bytes = [_]u8{0} ** 32 }, std.testing.allocator);
    try std.testing.expect(ref.owner.eql(new_owner));
}

test "system allocate resizes with zero-fill" {
    var lamports: u64 = 0;
    var owner = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    var data = try allocateBuf(std.testing.allocator, 8);
    defer std.testing.allocator.free(data);
    @memset(data[0..], 0xAA);

    const ref = AccountRef{
        .key = .{ .bytes = [_]u8{2} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };

    var buf: [12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], @intFromEnum(InstructionTag.allocate), .little);
    std.mem.writeInt(u64, buf[4..12], 11, .little);

    try execute(&[_]AccountRef{ref}, &buf, .{ .bytes = [_]u8{0} ** 32 }, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 11), ref.data.*.len);
    for (ref.data.*) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
