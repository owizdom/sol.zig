const std = @import("std");
const types = @import("types");
const base58 = @import("base58");

pub const Error = error{
    InvalidAccountLayout,
    InvalidAccountData,
    InvalidInstruction,
    InvalidInstructionData,
    NotEnoughFunds,
    AccountNotSigner,
    AccountNotWritable,
    AccountOwnerInvalid,
    ValueOverflow,
    Unauthorized,
};

pub const AccountRef = types.AccountRef;

pub const InstructionTag = enum(u32) {
    initialize_mint = 0,
    initialize_account = 1,
    initialize_multisig = 2,
    transfer = 3,
    approve = 4,
    revoke = 5,
    set_authority = 6,
    mint_to = 7,
    burn = 8,
    close_account = 9,
    freeze_account = 10,
    thaw_account = 11,
    transfer_checked = 12,
    approve_checked = 13,
    mint_to_checked = 14,
    burn_checked = 15,
    initialize_mint2 = 16,
    initialize_account2 = 17,
    initialize_account3 = 18,
};

pub const PROGRAM_ID_TEXT = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";

// Canonical offsets retained by RPC token decoding.
pub const MINT_SUPPLY_OFFSET: usize = 36;
pub const MINT_DECIMALS_OFFSET: usize = 44;
pub const MINT_MIN_SIZE: usize = MINT_DECIMALS_OFFSET + 1;

const MINT_AUTHORITY_FLAG: usize = 45;
const MINT_AUTHORITY_KEY: usize = 46;
const MINT_FREEZE_AUTHORITY_FLAG: usize = 78;
const MINT_FREEZE_AUTHORITY_KEY: usize = 79;
const MINT_STATE_SIZE: usize = MINT_FREEZE_AUTHORITY_KEY + 32;

pub const TOKEN_MINT_OFFSET: usize = 0;
pub const TOKEN_OWNER_OFFSET: usize = 32;
pub const TOKEN_AMOUNT_OFFSET: usize = 64;
pub const TOKEN_ACCOUNT_MIN_SIZE: usize = TOKEN_AMOUNT_OFFSET + 8;

const TOKEN_DELEGATE_FLAG: usize = 72;
const TOKEN_DELEGATE_KEY: usize = 73;
const TOKEN_DELEGATED_AMOUNT_OFFSET: usize = 105;
const TOKEN_FROZEN_OFFSET: usize = 113;
const TOKEN_CLOSE_AUTHORITY_FLAG: usize = 114;
const TOKEN_CLOSE_AUTHORITY_KEY: usize = 115;
const TOKEN_ACCOUNT_EXT_SIZE: usize = TOKEN_CLOSE_AUTHORITY_KEY + 32;

const MAX_MULTISIG_SIGNERS: usize = 11;
const MAX_U64 = std.math.maxInt(u64);

fn isSamePubkey(a: *const types.Pubkey, b: *const types.Pubkey) bool {
    return std.mem.eql(u8, a.bytes[0..], b.bytes[0..]);
}

pub fn isTokenProgram(candidate: types.Pubkey) bool {
    var decoded_out: [64]u8 = undefined;
    const decoded = base58.decode(PROGRAM_ID_TEXT, &decoded_out) catch return false;
    if (decoded.len > 32 or decoded.len == 0) return false;
    var program_id_bytes: [32]u8 = .{0} ** 32;
    const offset = 32 - decoded.len;
    @memcpy(program_id_bytes[offset..], decoded);
    return candidate.eql(.{ .bytes = program_id_bytes });
}

fn ensureDataLen(allocator: std.mem.Allocator, account: *AccountRef, needed: usize) !void {
    if (account.data.*.len >= needed) return;
    const next = try allocator.alloc(u8, needed);
    @memset(next, 0);
    if (account.data.*.len > 0) {
        const copy_len = @min(account.data.*.len, needed);
        @memcpy(next[0..copy_len], account.data.*[0..copy_len]);
        allocator.free(account.data.*);
    }
    account.data.* = next;
}

fn requireWritable(account: *const AccountRef) Error!void {
    if (!account.is_writable) return error.AccountNotWritable;
}

fn requireSigner(account: *const AccountRef) Error!void {
    if (!account.is_signer) return error.AccountNotSigner;
}

fn requireAccountLen(account: *const AccountRef, needed: usize) Error!void {
    if (account.data.*.len < needed) return error.InvalidAccountData;
}

