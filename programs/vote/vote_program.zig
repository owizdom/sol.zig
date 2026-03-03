const std = @import("std");
const types = @import("types");
const vote_mod = @import("consensus/vote");

pub const ID: types.Pubkey = .{ .bytes = [_]u8{1} ** 32 };

pub const AccountRef = types.AccountRef;

pub const Error = error{
    InvalidInstruction,
    InvalidData,
    InvalidAccountLayout,
    Unauthorized,
};

const VOTE_ACCOUNT_SIZE: usize = 200;
const VOTE_HEADER_SIZE: usize = 112;
const MAX_VOTES = vote_mod.MAX_LOCKOUT_HISTORY;

pub const InstructionTag = enum(u32) {
    InitializeAccount = 0,
    Vote = 1,
    Withdraw = 2,
    UpdateCommission = 3,
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

fn readInstructionTag(data: []const u8) !InstructionTag {
    if (data.len < 4) return error.InvalidInstruction;
    return @enumFromInt(readLE(u32, data, 0));
}

fn decodeHeader(data: []const u8) !void {
    if (data.len < VOTE_HEADER_SIZE) return error.InvalidAccountLayout;
    if (readLE(u32, data, 0) != 1) return error.InvalidData;
}

fn authorizedVoter(data: []const u8) types.Pubkey {
    return .{ .bytes = data[36..68].* };
}

fn authorizedWithdrawer(data: []const u8) types.Pubkey {
    return .{ .bytes = data[68..100].* };
}

fn encodeHeader(
    data: []u8,
    node_pk: types.Pubkey,
    auth_voter: types.Pubkey,
    auth_withdrawer: types.Pubkey,
    commission: u8,
) void {
    @memset(data[0..VOTE_ACCOUNT_SIZE], 0);

    writeLE(u32, data, 0, 1);
    @memcpy(data[4..36], &node_pk.bytes);
    @memcpy(data[36..68], &auth_voter.bytes);
    @memcpy(data[68..100], &auth_withdrawer.bytes);
    data[100] = commission;
}

fn readVoteStack(data: []const u8, out: *[MAX_VOTES]vote_mod.Lockout) !usize {
    const count = readLE(u16, data, 110);
    if (count > MAX_VOTES) return error.InvalidData;

    const payload = data[VOTE_HEADER_SIZE..];
    if (payload.len < count * 12) return error.InvalidData;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = i * 12;
        out[i] = .{
            .slot = readLE(u64, payload, off),
            .confirmation_count = readLE(u32, payload, off + 8),
        };
    }

    return count;
}

fn writeVoteStack(data: []u8, votes: []const vote_mod.Lockout, has_root: bool, root_slot: ?types.Slot) !void {
    writeLE(u16, data, 110, @intCast(votes.len));
    data[109] = if (has_root) 1 else 0;

    if (has_root) {
        const slot = root_slot orelse return error.InvalidData;
        writeLE(u64, data, 101, slot);
    } else {
        @memset(data[101..109], 0);
    }

    const payload = data[VOTE_HEADER_SIZE..];
    var i: usize = 0;
    while (i < votes.len) : (i += 1) {
        const off = i * 12;
        writeLE(u64, payload, off, votes[i].slot);
        writeLE(u32, payload, off + 8, votes[i].confirmation_count);
    }

    var clear_off = votes.len * 12;
    while (clear_off + VOTE_HEADER_SIZE < data.len) : (clear_off += 12) {
        @memset(payload[clear_off .. clear_off + 12], 0);
    }
}

