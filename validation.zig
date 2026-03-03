const std = @import("std");
const token = @import("programs/token");
const bpf_loader = @import("programs/bpf_loader");
const types = @import("types");

const BpfProgram = bpf_loader.AccountRef;
const TokenAccount = token.AccountRef;

fn makePubkey(byte: u8) types.Pubkey {
    return .{ .bytes = [_]u8{byte} ** 32 };
}

fn buildAccount(
    key: types.Pubkey,
    lamports: *u64,
    owner: *types.Pubkey,
    data: *[]u8,
    signer: bool,
    writable: bool,
) BpfProgram {
    return .{
        .key = key,
        .lamports = lamports,
        .data = data,
        .owner = owner,
        .executable = false,
        .is_signer = signer,
        .is_writable = writable,
    };
}

fn buildExecutableProgram(
    key: types.Pubkey,
    lamports: *u64,
    owner: *types.Pubkey,
    data: *[]u8,
    signer: bool,
    writable: bool,
) BpfProgram {
    var account = buildAccount(key, lamports, owner, data, signer, writable);
    account.executable = true;
    return account;
}

fn makeUnknownHelperProgram(helper_id: u64) [24]u8 {
    const magic = [_]u8{ 'S', 'B', 'F', '1' };
    var code = [_]u8{0} ** 24;
    std.mem.copyForwards(u8, code[0..4], &magic);

    var off: usize = 4;
    code[off + 0] = 0x85;
    code[off + 1] = 0x00;
    std.mem.writeInt(i16, code[off + 2 .. off + 4], 0, .little);
    std.mem.writeInt(i32, code[off + 4 .. off + 8], @intCast(helper_id), .little);
    off += 8;

    code[off + 0] = 0x95;
    code[off + 1] = 0x00;
    std.mem.writeInt(i16, code[off + 2 .. off + 4], 0, .little);
    std.mem.writeInt(i32, code[off + 4 .. off + 8], 0, .little);

    return code;
}

fn readAmountFromTokenAccount(account: *TokenAccount) u64 {
    if (account.data.*.len < 72) return 0;
    return std.mem.readInt(u64, account.data.*[64..72], .little);
}

fn newTokenAccount(
    key: types.Pubkey,
    lamports: *u64,
    owner: *types.Pubkey,
    signer: bool,
    writable: bool,
    allocator: std.mem.Allocator,
) !TokenAccount {
    var account_data = try allocator.alloc(u8, 0);
    return .{
        .key = key,
        .lamports = lamports,
        .data = &account_data,
        .owner = owner,
        .executable = false,
        .is_signer = signer,
        .is_writable = writable,
    };
}

fn freeTokenAccounts(allocator: std.mem.Allocator, accounts: []TokenAccount) void {
    for (accounts) |acc| {
        allocator.free(acc.data.*);
    }
}

test "validation harness: unsupported BPF helper id is rejected deterministically" {
    const bad_helper_id = 0x7FFF_FFFE;
    var prog_data = try std.testing.allocator.dupe(u8, &makeUnknownHelperProgram(bad_helper_id));
    defer std.testing.allocator.free(prog_data);

    var lamports: u64 = 0;
    const owner = bpf_loader.ID;
    var program = buildExecutableProgram(
        makePubkey(0x31),
        &lamports,
        &owner,
        &prog_data,
        false,
        false,
    );

    const accounts = [_]BpfProgram{program};
    try std.testing.expectError(
        error.UnsupportedHelper,
        bpf_loader.executeProgram(program, &accounts, &.{}, 0, std.testing.allocator),
    );
}

test "validation harness: token transfer with wrong authority is explicit unauthorized" {
    const owner_program_key = makePubkey(0xA1);

    var mint_lamports: u64 = 0;
    var mint_data = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(mint_data);

    var mint_authority = makePubkey(0xA2);
    var mint_authority_lamports: u64 = 0;
    var mint_authority_data = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(mint_authority_data);

    var source_owner = makePubkey(0xB1);
    var source_owner_lamports: u64 = 0;
    var source_owner_data = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(source_owner_data);

    var destination_owner = makePubkey(0xC1);
    var destination_owner_lamports: u64 = 0;
    var destination_owner_data = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(destination_owner_data);

    var wrong_authority = makePubkey(0xD1);
    var wrong_authority_lamports: u64 = 0;
    var wrong_authority_data = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(wrong_authority_data);

    var source_token = try newTokenAccount(makePubkey(0xE1), &source_owner_lamports, &owner_program_key, true, true, std.testing.allocator);
    var destination_token = try newTokenAccount(makePubkey(0xE2), &destination_owner_lamports, &owner_program_key, true, true, std.testing.allocator);
    defer freeTokenAccounts(std.testing.allocator, &[_]TokenAccount{ source_token, destination_token });

    var mint_account = buildAccount(
        makePubkey(0xE3),
        &mint_lamports,
        &owner_program_key,
        &mint_data,
        true,
        true,
    );
    const mint_authority_account = buildAccount(
        mint_authority,
        &mint_authority_lamports,
        &owner_program_key,
        &mint_authority_data,
        true,
        true,
    );
    const source_owner_account = buildAccount(
        source_owner,
        &source_owner_lamports,
        &owner_program_key,
        &source_owner_data,
        true,
        false,
    );
    const destination_owner_account = buildAccount(
        destination_owner,
        &destination_owner_lamports,
        &owner_program_key,
        &destination_owner_data,
        false,
        false,
    );
    const wrong_authority_account = buildAccount(
        wrong_authority,
        &wrong_authority_lamports,
        &owner_program_key,
        &wrong_authority_data,
        true,
        false,
    );

    const init_mint = [_]u8{ 0, 0, 0, 0, 9 };
    try token.execute(&[_]TokenAccount{ mint_account, mint_authority_account }, &init_mint, 0, std.testing.allocator);

    const init_token_account = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0 };
    try token.execute(
        &[_]TokenAccount{ source_token, mint_account, source_owner_account },
        &init_token_account,
        0,
        std.testing.allocator,
    );
    try token.execute(
        &[_]TokenAccount{ destination_token, mint_account, destination_owner_account },
        &init_token_account,
        0,
        std.testing.allocator,
    );

    const mint_to = [_]u8{ 7, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0, 0 };
    try token.execute(
        &[_]TokenAccount{ mint_account, source_token, mint_authority_account },
        &mint_to,
        0,
        std.testing.allocator,
    );

    const before = readAmountFromTokenAccount(&source_token);
    const transfer = [_]u8{ 3, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(
        token.Error.Unauthorized,
        token.execute(
            &[_]TokenAccount{ source_token, destination_token, wrong_authority_account },
            &transfer,
            0,
            std.testing.allocator,
        ),
    );
    try std.testing.expectEqual(before, readAmountFromTokenAccount(&source_token));
}