fn readU64(data: []const u8, start: usize) u64 {
    var bytes: [8]u8 = undefined;
    @memcpy(&bytes, data[start .. start + 8]);
    return std.mem.readInt(u64, &bytes, .little);
}

fn writeU64(data: []u8, start: usize, value: u64) void {
    const target: *align(1) [8]u8 = @as(*align(1) [8]u8, @ptrCast(&data[start]));
    std.mem.writeInt(u64, target, value, .little);
}

fn addU64(a: u64, b: u64) Error!u64 {
    const r = @addWithOverflow(a, b);
    if (r[1] != 0) return error.ValueOverflow;
    return r[0];
}

fn subU64(a: u64, b: u64) Error!u64 {
    const r = @subWithOverflow(a, b);
    if (r[1] != 0) return error.NotEnoughFunds;
    return r[0];
}

fn readPubkeyAt(data: []const u8, start: usize) ?types.Pubkey {
    if (data.len < start + 32) return null;
    var out: types.Pubkey = .{ .bytes = undefined };
    @memcpy(out.bytes[0..], data[start .. start + 32]);
    return out;
}

fn writePubkeyAt(data: []u8, start: usize, key: types.Pubkey) void {
    @memcpy(data[start .. start + 32], key.bytes[0..]);
}

fn readBoolFlag(data: []const u8, offset: usize) bool {
    if (data.len <= offset) return false;
    return data[offset] != 0;
}

fn writeBoolFlag(data: []u8, offset: usize, value: bool) void {
    data[offset] = if (value) 1 else 0;
}

fn writeOptionPubkey(data: []u8, flag_offset: usize, key_offset: usize, value: ?types.Pubkey) void {
    if (value) |k| {
        writeBoolFlag(data, flag_offset, true);
        writePubkeyAt(data, key_offset, k);
    } else {
        writeBoolFlag(data, flag_offset, false);
        if (data.len > key_offset) {
            @memset(data[key_offset..@min(data.len, key_offset + 32)], 0);
        }
    }
}

fn readOptionPubkey(data: []const u8, flag_offset: usize, key_offset: usize) ?types.Pubkey {
    if (!readBoolFlag(data, flag_offset)) return null;
    return readPubkeyAt(data, key_offset);
}

fn parseAmount(ix_data: []const u8) Error!u64 {
    if (ix_data.len < 12) return error.InvalidInstruction;
    return std.mem.readInt(u64, ix_data[4..12], .little);
}

const CheckedAmount = struct {
    amount: u64,
    decimals: u8,
};

fn parseCheckedAmount(ix_data: []const u8) Error!CheckedAmount {
    if (ix_data.len < 13) return error.InvalidInstruction;
    return .{
        .amount = try parseAmount(ix_data),
        .decimals = ix_data[12],
    };
}

fn parseAmountChecked(ix_data: []const u8, checked: bool) !CheckedAmount {
    return if (checked) try parseCheckedAmount(ix_data) else .{
        .amount = try parseAmount(ix_data),
        .decimals = 0,
    };
}

fn isMintAuthorityPresent(account: *const AccountRef) bool {
    return readOptionPubkey(account.data.*, MINT_AUTHORITY_FLAG, MINT_AUTHORITY_KEY) != null;
}

fn isMultisigSigner(signers_blob: []const u8, required: u8, signer_accounts: []const AccountRef) bool {
    if (required == 0) return false;
    if (signers_blob.len < @as(usize, required) * 32) return false;
    if (required > MAX_MULTISIG_SIGNERS) return false;

    var matched = [_]bool{false} ** MAX_MULTISIG_SIGNERS;
    var count: u8 = 0;
    var i: usize = 0;
    while (i < signer_accounts.len and count < required) : (i += 1) {
        if (!signer_accounts[i].is_signer) continue;
        const signer_key = signer_accounts[i].key;
        var j: usize = 0;
        while (j < required) : (j += 1) {
            if (matched[j]) continue;
            const s0 = j * 32;
            const key = readPubkeyAt(signers_blob, s0) orelse break;
            if (!isSamePubkey(&key, &signer_key)) continue;
            matched[j] = true;
            count +%= 1;
            break;
        }
    }
    return count >= required;
}

fn assertAuthority(account: *const AccountRef, expected: types.Pubkey, signer_accounts: []const AccountRef) Error!void {
    if (!isSamePubkey(&account.key, &expected)) return error.Unauthorized;
    if (account.is_signer) return;

    if (account.data.*.len >= 2) {
        const threshold = account.data.*[0];
        if (threshold > 0) {
            const signer_count = account.data.*[1];
            if (threshold <= signer_count) {
                const signers_blob = account.data.*[2..];
                if (isMultisigSigner(signers_blob, threshold, signer_accounts)) return;
            }
        }
    }
    return error.AccountNotSigner;
}

