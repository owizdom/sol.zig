// Runtime: loads accounts, dispatches instructions to native programs, commits changes.
const std = @import("std");
const types      = @import("types");
const transaction = @import("transaction");
const accounts_db = @import("accounts_db");
const sys_prog   = @import("programs/system");
const vote_prog  = @import("programs/vote_program");
const stake_prog = @import("programs/stake");
const config_prog = @import("programs/config");
const token_prog = @import("programs/token");
const sysvar     = @import("sysvar");
const bpf_prog = @import("programs/bpf_loader");

pub const MAX_CPI_DEPTH: usize = 4;
pub const COMPUTE_UNIT_LIMIT: u64 = 1_400_000;

// ── Error set ────────────────────────────────────────────────────────────────

pub const RuntimeError = error{
    InvalidAccountIndex,
    InvalidInstructionData,
    InvalidAccountLayout,
    InvalidAccountData,
    AccountNotFound,
    ProgramAccountNotFound,
    InsufficientFunds,
    AccountNotWritable,
    AccountNotSigner,
    Unauthorized,
    InvalidProgramId,
    MaxCpiDepthExceeded,
    ComputeUnitsExhausted,
    UnsupportedHelper,
    FeatureDisabled,
    ProgramFailed,
    OutOfMemory,
    ProgramError,
    DuplicateAccount,
    Overflow,
    BpfExecutionNotSupported,
};

// ── Mutable account reference ────────────────────────────────────────────────

pub const AccountRef = types.AccountRef;

// ── Invoke context ───────────────────────────────────────────────────────────

pub const InvokeContext = struct {
    db:          *accounts_db.AccountsDb,
    slot:        types.Slot,
    epoch:       types.Epoch,
    allocator:   std.mem.Allocator,
    compute_used: u64,
    cpi_depth:   usize,
    recent_bh:   types.Hash,
    helper_features: bpf_prog.HelperFeatures,

    pub fn init(
        db:        *accounts_db.AccountsDb,
        slot:      types.Slot,
        epoch:     types.Epoch,
        recent_bh: types.Hash,
        allocator: std.mem.Allocator,
        helper_features: bpf_prog.HelperFeatures,
    ) InvokeContext {
        return .{
            .db           = db,
            .slot         = slot,
            .epoch        = epoch,
            .allocator    = allocator,
            .compute_used = 0,
            .cpi_depth    = 0,
            .recent_bh    = recent_bh,
            .helper_features = helper_features,
        };
    }

    pub fn chargeCompute(self: *InvokeContext, units: u64) RuntimeError!void {
        self.compute_used = self.compute_used +| units;
        if (self.compute_used > COMPUTE_UNIT_LIMIT) return error.ComputeUnitsExhausted;
    }
};

fn mapRuntimeError(err: anyerror) RuntimeError {
    return switch (err) {
        error.InvalidInstruction,
        error.InvalidInstructionData => RuntimeError.InvalidInstructionData,

        error.InvalidAccountLayout,
        error.InvalidAddress => RuntimeError.InvalidAccountLayout,
        error.InvalidAccountIndex => RuntimeError.InvalidAccountIndex,
        error.InvalidAccountData,
        error.InvalidAccountOwner,
        error.AccountOwnerInvalid,
        error.ValueOverflow,
        error.InvalidData => RuntimeError.InvalidAccountData,

        error.Overflow => RuntimeError.Overflow,

        error.NotWritable,
        error.AccountNotWritable => RuntimeError.AccountNotWritable,

        error.NotEnoughFunds => RuntimeError.InsufficientFunds,
        error.InvalidSigner,
        error.AccountNotSigner => RuntimeError.AccountNotSigner,
        error.DuplicateAccount => RuntimeError.DuplicateAccount,
        error.Unauthorized => RuntimeError.Unauthorized,
        error.MaxCpiDepthExceeded => RuntimeError.MaxCpiDepthExceeded,

        error.UnsupportedHelper,
        error.CpiNotSupported => RuntimeError.UnsupportedHelper,
        error.ProgramFailed => RuntimeError.ProgramFailed,

        error.FeatureDisabled => RuntimeError.FeatureDisabled,
        error.InvalidProgramFormat => RuntimeError.InvalidInstructionData,
        error.DivideByZero => RuntimeError.InvalidInstructionData,
        error.OutOfMemory => RuntimeError.OutOfMemory,
        error.BpfExecutionNotSupported => RuntimeError.BpfExecutionNotSupported,
        error.ComputeBudgetExceeded => RuntimeError.ComputeUnitsExhausted,
        else => RuntimeError.ProgramFailed,
    };
}

