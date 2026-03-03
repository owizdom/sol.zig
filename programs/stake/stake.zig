const std = @import("std");
const types = @import("types");

/// Stake11111111111111111111111111111111111111111 (mainnet address)
pub const ID: types.Pubkey = .{
    .bytes = [_]u8{
        0x06, 0xa1, 0xd8, 0x17, 0x91, 0x37, 0x54, 0x2a,
        0x98, 0x34, 0x37, 0xbd, 0xfe, 0x2a, 0x7a, 0xb2,
        0x55, 0x7f, 0x53, 0x5c, 0x8a, 0x78, 0x72, 0x2b,
        0x68, 0xa4, 0x9d, 0xc0, 0x00, 0x00, 0x00, 0x00,
    },
};

pub const AccountRef = types.AccountRef;

pub const Error = error{
    InvalidInstruction,
    InvalidAccountLayout,
    InvalidAccountData,
    InvalidSigner,
    NotEnoughFunds,
    NotWritable,
    InvalidAccountOwner,
    StakeInvalidState,
    StakeLocked,
};

pub const StakeLifecycleState = enum(u32) {
    uninitialized = 0,
    inactive = 1,
    activating = 2,
    active = 3,
    deactivating = 4,
};

const STATE_INACTIVE = @intFromEnum(StakeLifecycleState.inactive);
const STATE_ACTIVATING = @intFromEnum(StakeLifecycleState.activating);
const STATE_ACTIVE = @intFromEnum(StakeLifecycleState.active);
const STATE_DEACTIVATING = @intFromEnum(StakeLifecycleState.deactivating);

pub const InstructionTag = enum(u32) {
    initialize = 0,
    delegate = 1,
    deactivate = 2,
    withdraw = 3,
    split = 4,
    merge = 5,
};

// Serialized layout (172 bytes):
//   state:                  u32     offset   0
//   authorized_staker:      [32]u8  offset   4
//   authorized_withdrawer:  [32]u8  offset  36
//   lockup_unix_timestamp:  u64     offset  68
//   lockup_epoch:           u64     offset  76
//   lockup_custodian:       [32]u8  offset  84
//   voter_pubkey:           [32]u8  offset 116
//   activation_epoch:       u64     offset 148
//   deactivation_epoch:     u64     offset 156
//   stake_lamports:         u64     offset 164
//   total: 172 bytes
pub const STAKE_ACCOUNT_BYTES = 172;

const StakeState = struct {
    state: u32,
    authorized_staker: types.Pubkey,
    authorized_withdrawer: types.Pubkey,
    lockup_unix_timestamp: u64,
    lockup_epoch: u64,
    lockup_custodian: types.Pubkey,
    voter_pubkey: types.Pubkey,
    activation_epoch: u64,
    deactivation_epoch: u64,
    stake_lamports: u64,
};

fn readLE(comptime T: type, raw: []const u8, start: usize) T {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    var bytes: [size]u8 = undefined;
    @memcpy(&bytes, raw[start .. start + size]);
    return std.mem.readInt(T, &bytes, .little);
}

fn writeLE(comptime T: type, raw: []u8, start: usize, value: T) void {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    var bytes: [size]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    @memcpy(raw[start .. start + size], &bytes);
}

fn loadStakeData(raw: []const u8) !StakeState {
    if (raw.len < STAKE_ACCOUNT_BYTES) return error.InvalidAccountData;
    var i: usize = 0;
    const state = readLE(u32, raw, i);
    i += 4;

    var staker: types.Pubkey = .{ .bytes = [_]u8{0} ** 32 };
    var withdrawer: types.Pubkey = .{ .bytes = [_]u8{0} ** 32 };
    var custodian: types.Pubkey = .{ .bytes = [_]u8{0} ** 32 };
    var voter: types.Pubkey = .{ .bytes = [_]u8{0} ** 32 };
    std.mem.copyForwards(u8, &staker.bytes, raw[i .. i + 32]);
    i += 32;
    std.mem.copyForwards(u8, &withdrawer.bytes, raw[i .. i + 32]);
    i += 32;
    const lockup_unix_timestamp = readLE(u64, raw, i);
    i += 8;
    const lockup_epoch = readLE(u64, raw, i);
    i += 8;
    std.mem.copyForwards(u8, &custodian.bytes, raw[i .. i + 32]);
    i += 32;
    std.mem.copyForwards(u8, &voter.bytes, raw[i .. i + 32]);
    i += 32;
    const activation_epoch = readLE(u64, raw, i);
    i += 8;
    const deactivation_epoch = readLE(u64, raw, i);
    i += 8;
    const stake_lamports = readLE(u64, raw, i);

    return .{
        .state = state,
        .authorized_staker = staker,
        .authorized_withdrawer = withdrawer,
        .lockup_unix_timestamp = lockup_unix_timestamp,
        .lockup_epoch = lockup_epoch,
        .lockup_custodian = custodian,
        .voter_pubkey = voter,
        .activation_epoch = activation_epoch,
        .deactivation_epoch = deactivation_epoch,
        .stake_lamports = stake_lamports,
    };
}