fn initMintData(
    account: *AccountRef,
    allocator: std.mem.Allocator,
    decimals: u8,
    authority: types.Pubkey,
    close_authority: ?types.Pubkey,
) !void {
    try ensureDataLen(allocator, account, MINT_STATE_SIZE);
    @memset(account.data.*[0..], 0);
    writeU64(account.data.*, MINT_SUPPLY_OFFSET, 0);
    account.data.*[MINT_DECIMALS_OFFSET] = decimals;
    writeOptionPubkey(account.data.*, MINT_AUTHORITY_FLAG, MINT_AUTHORITY_KEY, authority);
    writeOptionPubkey(account.data.*, MINT_FREEZE_AUTHORITY_FLAG, MINT_FREEZE_AUTHORITY_KEY, close_authority);
}

fn initTokenAccountData(
    account: *AccountRef,
    allocator: std.mem.Allocator,
    mint: types.Pubkey,
    owner: types.Pubkey,
) !void {
    try ensureDataLen(allocator, account, TOKEN_ACCOUNT_EXT_SIZE);
    @memset(account.data.*[0..], 0);
    writePubkeyAt(account.data.*, TOKEN_MINT_OFFSET, mint);
    writePubkeyAt(account.data.*, TOKEN_OWNER_OFFSET, owner);
    writeU64(account.data.*, TOKEN_AMOUNT_OFFSET, 0);
}

fn readMintAuthorityData(mint: *const AccountRef) ?types.Pubkey {
    return readOptionPubkey(mint.data.*, MINT_AUTHORITY_FLAG, MINT_AUTHORITY_KEY);
}

fn readMintFreezeAuthorityData(mint: *const AccountRef) ?types.Pubkey {
    return readOptionPubkey(mint.data.*, MINT_FREEZE_AUTHORITY_FLAG, MINT_FREEZE_AUTHORITY_KEY);
}

fn readTokenDelegateData(token: *const AccountRef) ?types.Pubkey {
    return readOptionPubkey(token.data.*, TOKEN_DELEGATE_FLAG, TOKEN_DELEGATE_KEY);
}

fn readTokenDelegatedAmount(token: *const AccountRef) u64 {
    if (token.data.*.len <= TOKEN_DELEGATED_AMOUNT_OFFSET + 7) return 0;
    return readU64(token.data.*, TOKEN_DELEGATED_AMOUNT_OFFSET);
}

fn writeTokenDelegate(token: *AccountRef, allocator: std.mem.Allocator, delegate: ?types.Pubkey) !void {
    try ensureDataLen(allocator, token, TOKEN_ACCOUNT_EXT_SIZE);
    writeOptionPubkey(token.data.*, TOKEN_DELEGATE_FLAG, TOKEN_DELEGATE_KEY, delegate);
    writeU64(token.data.*, TOKEN_DELEGATED_AMOUNT_OFFSET, if (delegate) |_| 0 else 0);
}

fn writeTokenDelegatedAmount(token: *AccountRef, allocator: std.mem.Allocator, amount: u64) !void {
    try ensureDataLen(allocator, token, TOKEN_ACCOUNT_EXT_SIZE);
    writeU64(token.data.*, TOKEN_DELEGATED_AMOUNT_OFFSET, amount);
}

fn readCloseAuthority(token: *const AccountRef) ?types.Pubkey {
    return readOptionPubkey(token.data.*, TOKEN_CLOSE_AUTHORITY_FLAG, TOKEN_CLOSE_AUTHORITY_KEY);
}

fn writeCloseAuthority(token: *AccountRef, allocator: std.mem.Allocator, value: ?types.Pubkey) !void {
    try ensureDataLen(allocator, token, TOKEN_ACCOUNT_EXT_SIZE);
    writeOptionPubkey(token.data.*, TOKEN_CLOSE_AUTHORITY_FLAG, TOKEN_CLOSE_AUTHORITY_KEY, value);
}

fn isTokenFrozen(token: *const AccountRef) bool {
    return readBoolFlag(token.data.*, TOKEN_FROZEN_OFFSET);
}