// ── Loaded accounts for a transaction ───────────────────────────────────────

pub const LoadedAccounts = struct {
    accounts: []LoadedAccount,
    allocator: std.mem.Allocator,

    pub const LoadedAccount = struct {
        key:       types.Pubkey,
        lamports:  u64,
        data:      []u8,      // heap copy; owned
        owner:     types.Pubkey,
        executable: bool,
        rent_epoch: types.Epoch,
        is_signer: bool,
        is_writable: bool,
    };

    pub fn deinit(self: *LoadedAccounts) void {
        for (self.accounts) |*a| self.allocator.free(a.data);
        self.allocator.free(self.accounts);
    }
};

/// Load all accounts referenced by the message from AccountsDB.
pub fn loadAccounts(
    db:      *accounts_db.AccountsDb,
    message: *const transaction.Message,
    allocator: std.mem.Allocator,
) !LoadedAccounts {
    const n = message.account_keys.len;
    const n_signed = message.header.num_required_signatures;
    const n_ro_sign = message.header.num_readonly_signed_accounts;
    const n_ro_uns = message.header.num_readonly_unsigned_accounts;

    if (n_ro_sign > n_signed) return error.InvalidInstructionData;
    if (n_ro_uns > n - n_signed) return error.InvalidInstructionData;

    try validateDuplicateAccountMeta(message, allocator);

    const arr = try allocator.alloc(LoadedAccounts.LoadedAccount, n);

    for (message.account_keys, 0..) |key, i| {
        const is_signer   = i < n_signed;
        const is_writable = if (is_signer)
            i < (n_signed - n_ro_sign)
        else
            i < (n - n_ro_uns);

        if (db.get(key)) |stored| {
            if (comptime accounts_db.PERSISTENT) {
                arr[i] = .{
                    .key        = key,
                    .lamports   = stored.lamports,
                    .data       = stored.data,
                    .owner      = stored.owner,
                    .executable = stored.executable,
                    .rent_epoch = stored.rent_epoch,
                    .is_signer  = is_signer,
                    .is_writable = is_writable,
                };
            } else {
                const data_copy = try allocator.dupe(u8, stored.data);
                arr[i] = .{
                    .key        = key,
                    .lamports   = stored.lamports,
                    .data       = data_copy,
                    .owner      = stored.owner,
                    .executable = stored.executable,
                    .rent_epoch = stored.rent_epoch,
                    .is_signer  = is_signer,
                    .is_writable = is_writable,
                };
            }
            if (comptime accounts_db.PERSISTENT) {
                db.allocator.free(stored.data);
            }
        } else {
            // Account doesn't exist yet — start as zero-lamport owned by System Program.
            arr[i] = .{
                .key        = key,
                .lamports   = 0,
                .data       = try allocator.dupe(u8, &.{}),
                .owner      = .{ .bytes = [_]u8{0} ** 32 },
                .executable = false,
                .rent_epoch = 0,
                .is_signer  = is_signer,
                .is_writable = is_writable,
            };
        }
    }

    return .{ .accounts = arr, .allocator = allocator };
}

const AccountMetaFlags = packed struct {
    is_signer: bool,
    is_writable: bool,
};

fn validateDuplicateAccountMeta(message: *const transaction.Message, allocator: std.mem.Allocator) RuntimeError!void {
    var seen = std.AutoHashMap([32]u8, AccountMetaFlags).init(allocator);
    defer seen.deinit();

    const n = message.account_keys.len;
    for (message.account_keys, 0..) |key, i| {
        const is_signer = i < message.header.num_required_signatures;
        const is_writable = if (is_signer)
            i < (message.header.num_required_signatures - message.header.num_readonly_signed_accounts)
        else
            i < (n - message.header.num_readonly_unsigned_accounts);
        const flags = AccountMetaFlags{ .is_signer = is_signer, .is_writable = is_writable };

        if (seen.get(key.bytes)) |prev| {
            if (prev.is_signer != flags.is_signer or prev.is_writable != flags.is_writable) {
                return error.DuplicateAccount;
            }
        } else {
            try seen.put(key.bytes, flags);
        }
    }
}