fn persistStakeData(raw: []u8, data: StakeState) !void {
    if (raw.len < STAKE_ACCOUNT_BYTES) return error.InvalidAccountData;
    var i: usize = 0;
    writeLE(u32, raw, i, data.state);
    i += 4;
    std.mem.copyForwards(u8, raw[i .. i + 32], &data.authorized_staker.bytes);
    i += 32;
    std.mem.copyForwards(u8, raw[i .. i + 32], &data.authorized_withdrawer.bytes);
    i += 32;
    writeLE(u64, raw, i, data.lockup_unix_timestamp);
    i += 8;
    writeLE(u64, raw, i, data.lockup_epoch);
    i += 8;
    std.mem.copyForwards(u8, raw[i .. i + 32], &data.lockup_custodian.bytes);
    i += 32;
    std.mem.copyForwards(u8, raw[i .. i + 32], &data.voter_pubkey.bytes);
    i += 32;
    writeLE(u64, raw, i, data.activation_epoch);
    i += 8;
    writeLE(u64, raw, i, data.deactivation_epoch);
    i += 8;
    writeLE(u64, raw, i, data.stake_lamports);
}

/// Apply activation/deactivation transitions when cluster epoch advances.
/// Returns true if account data changed and must be persisted.
pub fn applyEpochBoundaryTransitions(raw: []u8, epoch: types.Epoch) !bool {
    var state = try loadStakeData(raw);
    const before = state.state;

    if (state.state == STATE_ACTIVATING and epoch >= state.activation_epoch) {
        state.state = STATE_ACTIVE;
    }

    if (state.state == STATE_DEACTIVATING and epoch >= state.deactivation_epoch) {
        state.state = STATE_INACTIVE;
        state.deactivation_epoch = 0;
        state.voter_pubkey = .{ .bytes = [_]u8{0} ** 32 };
    }

    if (state.state != before) {
        try persistStakeData(raw, state);
        return true;
    }
    return false;
}

fn readTag(ix_data: []const u8) !InstructionTag {
    if (ix_data.len < 4) return error.InvalidInstruction;
    const raw = readLE(u32, ix_data, 0);
    return switch (raw) {
        0 => .initialize,
        1 => .delegate,
        2 => .deactivate,
        3 => .withdraw,
        4 => .split,
        5 => .merge,
        else => error.InvalidInstruction,
    };
}

/// Return true if any account in `accounts` is a signer with the given pubkey.
fn isSigning(accounts: []AccountRef, pubkey: types.Pubkey) bool {
    for (accounts) |acc| {
        if (acc.is_signer and std.mem.eql(u8, &acc.key.bytes, &pubkey.bytes)) return true;
    }
    return false;
}