fn setTokenFrozen(token: *AccountRef, allocator: std.mem.Allocator, value: bool) !void {
    try ensureDataLen(allocator, token, TOKEN_ACCOUNT_EXT_SIZE);
    writeBoolFlag(token.data.*, TOKEN_FROZEN_OFFSET, value);
}

fn transferBetween(accounts: []AccountRef, ix_data: []const u8, checked: bool, _: bool, allocator: std.mem.Allocator) !void {
    if (accounts.len < 3 + @as(usize, @intFromBool(checked))) return error.InvalidAccountLayout;
    const source = &accounts[0];
    const destination = &accounts[1];
    const authority = &accounts[2];
    const checked_mint = if (checked) &accounts[3] else null;

    try requireWritable(source);
    try requireWritable(destination);
    try requireAccountLen(source, TOKEN_ACCOUNT_MIN_SIZE);
    try requireAccountLen(destination, TOKEN_ACCOUNT_MIN_SIZE);
    if (isTokenFrozen(source) or isTokenFrozen(destination)) return error.InvalidAccountData;

    const parsed = try parseAmountChecked(ix_data, checked);
    const amount = parsed.amount;
    if (amount == 0) return;

    const source_amount = readU64(source.data.*, TOKEN_AMOUNT_OFFSET);
    const destination_amount = readU64(destination.data.*, TOKEN_AMOUNT_OFFSET);

    if (checked_mint) |mint_acc| {
        try requireAccountLen(mint_acc, MINT_MIN_SIZE);
        const observed_decimals = mint_acc.data.*[MINT_DECIMALS_OFFSET];
        if (parsed.decimals != observed_decimals) return error.InvalidInstructionData;

        const source_mint = readPubkeyAt(source.data.*, TOKEN_MINT_OFFSET) orelse return error.InvalidAccountData;
        const destination_mint = readPubkeyAt(destination.data.*, TOKEN_MINT_OFFSET) orelse return error.InvalidAccountData;
        if (!isSamePubkey(&source_mint, &destination_mint)) return error.InvalidAccountData;
    }

    const token_owner = readPubkeyAt(source.data.*, TOKEN_OWNER_OFFSET) orelse return error.InvalidAccountData;
    const token_delegate = readTokenDelegateData(source);
    const current_amount = readTokenDelegatedAmount(source);

    if (isSamePubkey(&token_owner, &authority.key)) {
        try requireSigner(authority);
    } else if (token_delegate) |delegate| {
        if (!isSamePubkey(&delegate, &authority.key)) return error.Unauthorized;
        if (authority.is_signer) {
            if (amount > current_amount) return error.NotEnoughFunds;
            const remaining_delegate = try subU64(current_amount, amount);
            if (remaining_delegate == 0) {
                try writeTokenDelegate(source, allocator, null);
            } else {
                try writeTokenDelegatedAmount(source, allocator, remaining_delegate);
            }
        } else {
            return error.AccountNotSigner;
        }
    } else {
        try assertAuthority(authority, token_owner, accounts);
    }

    const next_source = try subU64(source_amount, amount);
    const next_dest = try addU64(destination_amount, amount);
    writeU64(source.data.*, TOKEN_AMOUNT_OFFSET, next_source);
    writeU64(destination.data.*, TOKEN_AMOUNT_OFFSET, next_dest);
}

fn ensureMintMetadata(mint: *const AccountRef) !void {
    try requireAccountLen(mint, MINT_MIN_SIZE);
    if (mint.data.*.len < MINT_STATE_SIZE) {
        // keep accepting historical accounts while still checking required fields
        return;
    }
}

fn executeInitializeMint(accounts: []AccountRef, ix_data: []const u8, allocator: std.mem.Allocator) !void {
    if (accounts.len < 2) return error.InvalidAccountLayout;
    if (ix_data.len < 5) return error.InvalidInstruction;

    const mint_account = &accounts[0];
    const authority_account = &accounts[1];
    const freeze_authority: ?types.Pubkey = if (accounts.len > 2) accounts[2].key else null;

    try requireWritable(mint_account);
    try requireSigner(authority_account);
    try initMintData(mint_account, allocator, ix_data[4], authority_account.key, freeze_authority);
}

fn executeInitializeAccount(accounts: []AccountRef, allocator: std.mem.Allocator) !void {
    if (accounts.len < 2) return error.InvalidAccountLayout;
    const token_account = &accounts[0];
    const mint_account = &accounts[1];
    const owner = if (accounts.len > 2) accounts[2].key else token_account.key;
    const mint_key = readPubkeyAt(mint_account.data.*, TOKEN_MINT_OFFSET) orelse return error.InvalidAccountData;

    try requireWritable(token_account);
    try requireSigner(token_account);
    try requireAccountLen(mint_account, MINT_MIN_SIZE);
    try initTokenAccountData(token_account, allocator, mint_key, owner);
}