/// Commit loaded accounts back to AccountsDB after successful execution.
pub fn commitAccounts(
    db:   *accounts_db.AccountsDb,
    la:   *LoadedAccounts,
    slot: types.Slot,
) !void {
    for (la.accounts) |a| {
        if (a.lamports == 0 and a.data.len == 0) {
            // Dead account — delete.
            try db.delete(a.key, slot);
        } else {
            try db.store(a.key, a.lamports, a.data, a.owner, a.executable, a.rent_epoch, slot);
        }
    }
}

// ── Instruction executor ─────────────────────────────────────────────────────

/// Execute a single instruction. Returns compute units consumed.
pub fn executeInstruction(
    ctx:     *InvokeContext,
    message: *const transaction.Message,
    ix:      transaction.CompiledInstruction,
    la:      *LoadedAccounts,
) RuntimeError!u64 {
    const before = ctx.compute_used;

    if (ix.program_id_index >= message.account_keys.len) return error.InvalidAccountIndex;
    const program_id = message.account_keys[ix.program_id_index];
    const program_owner = la.accounts[ix.program_id_index].owner;
    const program_is_executable = la.accounts[ix.program_id_index].executable;

    // Base cost per instruction.
    try ctx.chargeCompute(150);

    // Build AccountRef slice for this instruction.
    var refs_buf: [64]AccountRef = undefined;
    if (ix.accounts.len > refs_buf.len) return error.InvalidAccountIndex;

    for (ix.accounts, 0..) |ai, ri| {
        if (ai >= la.accounts.len) return error.InvalidAccountIndex;
        const a = &la.accounts[ai];
        refs_buf[ri] = .{
            .key        = a.key,
            .lamports   = &a.lamports,
            .data       = &a.data,
            .owner      = &a.owner,
            .executable = a.executable,
            .is_signer  = a.is_signer,
            .is_writable = a.is_writable,
        };
    }
    const refs = refs_buf[0..ix.accounts.len];
    try normalizeInstructionRefs(refs);
    for (refs) |a| {
        if (bpf_prog.isSysvarAccount(&a.key) and a.is_writable) return error.InvalidAccountLayout;
    }

    // Dispatch.
    if (std.mem.eql(u8, &program_id.bytes, &sys_prog.ID.bytes)) {
        // System Program
        sys_prog.execute(refs, ix.data, ctx.recent_bh, ctx.allocator) catch |e| return mapRuntimeError(e);
        try ctx.chargeCompute(100);
    } else if (std.mem.eql(u8, &program_id.bytes, &vote_prog.ID.bytes)) {
        // Vote Program
        vote_prog.execute(refs, ix.data, ctx.slot, ctx.recent_bh) catch |e| return mapRuntimeError(e);
        try ctx.chargeCompute(2_100);
    } else if (std.mem.eql(u8, &program_id.bytes, &stake_prog.ID.bytes)) {
        // Stake Program
        stake_prog.execute(refs, ix.data, ctx.epoch, ctx.allocator) catch |e| return mapRuntimeError(e);
        try ctx.chargeCompute(15_000);
    } else if (std.mem.eql(u8, &program_id.bytes, &config_prog.ID.bytes)) {
        // Config Program
        config_prog.execute(refs, ix.data, ctx.slot, ctx.allocator) catch |e| return mapRuntimeError(e);
        try ctx.chargeCompute(2_500);
    } else if (token_prog.isTokenProgram(program_id)) {
        token_prog.execute(refs, ix.data, ctx.slot, ctx.allocator) catch |e| return mapRuntimeError(e);
        try ctx.chargeCompute(5_500);
    } else if (std.mem.eql(u8, &program_id.bytes, &bpf_prog.ID.bytes)) {
        // BPF Loader.
        bpf_prog.execute(refs, ix.data, ctx.slot, ctx.allocator) catch |e| return mapRuntimeError(e);
        try ctx.chargeCompute(5_000);
    } else if (program_is_executable and std.mem.eql(u8, &program_owner.bytes, &bpf_prog.ID.bytes)) {
        // Loader-owned executable user program.
        const program_ref = AccountRef{
            .key = program_id,
            .lamports = &la.accounts[ix.program_id_index].lamports,
            .data = &la.accounts[ix.program_id_index].data,
            .owner = &la.accounts[ix.program_id_index].owner,
            .executable = la.accounts[ix.program_id_index].executable,
            .is_signer = la.accounts[ix.program_id_index].is_signer,
            .is_writable = la.accounts[ix.program_id_index].is_writable,
        };
        const remaining_budget = COMPUTE_UNIT_LIMIT -| ctx.compute_used;
        const execution = bpf_prog.executeProgramWithFeaturesAndBudgetDetailed(
            program_ref,
            refs,
            ix.data,
            ctx.slot,
            ctx.allocator,
            remaining_budget,
            ctx.helper_features,
        ) catch |err| return mapRuntimeError(err);
        const exit_code = execution.exit_code;
        if (exit_code != 0) return error.ProgramFailed;
        try ctx.chargeCompute(execution.compute_used);
    } else {
        // Unknown program IDs are rejected in this first-pass implementation.
        return error.InvalidProgramId;
    }

    return ctx.compute_used - before;
}