pub fn execute(
    accounts: []AccountRef,
    ix_data: []const u8,
    _: types.Slot,
    _: types.Hash,
) Error!void {
    if (accounts.len < 1) return error.InvalidAccountLayout;
    if (!accounts[0].is_writable) return error.InvalidAccountLayout;

    const tag = try readInstructionTag(ix_data);
    switch (tag) {
        .InitializeAccount => {
            if (!accounts[0].is_signer) return error.Unauthorized;
            if (ix_data.len < 101) return error.InvalidInstruction;
            if (accounts[0].data.*.len < VOTE_ACCOUNT_SIZE) return error.InvalidAccountLayout;

            const node_pk = types.Pubkey{ .bytes = ix_data[4..36].* };
            const auth_voter = types.Pubkey{ .bytes = ix_data[36..68].* };
            const auth_withdrawer = types.Pubkey{ .bytes = ix_data[68..100].* };
            const commission = ix_data[100];

            encodeHeader(accounts[0].data.*, node_pk, auth_voter, auth_withdrawer, commission);
            try writeVoteStack(accounts[0].data.*, &.{}, false, null);
            std.mem.writeInt(u16, accounts[0].data.*[110..112], 0, .little);
        },
        .Vote => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (!accounts[1].is_signer) return error.Unauthorized;
            if (ix_data.len < 44) return error.InvalidInstruction;
            if (accounts[0].data.*.len < VOTE_ACCOUNT_SIZE) return error.InvalidAccountLayout;

            try decodeHeader(accounts[0].data.*);
            if (!accounts[1].key.eql(authorizedVoter(accounts[0].data.*))) return error.Unauthorized;

            const vote_slot = readLE(u64, ix_data, 4);
            const _hash: [32]u8 = ix_data[12..44].*;
            _ = _hash;

            var votes: [MAX_VOTES]vote_mod.Lockout = undefined;
            var vote_count = try readVoteStack(accounts[0].data.*, &votes);

            // Duplicate and lockout checks.
            for (votes[0..vote_count]) |vote| {
                if (vote.slot == vote_slot) return error.InvalidData;
            }
            while (vote_count > 0) {
                const oldest = votes[0];
                if (vote_slot <= oldest.slot + vote_mod.lockout_slots(oldest.confirmation_count)) break;

                var i: usize = 0;
                while (i + 1 < vote_count) : (i += 1) {
                    votes[i] = votes[i + 1];
                }
                vote_count -= 1;
            }

            for (votes[0..vote_count]) |*vote| {
                vote.confirmation_count +|= 1;
            }

            var has_root = accounts[0].data.*[109] != 0;
            var root_slot: ?types.Slot = null;
            if (vote_count > 0 and vote_count >= MAX_VOTES) {
                root_slot = votes[0].slot;
                has_root = true;

                var i: usize = 0;
                while (i + 1 < vote_count) : (i += 1) {
                    votes[i] = votes[i + 1];
                }
                vote_count -= 1;
            }

            votes[vote_count] = .{ .slot = vote_slot, .confirmation_count = 1 };
            vote_count += 1;

            try writeVoteStack(accounts[0].data.*, votes[0..vote_count], has_root, root_slot);
        },
        .Withdraw => {
            if (accounts.len < 3) return error.InvalidAccountLayout;
            if (!accounts[2].is_signer) return error.Unauthorized;
            if (!accounts[0].is_writable or !accounts[1].is_writable) return error.InvalidData;
            if (ix_data.len < 12) return error.InvalidInstruction;
            if (accounts[0].data.*.len < VOTE_HEADER_SIZE) return error.InvalidAccountLayout;

            if (!accounts[2].key.eql(authorizedWithdrawer(accounts[0].data.*))) return error.Unauthorized;

            const amount = readLE(u64, ix_data, 4);
            if (accounts[0].lamports.* < amount) return error.InvalidData;

            accounts[0].lamports.* -= amount;
            accounts[1].lamports.* += amount;
        },
        .UpdateCommission => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (!accounts[1].is_signer) return error.Unauthorized;
            if (ix_data.len < 5) return error.InvalidInstruction;
            if (accounts[0].data.*.len < VOTE_HEADER_SIZE) return error.InvalidAccountLayout;

            try decodeHeader(accounts[0].data.*);
            if (!accounts[1].key.eql(authorizedWithdrawer(accounts[0].data.*))) return error.Unauthorized;

            accounts[0].data.*[100] = ix_data[4];
        },
    }
}

test "initialize vote account writes expected header" {
    var owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.alloc(u8, VOTE_ACCOUNT_SIZE);
    defer std.testing.allocator.free(data);

    const vote_acct = AccountRef{
        .key = .{ .bytes = [_]u8{1} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };

    var init_ix: [101]u8 = undefined;
    std.mem.writeInt(u32, init_ix[0..4], @intFromEnum(InstructionTag.InitializeAccount), .little);
    const node = types.Pubkey{ .bytes = [_]u8{9} ** 32 };
    const voter = types.Pubkey{ .bytes = [_]u8{7} ** 32 };
    const withdrawer = types.Pubkey{ .bytes = [_]u8{8} ** 32 };
    @memcpy(init_ix[4..36], &node.bytes);
    @memcpy(init_ix[36..68], &voter.bytes);
    @memcpy(init_ix[68..100], &withdrawer.bytes);
    init_ix[100] = 10;

    try execute(&[_]AccountRef{vote_acct}, &init_ix, 0, types.Hash.ZERO);

    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, data[0..4], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, data[110..112], .little));
    try std.testing.expectEqual(@as(u8, 10), data[100]);
}