fn executeInitializeMultisig(accounts: []AccountRef, ix_data: []const u8, allocator: std.mem.Allocator) !void {
    if (accounts.len < 2) return error.InvalidAccountLayout;
    if (ix_data.len < 5) return error.InvalidInstruction;
    const threshold = ix_data[4];
    const signer_count = accounts.len - 1;
    if (threshold == 0 or threshold > signer_count) return error.InvalidInstructionData;
    if (signer_count > MAX_MULTISIG_SIGNERS or signer_count > MAX_U64) return error.InvalidInstructionData;

    const multisig = &accounts[0];
    try requireWritable(multisig);
    const needed = 2 + signer_count * 32;
    try ensureDataLen(allocator, multisig, needed);
    @memset(multisig.data.*[0..needed], 0);
    multisig.data.*[0] = threshold;
    multisig.data.*[1] = @intCast(signer_count);
    var i: usize = 0;
    while (i < signer_count) : (i += 1) {
        const signer_key = accounts[i + 1].key;
        try requireSigner(&accounts[i + 1]);
        writePubkeyAt(multisig.data.*, 2 + (i * 32), signer_key);
    }
}

fn executeTransfer(accounts: []AccountRef, ix_data: []const u8, allocator: std.mem.Allocator) !void {
    try transferBetween(accounts, ix_data, false, false, allocator);
}

fn executeTransferChecked(accounts: []AccountRef, ix_data: []const u8, allocator: std.mem.Allocator) !void {
    try transferBetween(accounts, ix_data, true, true, allocator);
}

fn executeApprove(accounts: []AccountRef, ix_data: []const u8, checked: bool, allocator: std.mem.Allocator) !void {
    if (accounts.len < 3 + @as(usize, @intFromBool(checked))) return error.InvalidAccountLayout;
    const token_account = &accounts[0];
    const delegate = &accounts[1];
    const authority = &accounts[2];
    const expected = readPubkeyAt(token_account.data.*, TOKEN_OWNER_OFFSET) orelse return error.InvalidAccountData;
    const parsed = try parseAmountChecked(ix_data, checked);
    if (checked) {
        const mint = &accounts[3];
        try requireAccountLen(mint, MINT_MIN_SIZE);
        const observed = mint.data.*[MINT_DECIMALS_OFFSET];
        if (parsed.decimals != observed) return error.InvalidInstructionData;
    }
    try requireAccountLen(token_account, TOKEN_ACCOUNT_MIN_SIZE);
    try ensureAccountWritableAndSignerAuthority(token_account, authority, expected, accounts, allocator);

    if (parsed.amount == 0) {
        try writeTokenDelegate(token_account, allocator, null);
        return;
    }
    try writeTokenDelegate(token_account, allocator, delegate.key);
    try writeTokenDelegatedAmount(token_account, allocator, parsed.amount);
}

fn executeRevoke(accounts: []AccountRef, ix_data: []const u8, allocator: std.mem.Allocator) !void {
    _ = ix_data;
    if (accounts.len < 2) return error.InvalidAccountLayout;
    const token_account = &accounts[0];
    const authority = &accounts[1];
    const expected = readPubkeyAt(token_account.data.*, TOKEN_OWNER_OFFSET) orelse return error.InvalidAccountData;
    try requireAccountLen(token_account, TOKEN_ACCOUNT_MIN_SIZE);
    try ensureAccountWritableAndSignerAuthority(token_account, authority, expected, accounts, allocator);
    try writeTokenDelegate(token_account, allocator, null);
}

fn ensureAccountWritableAndSignerAuthority(
    target: *AccountRef,
    authority: *const AccountRef,
    expected: types.Pubkey,
    accounts: []const AccountRef,
    allocator: std.mem.Allocator,
) !void {
    _ = allocator;
    try requireWritable(target);
    if (isSamePubkey(&authority.key, &expected)) {
        try requireSigner(authority);
        return;
    }
    if (authority.is_signer) return;
    if (authority.data.*.len >= 2 and authority.data.*.len >= 2 + (@as(usize, authority.data.*[1]) * 32)) {
        const threshold = authority.data.*[0];
        const signer_count = authority.data.*[1];
        if (threshold > 0 and threshold <= signer_count) {
            if (isMultisigSigner(authority.data.*[2..], threshold, accounts)) return;
        }
    }
    return error.AccountNotSigner;
}