fn normalizeInstructionRefs(refs: []AccountRef) RuntimeError!void {
    if (refs.len == 0) return;

    for (refs, 0..) |*current, i| {
        var writable = current.is_writable;
        var signer = current.is_signer;
        var seen_writable = current.is_writable;

        var j: usize = i + 1;
        while (j < refs.len) : (j += 1) {
            if (!isSamePubkey(&current.key, &refs[j].key)) continue;
            if (writable != refs[j].is_writable) return error.DuplicateAccount;
            writable = writable or refs[j].is_writable;
            signer = signer or refs[j].is_signer;
            seen_writable = seen_writable or refs[j].is_writable;
        }

        var j2: usize = 0;
        while (j2 < i) : (j2 += 1) {
            if (!isSamePubkey(&current.key, &refs[j2].key)) continue;
            if (seen_writable != refs[j2].is_writable) return error.DuplicateAccount;
            writable = writable or refs[j2].is_writable;
            signer = signer or refs[j2].is_signer;
            seen_writable = seen_writable or refs[j2].is_writable;
        }

        current.is_writable = writable;
        current.is_signer = signer;
    }
    return;
}

fn isSamePubkey(a: *const types.Pubkey, b: *const types.Pubkey) bool {
    return std.mem.eql(u8, a.bytes[0..], b.bytes[0..]);
}

/// Execute all instructions in a transaction.
pub fn executeTransaction(
    ctx:     *InvokeContext,
    message: *const transaction.Message,
    la:      *LoadedAccounts,
) RuntimeError!u64 {
    for (message.instructions) |ix| {
        _ = try executeInstruction(ctx, message, ix, la);
    }
    return ctx.compute_used;
}

test "load nonexistent account returns zero" {
    var db = accounts_db.AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    const sig = types.Signature{ .bytes = [_]u8{0} ** 64 };
    const key = types.Pubkey{ .bytes = [_]u8{0xAA} ** 32 };
    const bh  = types.Hash.ZERO;

    const msg = transaction.Message{
        .header = .{ .num_required_signatures = 1, .num_readonly_signed_accounts = 0, .num_readonly_unsigned_accounts = 0 },
        .account_keys = &[_]types.Pubkey{key},
        .recent_blockhash = bh,
        .instructions = &[_]transaction.CompiledInstruction{},
    };
    _ = sig;

    var la = try loadAccounts(&db, &msg, std.testing.allocator);
    defer la.deinit();

    try std.testing.expectEqual(@as(u64, 0), la.accounts[0].lamports);
}