test "vote instruction increments confirmations in lockout stack" {
    var owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.alloc(u8, VOTE_ACCOUNT_SIZE);
    defer std.testing.allocator.free(data);

    const vote_acct = AccountRef{
        .key = .{ .bytes = [_]u8{1} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = true,
    };

    var init_ix: [101]u8 = undefined;
    std.mem.writeInt(u32, init_ix[0..4], @intFromEnum(InstructionTag.InitializeAccount), .little);
    const node = types.Pubkey{ .bytes = [_]u8{9} ** 32 };
    const voter = types.Pubkey{ .bytes = [_]u8{7} ** 32 };
    const withdrawer = types.Pubkey{ .bytes = [_]u8{8} ** 32 };
    @memcpy(init_ix[4..36], &node.bytes);
    @memcpy(init_ix[36..68], &voter.bytes);
    @memcpy(init_ix[68..100], &withdrawer.bytes);
    init_ix[100] = 10;

    try execute(&[_]AccountRef{vote_acct}, &init_ix, 0, types.Hash.ZERO);

    const voter_acct = AccountRef{
        .key = voter,
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };

    var vote_ix: [44]u8 = undefined;
    std.mem.writeInt(u32, vote_ix[0..4], @intFromEnum(InstructionTag.Vote), .little);
    std.mem.writeInt(u64, vote_ix[4..12], 10, .little);
    @memset(vote_ix[12..], 0);

    try execute(&[_]AccountRef{ vote_acct, voter_acct }, &vote_ix, 10, types.Hash.ZERO);

    std.mem.writeInt(u64, vote_ix[4..12], 20, .little);
    try execute(&[_]AccountRef{ vote_acct, voter_acct }, &vote_ix, 20, types.Hash.ZERO);

    const count = std.mem.readInt(u16, data[110..112], .little);
    try std.testing.expectEqual(@as(u16, 2), count);

    const first_slot = std.mem.readInt(u64, data[112..120], .little);
    const first_conf = std.mem.readInt(u32, data[120..124], .little);
    const second_conf = std.mem.readInt(u32, data[132..136], .little);

    try std.testing.expectEqual(@as(types.Slot, 10), first_slot);
    try std.testing.expectEqual(@as(u32, 2), first_conf);
    try std.testing.expectEqual(@as(u32, 1), second_conf);
}

test "vote update commission requires authorized withdrawer" {
    var owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.alloc(u8, VOTE_ACCOUNT_SIZE);
    defer std.testing.allocator.free(data);

    const vote_acct = AccountRef{
        .key = .{ .bytes = [_]u8{2} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };

    const voter = types.Pubkey{ .bytes = [_]u8{7} ** 32 };
    const withdrawer = types.Pubkey{ .bytes = [_]u8{8} ** 32 };

    var init_ix: [101]u8 = undefined;
    std.mem.writeInt(u32, init_ix[0..4], @intFromEnum(InstructionTag.InitializeAccount), .little);
    init_ix[4] = 0;
    @memset(init_ix[4..36], 0);

    const node = types.Pubkey{ .bytes = [_]u8{9} ** 32 };
    @memcpy(init_ix[4..36], &node.bytes);
    @memcpy(init_ix[36..68], &voter.bytes);
    @memcpy(init_ix[68..100], &withdrawer.bytes);
    init_ix[100] = 10;
    try execute(&[_]AccountRef{vote_acct}, &init_ix, 0, types.Hash.ZERO);

    const withdrawer_acct = AccountRef{
        .key = withdrawer,
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };

    var update_ix: [5]u8 = undefined;
    std.mem.writeInt(u32, update_ix[0..4], @intFromEnum(InstructionTag.UpdateCommission), .little);
    update_ix[4] = 42;

    try execute(&[_]AccountRef{ vote_acct, withdrawer_acct }, &update_ix, 0, types.Hash.ZERO);
    try std.testing.expectEqual(@as(u8, 42), data[100]);
}