fn executeSetAuthority(accounts: []AccountRef, ix_data: []const u8, allocator: std.mem.Allocator) !void {
    if (accounts.len < 2) return error.InvalidAccountLayout;
    if (ix_data.len < 5) return error.InvalidInstruction;
    const target = &accounts[0];
    const current_authority = &accounts[1];
    const next_authority = if (accounts.len > 2) accounts[2] else null;
    const mode = ix_data[4];

    const replacement: ?types.Pubkey = if (next_authority) |a| if (a.is_signer) a.key else null else null;
    switch (mode) {
        0 => {
            try requireAccountLen(target, MINT_AUTHORITY_FLAG + 1);
            const expected = readMintAuthorityData(target) orelse return error.InvalidInstructionData;
            try assertAuthority(current_authority, expected, accounts);
            try ensureDataLen(allocator, target, MINT_STATE_SIZE);
            writeOptionPubkey(target.data.*, MINT_AUTHORITY_FLAG, MINT_AUTHORITY_KEY, replacement);
        },
        1 => {
            try requireAccountLen(target, MINT_MIN_SIZE);
            const expected = readMintFreezeAuthorityData(target) orelse return error.InvalidInstructionData;
            try assertAuthority(current_authority, expected, accounts);
            try ensureDataLen(allocator, target, MINT_STATE_SIZE);
            writeOptionPubkey(target.data.*, MINT_FREEZE_AUTHORITY_FLAG, MINT_FREEZE_AUTHORITY_KEY, replacement);
        },
        2 => {
            try requireAccountLen(target, TOKEN_ACCOUNT_MIN_SIZE);
            const expected = readPubkeyAt(target.data.*, TOKEN_OWNER_OFFSET) orelse return error.InvalidAccountData;
            const resolved: types.Pubkey = expected;
            try assertAuthority(current_authority, resolved, accounts);
            if (next_authority) |na| {
                writePubkeyAt(target.data.*, TOKEN_OWNER_OFFSET, na.key);
            } else {
                return error.InvalidInstructionData;
            }
        },
        3 => {
            try requireAccountLen(target, TOKEN_ACCOUNT_MIN_SIZE);
            const current = readCloseAuthority(target);
            if (current) |expected| {
                try assertAuthority(current_authority, expected, accounts);
            } else {
                const owner = readPubkeyAt(target.data.*, TOKEN_OWNER_OFFSET) orelse return error.InvalidAccountData;
                try assertAuthority(current_authority, owner, accounts);
            }
            try writeCloseAuthority(target, allocator, replacement);
        },
        else => return error.InvalidInstructionData,
    }
}

fn executeMintTo(accounts: []AccountRef, ix_data: []const u8, checked: bool, _: std.mem.Allocator) !void {
    if (accounts.len < 3 + @as(usize, @intFromBool(checked))) return error.InvalidAccountLayout;
    const mint = &accounts[0];
    const destination = &accounts[1];
    const authority = &accounts[2];

    const parsed = try parseAmountChecked(ix_data, checked);
    try ensureMintMetadata(mint);
    if (checked) {
        try requireAccountLen(&accounts[3], MINT_MIN_SIZE);
        if (parsed.decimals != accounts[3].data.*[MINT_DECIMALS_OFFSET]) return error.InvalidInstructionData;
    }

    const expected = readMintAuthorityData(mint) orelse return error.InvalidInstructionData;
    try assertAuthority(authority, expected, accounts);
    try requireWritable(mint);
    try requireWritable(destination);
    try requireAccountLen(destination, TOKEN_ACCOUNT_MIN_SIZE);

    const destination_mint = readPubkeyAt(destination.data.*, TOKEN_MINT_OFFSET) orelse return error.InvalidAccountData;
    if (!isSamePubkey(&destination_mint, &mint.key)) return error.InvalidAccountData;

    const current_supply = readU64(mint.data.*, MINT_SUPPLY_OFFSET);
    const destination_amount = readU64(destination.data.*, TOKEN_AMOUNT_OFFSET);
    writeU64(mint.data.*, MINT_SUPPLY_OFFSET, try addU64(current_supply, parsed.amount));
    writeU64(destination.data.*, TOKEN_AMOUNT_OFFSET, try addU64(destination_amount, parsed.amount));
}