test "runtime executes loader-owned program bytecode" {
    var db = accounts_db.AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    const slot: types.Slot = 12;
    const recent_bh = types.Hash.ZERO;
    const sender_key = types.Pubkey{ .bytes = [_]u8{0x11} ** 32 };
    const receiver_key = types.Pubkey{ .bytes = [_]u8{0x22} ** 32 };
    const program_key = types.Pubkey{ .bytes = [_]u8{0x33} ** 32 };

    try db.store(sender_key, 50, &[_]u8{}, .{ .bytes = [_]u8{0} ** 32 }, false, 0, slot);
    try db.store(receiver_key, 1, &[_]u8{}, .{ .bytes = [_]u8{0} ** 32 }, false, 0, slot);

    var program_bytes: [56]u8 = undefined;
    @memset(&program_bytes, 0);
    @memcpy(program_bytes[0..4], "SBF1"[0..4]);

    var p: usize = 4;
    // r1 = 0
    program_bytes[p + 0] = 0xb7;
    program_bytes[p + 1] = 0x01;
    std.mem.writeInt(i16, program_bytes[p + 2 .. p + 4], 0, .little);
    std.mem.writeInt(i32, program_bytes[p + 4 .. p + 8], 0, .little);
    p += 8;

    // r2 = 1
    program_bytes[p + 0] = 0xb7;
    program_bytes[p + 1] = 0x02;
    std.mem.writeInt(i16, program_bytes[p + 2 .. p + 4], 0, .little);
    std.mem.writeInt(i32, program_bytes[p + 4 .. p + 8], 1, .little);
    p += 8;

    // r3 = 10
    program_bytes[p + 0] = 0xb7;
    program_bytes[p + 1] = 0x03;
    std.mem.writeInt(i16, program_bytes[p + 2 .. p + 4], 0, .little);
    std.mem.writeInt(i32, program_bytes[p + 4 .. p + 8], 10, .little);
    p += 8;

    // helper transfer
    program_bytes[p + 0] = 0x85;
    program_bytes[p + 1] = 0x00;
    std.mem.writeInt(i16, program_bytes[p + 2 .. p + 4], 0, .little);
    std.mem.writeInt(i32, program_bytes[p + 4 .. p + 8], 1, .little);
    p += 8;

    // exit
    program_bytes[p + 0] = 0x95;
    std.mem.writeInt(i16, program_bytes[p + 2 .. p + 4], 0, .little);
    std.mem.writeInt(i32, program_bytes[p + 4 .. p + 8], 0, .little);
    try db.store(program_key, 0, &program_bytes, bpf_prog.ID, true, 0, slot);

    var msg = transaction.Message{
        .header = .{
            .num_required_signatures = 1,
            .num_readonly_signed_accounts = 0,
            .num_readonly_unsigned_accounts = 0,
        },
        .account_keys = &[_]types.Pubkey{
            sender_key,
            receiver_key,
            program_key,
        },
        .recent_blockhash = recent_bh,
        .instructions = &[_]transaction.CompiledInstruction{
            .{
                .program_id_index = 2,
                .accounts = &[_]u8{ 0, 1 },
                .data = &[_]u8{},
            },
        },
    };

    var la = try loadAccounts(&db, &msg, std.testing.allocator);
    defer la.deinit();

    var ctx = InvokeContext.init(&db, slot, 0, recent_bh, std.testing.allocator, bpf_prog.DefaultHelperFeatures);
    _ = try executeTransaction(&ctx, &msg, &la);

    try std.testing.expectEqual(@as(u64, 40), la.accounts[0].lamports);
    try std.testing.expectEqual(@as(u64, 11), la.accounts[1].lamports);
}

test "runtime rejects writable sysvar account references" {
    var db = accounts_db.AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    const slot: types.Slot = 21;
    const recent_bh = types.Hash.ZERO;
    const program_key = types.Pubkey{ .bytes = [_]u8{0x77} ** 32 };

    const msg = transaction.Message{
        .header = .{
            .num_required_signatures = 0,
            .num_readonly_signed_accounts = 0,
            .num_readonly_unsigned_accounts = 0,
        },
        .account_keys = &[_]types.Pubkey{
            sysvar.CLOCK_ID,
            program_key,
        },
        .recent_blockhash = recent_bh,
        .instructions = &[_]transaction.CompiledInstruction{
            .{
                .program_id_index = 1,
                .accounts = &[_]u8{0},
                .data = &[_]u8{},
            },
        },
    };

    var la = try loadAccounts(&db, &msg, std.testing.allocator);
    defer la.deinit();

    var ctx = InvokeContext.init(&db, slot, 0, recent_bh, std.testing.allocator, bpf_prog.DefaultHelperFeatures);
    try std.testing.expectError(error.InvalidAccountLayout, executeTransaction(&ctx, &msg, &la));
}

test "loadAccounts rejects duplicate account keys with conflicting mutability" {
    var db = accounts_db.AccountsDb.init(std.testing.allocator);
    defer db.deinit();

    const key = types.Pubkey{ .bytes = [_]u8{0x11} ** 32 };
    const msg = transaction.Message{
        .header = .{
            .num_required_signatures = 0,
            .num_readonly_signed_accounts = 0,
            .num_readonly_unsigned_accounts = 1,
        },
        .account_keys = &[_]types.Pubkey{ key, key },
        .recent_blockhash = types.Hash.ZERO,
        .instructions = &[_]transaction.CompiledInstruction{},
    };

    try std.testing.expectError(
        error.DuplicateAccount,
        loadAccounts(&db, &msg, std.testing.allocator),
    );
}