pub fn execute(
    accounts: []AccountRef,
    ix_data: []const u8,
    epoch: types.Epoch,
    _: std.mem.Allocator,
) Error!void {
    if (accounts.len == 0) return error.InvalidInstruction;
    const tag = try readTag(ix_data);

    if (accounts[0].data.len < STAKE_ACCOUNT_BYTES) return error.InvalidAccountData;

    switch (tag) {
        .initialize => {
            const a = &accounts[0];
            if (!a.is_writable) return error.NotWritable;
            var state = try loadStakeData(a.data.*);
            state.state = STATE_INACTIVE;
            state.activation_epoch = 0;
            state.deactivation_epoch = 0;
            state.lockup_unix_timestamp = 0;
            state.lockup_epoch = 0;
            state.lockup_custodian = .{ .bytes = [_]u8{0} ** 32 };
            state.voter_pubkey = .{ .bytes = [_]u8{0} ** 32 };
            state.stake_lamports = a.lamports.*;
            // Authorized staker + withdrawer from ix_data[4..68] or default to account key.
            if (ix_data.len >= 68) {
                std.mem.copyForwards(u8, &state.authorized_staker.bytes, ix_data[4..36]);
                std.mem.copyForwards(u8, &state.authorized_withdrawer.bytes, ix_data[36..68]);
            } else {
                state.authorized_staker = a.key;
                state.authorized_withdrawer = a.key;
            }
            try persistStakeData(a.data.*, state);
        },
        .delegate => {
            const a = &accounts[0];
            if (!a.is_writable) return error.NotWritable;
            if (a.data.*.len < STAKE_ACCOUNT_BYTES) return error.InvalidAccountData;
            var state = try loadStakeData(a.data.*);
            if (state.state != STATE_INACTIVE) return error.StakeInvalidState;
            // Authority: caller must be the authorized staker.
            if (!a.is_signer) return error.InvalidSigner;
            if (!std.mem.eql(u8, &a.key.bytes, &state.authorized_staker.bytes)) return error.InvalidSigner;
            if (ix_data.len < 36) return error.InvalidInstruction;
            var voter: types.Pubkey = .{ .bytes = [_]u8{0} ** 32 };
            std.mem.copyForwards(u8, &voter.bytes, ix_data[4..36]);
            state.state = STATE_ACTIVATING;
            state.voter_pubkey = voter;
            state.activation_epoch = epoch + 1;
            state.deactivation_epoch = 0;
            try persistStakeData(a.data.*, state);
        },
        .deactivate => {
            const a = &accounts[0];
            if (!a.is_writable) return error.NotWritable;
            var state = try loadStakeData(a.data.*);
            if (state.state != STATE_ACTIVE) return error.StakeInvalidState;
            // Authority: caller must be the authorized staker.
            if (!a.is_signer) return error.InvalidSigner;
            if (!std.mem.eql(u8, &a.key.bytes, &state.authorized_staker.bytes)) return error.InvalidSigner;
            state.state = STATE_DEACTIVATING;
            state.deactivation_epoch = epoch + 1;
            try persistStakeData(a.data.*, state);
        },
        .withdraw => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            const source = &accounts[0];
            const destination = &accounts[1];
            if (!source.is_writable or !destination.is_writable) return error.NotWritable;
            if (ix_data.len < 12) return error.InvalidInstruction;
            const lamports = readLE(u64, ix_data, 4);
            var state = try loadStakeData(source.data.*);
            // Authority: caller must be the authorized withdrawer.
            if (!source.is_signer) return error.InvalidSigner;
            if (!std.mem.eql(u8, &source.key.bytes, &state.authorized_withdrawer.bytes)) return error.InvalidSigner;
            // Lockup: if within lockup window, only the custodian can withdraw.
            if (state.lockup_epoch > 0 and epoch < state.lockup_epoch) {
                if (!isSigning(accounts, state.lockup_custodian)) return error.StakeLocked;
            }
            if (source.lamports.* < lamports) return error.NotEnoughFunds;
            source.lamports.* -= lamports;
            destination.lamports.* += lamports;
            state.stake_lamports = source.lamports.*;
            try persistStakeData(source.data.*, state);
            if (destination.data.*.len >= STAKE_ACCOUNT_BYTES) {
                var d = loadStakeData(destination.data.*) catch return;
                d.stake_lamports = destination.lamports.*;
                persistStakeData(destination.data.*, d) catch {};
            }
        },
        .split => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            const source = &accounts[0];
            const dest = &accounts[1];
            if (ix_data.len < 12) return error.InvalidInstruction;
            if (!source.is_writable or !dest.is_writable) return error.NotWritable;
            // Authority: caller must be the authorized staker.
            if (!source.is_signer) return error.InvalidSigner;
            var src_state = try loadStakeData(source.data.*);
            if (!std.mem.eql(u8, &source.key.bytes, &src_state.authorized_staker.bytes)) return error.InvalidSigner;
            const amount = readLE(u64, ix_data, 4);
            if (source.lamports.* < amount) return error.NotEnoughFunds;
            source.lamports.* -= amount;
            dest.lamports.* += amount;
            // Copy full StakeState to destination with split lamports.
            if (dest.data.*.len >= STAKE_ACCOUNT_BYTES) {
                var dest_state = src_state;
                dest_state.stake_lamports = amount;
                try persistStakeData(dest.data.*, dest_state);
            }
            // Update source.
            src_state.stake_lamports = source.lamports.*;
            try persistStakeData(source.data.*, src_state);
        },
        .merge => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            const source = &accounts[0];
            const dest = &accounts[1];
            if (!source.is_writable or !dest.is_writable) return error.NotWritable;
            if (ix_data.len < 4) return error.InvalidInstruction;
            dest.lamports.* += source.lamports.*;
            source.lamports.* = 0;
            var d = try loadStakeData(dest.data.*);
            d.stake_lamports = dest.lamports.*;
            try persistStakeData(dest.data.*, d);
            var s = try loadStakeData(source.data.*);
            s.stake_lamports = 0;
            s.state = STATE_INACTIVE;
            try persistStakeData(source.data.*, s);
        },
    }
}