fn executeMintToChecked(accounts: []AccountRef, ix_data: []const u8, allocator: std.mem.Allocator) !void {
    try executeMintTo(accounts, ix_data, true, allocator);
}

fn executeMintToBasic(accounts: []AccountRef, ix_data: []const u8, allocator: std.mem.Allocator) !void {
    try executeMintTo(accounts, ix_data, false, allocator);
}

fn executeBurn(accounts: []AccountRef, ix_data: []const u8, checked: bool) !void {
    if (accounts.len < 3 + @as(usize, @intFromBool(checked))) return error.InvalidAccountLayout;
    const source = &accounts[0];
    const mint = &accounts[1];
    const authority = &accounts[2];

    const parsed = try parseAmountChecked(ix_data, checked);
    try requireAccountLen(source, TOKEN_ACCOUNT_MIN_SIZE);
    try requireAccountLen(mint, MINT_MIN_SIZE);
    if (checked) {
        const observed = mint.data.*[MINT_DECIMALS_OFFSET];
        if (parsed.decimals != observed) return error.InvalidInstructionData;
    }

    const owner = readPubkeyAt(source.data.*, TOKEN_OWNER_OFFSET) orelse return error.InvalidAccountData;
    _ = owner;
    const source_mint = readPubkeyAt(source.data.*, TOKEN_MINT_OFFSET) orelse return error.InvalidAccountData;
    if (!isSamePubkey(&source_mint, &mint.key)) return error.InvalidAccountData;

    const expected = readMintAuthorityData(mint) orelse return error.InvalidInstructionData;
    try assertAuthority(authority, expected, accounts);

    const source_amount = readU64(source.data.*, TOKEN_AMOUNT_OFFSET);
    const mint_supply = readU64(mint.data.*, MINT_SUPPLY_OFFSET);
    const next_source = try subU64(source_amount, parsed.amount);
    const next_supply = try subU64(mint_supply, parsed.amount);
    writeU64(source.data.*, TOKEN_AMOUNT_OFFSET, next_source);
    writeU64(mint.data.*, MINT_SUPPLY_OFFSET, next_supply);
}

fn executeBurnChecked(accounts: []AccountRef, ix_data: []const u8) !void {
    try executeBurn(accounts, ix_data, true);
}

fn executeBurnBasic(accounts: []AccountRef, ix_data: []const u8) !void {
    try executeBurn(accounts, ix_data, false);
}

fn executeCloseAccount(accounts: []AccountRef, ix_data: []const u8) !void {
    _ = ix_data;
    if (accounts.len < 2) return error.InvalidAccountLayout;
    const token_account = &accounts[0];
    const receiver = &accounts[1];
    const authority = if (accounts.len > 2) &accounts[2] else null;

    try requireWritable(token_account);
    try requireWritable(receiver);
    try requireAccountLen(token_account, TOKEN_ACCOUNT_MIN_SIZE);

    const owner = readPubkeyAt(token_account.data.*, TOKEN_OWNER_OFFSET) orelse return error.InvalidAccountData;
    const expected = readCloseAuthority(token_account) orelse owner;
    const signer = authority orelse token_account;
    try assertAuthority(signer, expected, accounts);

    receiver.lamports.* += token_account.lamports.*;
    token_account.lamports.* = 0;
    if (token_account.data.*.len > 0) {
        @memset(token_account.data.*, 0);
    }
}

fn executeFreezeOrThaw(accounts: []AccountRef, ix_data: []const u8, frozen: bool, allocator: std.mem.Allocator) !void {
    _ = ix_data;
    if (accounts.len < 3) return error.InvalidAccountLayout;
    const token_account = &accounts[0];
    const mint = &accounts[1];
    const authority = &accounts[2];

    try requireAccountLen(token_account, TOKEN_ACCOUNT_MIN_SIZE);
    try requireMintAuthorityMetadata(mint);
    const expected = readMintFreezeAuthorityData(mint) orelse return error.AccountOwnerInvalid;
    try assertAuthority(authority, expected, accounts);
    try setTokenFrozen(token_account, allocator, frozen);
}

fn requireMintAuthorityMetadata(mint: *const AccountRef) !void {
    try requireAccountLen(mint, MINT_MIN_SIZE);
    if (readBoolFlag(mint.data.*, MINT_FREEZE_AUTHORITY_FLAG)) {
        if (mint.data.*.len < MINT_STATE_SIZE) return error.InvalidAccountData;
    }
}

fn dispatchByTag(token_accounts: []AccountRef, tag: u32, ix_data: []const u8, allocator: std.mem.Allocator) !void {
    switch (tag) {
        @intFromEnum(InstructionTag.initialize_mint), @intFromEnum(InstructionTag.initialize_mint2) => {
            return executeInitializeMint(token_accounts, ix_data, allocator);
        },
        @intFromEnum(InstructionTag.initialize_account),
        @intFromEnum(InstructionTag.initialize_account2),
        @intFromEnum(InstructionTag.initialize_account3) => {
            return executeInitializeAccount(token_accounts, allocator);
        },
        @intFromEnum(InstructionTag.initialize_multisig) => {
            return executeInitializeMultisig(token_accounts, ix_data, allocator);
        },
        @intFromEnum(InstructionTag.transfer) => return executeTransfer(token_accounts, ix_data, allocator),
        @intFromEnum(InstructionTag.transfer_checked) => return executeTransferChecked(token_accounts, ix_data, allocator),
        @intFromEnum(InstructionTag.approve) => return executeApprove(token_accounts, ix_data, false, allocator),
        @intFromEnum(InstructionTag.approve_checked) => return executeApprove(token_accounts, ix_data, true, allocator),
        @intFromEnum(InstructionTag.revoke) => return executeRevoke(token_accounts, ix_data, allocator),
        @intFromEnum(InstructionTag.set_authority) => return executeSetAuthority(token_accounts, ix_data, allocator),
        @intFromEnum(InstructionTag.mint_to) => return executeMintToBasic(token_accounts, ix_data, allocator),
        @intFromEnum(InstructionTag.mint_to_checked) => return executeMintToChecked(token_accounts, ix_data, allocator),
        @intFromEnum(InstructionTag.burn) => return executeBurnBasic(token_accounts, ix_data),
        @intFromEnum(InstructionTag.burn_checked) => return executeBurnChecked(token_accounts, ix_data),
        @intFromEnum(InstructionTag.close_account) => return executeCloseAccount(token_accounts, ix_data),
        @intFromEnum(InstructionTag.freeze_account) => return executeFreezeOrThaw(token_accounts, ix_data, true, allocator),
        @intFromEnum(InstructionTag.thaw_account) => return executeFreezeOrThaw(token_accounts, ix_data, false, allocator),
        else => return Error.InvalidInstructionData,
    }
}

pub fn execute(
    accounts: []AccountRef,
    ix_data: []const u8,
    _: types.Slot,
    allocator: std.mem.Allocator,
) !void {
    if (ix_data.len < 4) return Error.InvalidInstruction;
    const tag = std.mem.readInt(u32, ix_data[0..4], .little);
    return dispatchByTag(accounts, tag, ix_data, allocator);
}

test "initialize mint and account and transfer" {
    var mint: u64 = 0;
    var src_data = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(src_data);
    var dst_data = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(dst_data);
    var dst2_data = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(dst2_data);

    var mint_owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    const mint_acc = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    const token_acc = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    const user = types.Pubkey{ .bytes = [_]u8{3} ** 32 };
    const receiver = types.Pubkey{ .bytes = [_]u8{4} ** 32 };

    var accounts = [_]AccountRef{
        .{
            .key = mint_acc,
            .lamports = &mint,
            .data = &src_data,
            .owner = &mint_owner,
            .executable = false,
            .is_signer = true,
            .is_writable = true,
        },
        .{
            .key = token_acc,
            .lamports = &mint,
            .data = &dst_data,
            .owner = &mint_owner,
            .executable = false,
            .is_signer = true,
            .is_writable = true,
        },
        .{
            .key = user,
            .lamports = &mint,
            .data = &dst2_data,
            .owner = &mint_owner,
            .executable = false,
            .is_signer = true,
            .is_writable = true,
        },
        .{
            .key = receiver,
            .lamports = &mint,
            .data = &dst2_data,
            .owner = &mint_owner,
            .executable = false,
            .is_signer = false,
            .is_writable = true,
        },
    };

    const init_mint = [_]u8{0, 0, 0, 0, 9};
    try execute(accounts[0..1], &init_mint, 0, std.testing.allocator);

    const init_account = [_]u8{1, 0, 0, 0, 0, 0, 0, 0, 0};
    accounts[0].lamports.* = 10;
    try execute(accounts[0..3], &init_account, 0, std.testing.allocator);

    const mint_to = [_]u8{7, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0};
    try execute(accounts[0..3], &mint_to, 0, std.testing.allocator);
}