test "stake initialize sets authority to account key when ix_data is short" {
    var data: [STAKE_ACCOUNT_BYTES]u8 = std.mem.zeroes([STAKE_ACCOUNT_BYTES]u8);
    var data_slice: []u8 = &data;
    const kp = types.Pubkey{ .bytes = [_]u8{9} ** 32 };
    const owner = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    var lamports: u64 = 1_000_000;
    const ref = AccountRef{
        .key = kp,
        .lamports = &lamports,
        .data = &data_slice,
        .owner = @constCast(&owner),
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };
    // 36-byte initialize ix: tag=0 (4 bytes) + 32 zeros
    const init_data = [_]u8{0} ** 36;
    try execute(@constCast(&[_]AccountRef{ref}), &init_data, 0, std.testing.allocator);
    const state = try loadStakeData(data[0..]);
    try std.testing.expectEqual(@as(u32, STATE_INACTIVE), state.state);
    try std.testing.expect(std.mem.eql(u8, &state.authorized_staker.bytes, &kp.bytes));
    try std.testing.expect(std.mem.eql(u8, &state.authorized_withdrawer.bytes, &kp.bytes));
}

test "stake delegate requires authorized staker" {
    var data: [STAKE_ACCOUNT_BYTES]u8 = std.mem.zeroes([STAKE_ACCOUNT_BYTES]u8);
    var data_slice: []u8 = &data;
    const kp = types.Pubkey{ .bytes = [_]u8{9} ** 32 };
    const owner = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    var lamports: u64 = 1_000_000;
    const ref = AccountRef{
        .key = kp,
        .lamports = &lamports,
        .data = &data_slice,
        .owner = @constCast(&owner),
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };

    // Initialize first
    const init_data = [_]u8{0} ** 36;
    try execute(@constCast(&[_]AccountRef{ref}), &init_data, 0, std.testing.allocator);

    // Delegate: ix = tag(1) + voter(32 bytes)
    var del_data: [36]u8 = [_]u8{0} ** 36;
    std.mem.writeInt(u32, del_data[0..4], 1, .little);
    @memset(del_data[4..36], 0xAB); // voter pubkey
    try execute(@constCast(&[_]AccountRef{ref}), &del_data, 0, std.testing.allocator);

    const state = try loadStakeData(data[0..]);
    try std.testing.expectEqual(@as(u32, STATE_ACTIVATING), state.state);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xAB} ** 32, &state.voter_pubkey.bytes);
}

test "stake withdraw lockup blocks withdrawal before epoch" {
    var data: [STAKE_ACCOUNT_BYTES]u8 = std.mem.zeroes([STAKE_ACCOUNT_BYTES]u8);
    var data_slice: []u8 = &data;
    const staker = types.Pubkey{ .bytes = [_]u8{0x01} ** 32 };
    const owner = types.Pubkey{ .bytes = [_]u8{0x00} ** 32 };
    var src_lamps: u64 = 1_000_000;
    var dst_lamps: u64 = 0;
    var dst_data: [STAKE_ACCOUNT_BYTES]u8 = std.mem.zeroes([STAKE_ACCOUNT_BYTES]u8);
    var dst_data_slice: []u8 = &dst_data;

    const state = StakeState{
        .state = STATE_INACTIVE,
        .authorized_staker = staker,
        .authorized_withdrawer = staker,
        .lockup_unix_timestamp = 0,
        .lockup_epoch = 10, // locked until epoch 10
        .lockup_custodian = .{ .bytes = [_]u8{0xFF} ** 32 },
        .voter_pubkey = .{ .bytes = [_]u8{0} ** 32 },
        .activation_epoch = 0,
        .deactivation_epoch = 0,
        .stake_lamports = 1_000_000,
    };
    try persistStakeData(&data, state);

    const src_ref = AccountRef{
        .key = staker,
        .lamports = &src_lamps,
        .data = &data_slice,
        .owner = @constCast(&owner),
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };
    const dst_ref = AccountRef{
        .key = .{ .bytes = [_]u8{0x02} ** 32 },
        .lamports = &dst_lamps,
        .data = &dst_data_slice,
        .owner = @constCast(&owner),
        .executable = false,
        .is_signer = false,
        .is_writable = true,
    };

    // Withdraw 100 before lockup ends (epoch 5 < lockup_epoch 10) → StakeLocked
    var wd_data: [12]u8 = undefined;
    std.mem.writeInt(u32, wd_data[0..4], 3, .little);
    std.mem.writeInt(u64, wd_data[4..12], 100, .little);
    const err = execute(@constCast(&[_]AccountRef{ src_ref, dst_ref }), &wd_data, 5, std.testing.allocator);
    try std.testing.expectError(error.StakeLocked, err);

    // Epoch 10 (== lockup_epoch): withdraw should succeed
    try execute(@constCast(&[_]AccountRef{ src_ref, dst_ref }), &wd_data, 10, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1_000_000 - 100), src_lamps);
    try std.testing.expectEqual(@as(u64, 100), dst_lamps);
}
