const std = @import("std");
const types = @import("types");
const sysvar = @import("sysvar");

/// Placeholder BPF Loader program ID.
pub const ID: types.Pubkey = .{
    .bytes = [_]u8{
        0x00, 0x00, 0x00, 0xe4, 0xba, 0x66, 0x31, 0x3d,
        0x75, 0x87, 0x02, 0x1a, 0x63, 0xca, 0x94, 0x20,
        0x88, 0x2c, 0x5d, 0xf2, 0xbd, 0xfa, 0x17, 0x72,
        0x18, 0xab, 0xd4, 0xc1, 0xc0, 0x00, 0x00, 0x00,
    },
};

pub const AccountRef = types.AccountRef;

pub const Error = error{
    BpfExecutionNotSupported,
    InvalidInstruction,
    InvalidInstructionData,
    InvalidAccountLayout,
    InvalidAccountIndex,
    MaxCpiDepthExceeded,
    Unauthorized,
    InvalidAddress,
    InvalidProgramFormat,
    UnsupportedOpcode,
    UnsupportedHelper,
    DivideByZero,
    CpiNotSupported,
    FeatureDisabled,
    OutOfMemory,
    ComputeBudgetExceeded,
    ProgramFailed,
};

pub const ExecutionResult = struct {
    exit_code: u64,
    compute_used: u64,
};

pub const InstructionTag = enum(u32) {
    create_account = 0,
    write = 1,
    finalize = 2,
    upgrade = 3,
    close = 4,
    finalize_upgradeable = 5,
};

const BPF_LD = 0x00;
const BPF_LDX = 0x01;
const BPF_ST = 0x02;
const BPF_STX = 0x03;
const BPF_ALU = 0x04;
const BPF_JMP = 0x05;
const BPF_JMP32 = 0x06;
const BPF_ALU64 = 0x07;

const BPF_W = 0x00;
const BPF_H = 0x08;
const BPF_B = 0x10;
const BPF_DW = 0x18;
const BPF_IMM = 0x00;
const BPF_ABS = 0x20;
const BPF_IND = 0x40;
const BPF_MEM = 0x60;
const BPF_X = 0x08;
const BPF_K = 0x00;

const BPF_SIZE_MASK: u8 = 0x18;
const BPF_MODE_MASK: u8 = 0xe0;
const BPF_OP_MASK: u8 = 0xf0;

const BPF_ADD: u8 = 0x00;
const BPF_SUB: u8 = 0x10;
const BPF_MUL: u8 = 0x20;
const BPF_DIV: u8 = 0x30;
const BPF_OR: u8 = 0x40;
const BPF_AND: u8 = 0x50;
const BPF_LSH: u8 = 0x60;
const BPF_RSH: u8 = 0x70;
const BPF_NEG: u8 = 0x80;
const BPF_MOD: u8 = 0x90;
const BPF_XOR: u8 = 0xa0;
const BPF_MOV: u8 = 0xb0;
const BPF_ARSH: u8 = 0xc0;
const BPF_END: u8 = 0xd0;

const BPF_JA: u8 = 0x00;
const BPF_JEQ: u8 = 0x10;
const BPF_JGT: u8 = 0x20;
const BPF_JGE: u8 = 0x30;
const BPF_JSET: u8 = 0x40;
const BPF_JNE: u8 = 0x50;
const BPF_JSGT: u8 = 0x60;
const BPF_JSGE: u8 = 0x70;
const BPF_CALL: u8 = 0x80;
const BPF_EXIT: u8 = 0x90;
const BPF_JLT: u8 = 0xa0;
const BPF_JLE: u8 = 0xb0;
const BPF_JSLT: u8 = 0xc0;
const BPF_JSLE: u8 = 0xd0;

const BPF_HELPER_TRANSFER: u64 = 1;
const BPF_HELPER_RESIZE: u64 = 2;
const BPF_HELPER_SET_DATA: u64 = 3;
const BPF_HELPER_LOG: u64 = 4;
const BPF_HELPER_GET_SLOT: u64 = 5;
const BPF_HELPER_GET_IX_DATA_LEN: u64 = 6;
const BPF_HELPER_GET_KEY_BYTES: u64 = 7;
const BPF_HELPER_INVOKE: u64 = 8;
const BPF_HELPER_GET_COMPUTE_BUDGET: u64 = 9;
const BPF_HELPER_IS_SYSVAR: u64 = 10;
const BPF_HELPER_LOG_U64: u64 = 11;
const BPF_HELPER_LOG_U128: u64 = 12;
const BPF_HELPER_MEMCMP: u64 = 13;
const BPF_HELPER_SHA256: u64 = 14;
const BPF_HELPER_SET_RETURN_DATA: u64 = 15;
const BPF_HELPER_GET_RETURN_DATA: u64 = 16;

pub const COMPUTE_BUDGET_UNITS: u64 = 1_400_000;
pub const MAX_RETURN_DATA_LEN = 256;
const MAX_BPF_CALL_DEPTH: usize = 4;
const BASE_INSTRUCTION_COST: u64 = 1;
const BASE_STACK_LOAD_COST: u64 = 2;
const BASE_STACK_STORE_COST: u64 = 3;
const BASE_ALU_COST: u64 = 1;
const BASE_JUMP_COST: u64 = 1;
const BASE_CALL_COST: u64 = 1;
const HELPER_CALL_COST: u64 = 5;
const HELPER_LOG_COST: u64 = 4;
const HELPER_LOG_U64_COST: u64 = 4;
const HELPER_LOG_U128_COST: u64 = 6;
const HELPER_HASH_COST_BASE: u64 = 24;
const HELPER_MEMCMP_COST_BASE: u64 = 6;
const HELPER_MEMCMP_COST_PER_BYTE: u64 = 1;
const HELPER_MISC_COST: u64 = 2;
const HELPER_SET_RETURN_DATA_PER_BYTE: u64 = 1;
const HELPER_SET_DATA_PER_BYTE: u64 = 1;
const HELPER_RESIZE_COST: u64 = 30;
const HELPER_TRANSFER_COST: u64 = 50;
const HELPER_INVOKE_COST: u64 = 200;
const HELPER_NESTED_FRAME_COST: u64 = 50;
const HELPER_CPI_OVERHEAD: u64 = 80;
const COST_PER_HASH_BYTE: u64 = 2;
const MAX_CPI_ACCOUNTS: usize = 64;
const MAX_INVOKE_FRAMES = MAX_BPF_CALL_DEPTH + 1;
const CPI_META_WRITABLE = 0x01;
const CPI_META_SIGNER = 0x02;

const InvokeLock = struct {
    key: types.Pubkey,
    mode: AccessMode,
};

const InvokeFrame = struct {
    lock_count: usize,
    locks: [MAX_CPI_ACCOUNTS]InvokeLock,
    return_data_len: usize,
    return_data: [MAX_RETURN_DATA_LEN]u8,

    pub fn init(self: *InvokeFrame) void {
        self.lock_count = 0;
        self.return_data_len = 0;
        self.return_data = [_]u8{0} ** MAX_RETURN_DATA_LEN;
    }

    pub fn find(self: *const InvokeFrame, key: *const types.Pubkey) ?AccessMode {
        for (self.locks[0..self.lock_count]) |lock| {
            if (isSamePubkey(&lock.key, key)) return lock.mode;
        }
        return null;
    }

    pub fn add(self: *InvokeFrame, key: types.Pubkey, mode: AccessMode) Error!void {
        var i: usize = 0;
        while (i < self.lock_count) : (i += 1) {
            if (!isSamePubkey(&self.locks[i].key, &key)) continue;
            if (self.locks[i].mode != mode) return error.InvalidAccountLayout;
            return;
        }
        if (self.lock_count >= self.locks.len) return error.InvalidInstructionData;
        self.locks[self.lock_count] = .{ .key = key, .mode = mode };
        self.lock_count += 1;
    }

    pub fn clearReturnData(self: *InvokeFrame) void {
        self.return_data_len = 0;
    }

    pub fn setReturnData(self: *InvokeFrame, bytes: []const u8) Error!void {
        if (bytes.len > self.return_data.len) return error.InvalidInstructionData;
        self.return_data_len = 0;
        @memcpy(self.return_data[0..bytes.len], bytes);
        self.return_data_len = bytes.len;
    }

    pub fn returnDataSlice(self: *const InvokeFrame) []const u8 {
        return self.return_data[0..self.return_data_len];
    }

    pub fn inheritFrom(self: *InvokeFrame, source: *const InvokeFrame) void {
        self.return_data_len = source.return_data_len;
        @memcpy(self.return_data[0..source.return_data_len], source.return_data[0..source.return_data_len]);
    }
};

pub const HelperFeatures = struct {
    logs: bool = false,
    key_serialization: bool = false,
    compute_budget: bool = false,
    cpi: bool = false,
    return_data: bool = false,
    sha256: bool = false,
    memcmp: bool = false,
};

pub const DefaultHelperFeatures = HelperFeatures{
    .logs = true,
    .key_serialization = true,
    .compute_budget = true,
    .cpi = false,
    .return_data = false,
    .sha256 = false,
    .memcmp = false,
};

const STACK_BYTES = 512;
const MAX_REGS = 11;
const MAX_INSTRUCTIONS = 65_536;
const ELF_CLASS_64: u8 = 2;
const PF_X = 1;
const PT_LOAD: u32 = 1;

const ElfMagic = [_]u8{0x7f, 'E', 'L', 'F'};

const SBF_MAGIC = "SBF1";
const MAX_PROGRAM_VERSION: u8 = 1;
const MIN_LEGACY_SBF_VERSION: u8 = 0;
const MIN_PROGRAM_VERSION: u8 = 0;

pub const AccessMode = enum {
    readonly,
    writable,
};

const SliceRange = struct { start: usize, end: usize };

pub const ExecuteContext = struct {
    budget: u64,
    remaining: u64,
    consumed: u64,
    call_depth: usize,
    frames: [MAX_INVOKE_FRAMES]InvokeFrame,

    pub fn init(capacity: u64) ExecuteContext {
        return .{
            .budget = capacity,
            .remaining = capacity,
            .consumed = 0,
            .call_depth = 0,
            .frames = [_]InvokeFrame{.{
                .lock_count = 0,
                .locks = [_]InvokeLock{.{ .key = .{ .bytes = [_]u8{0} ** 32 }, .mode = .readonly }} ** MAX_CPI_ACCOUNTS,
                .return_data_len = 0,
                .return_data = [_]u8{0} ** MAX_RETURN_DATA_LEN,
            }} ** MAX_INVOKE_FRAMES,
        };
    }

    pub fn consumedUnits(self: *const ExecuteContext) u64 {
        return self.consumed;
    }

    pub fn charge(self: *ExecuteContext, units: u64) Error!void {
        if (units == 0) return;
        if (units > self.remaining) return error.ComputeBudgetExceeded;
        self.remaining -= units;
        if (std.math.maxInt(u64) - self.consumed < units) return error.ComputeBudgetExceeded;
        self.consumed += units;
    }

    pub fn enterRootFrame(self: *ExecuteContext, accounts: []const AccountRef) Error!void {
        self.call_depth = 0;
        self.frames[0].init();

        for (accounts) |account| {
            const mode: AccessMode = if (account.is_writable) .writable else .readonly;
            try self.frames[0].add(account.key, mode);
        }
    }

    fn hasReadableConflictWithActive(self: *const ExecuteContext, key: *const types.Pubkey, mode: AccessMode) Error!void {
        var frame_idx: usize = 0;
        while (frame_idx <= self.call_depth) : (frame_idx += 1) {
            if (self.frames[frame_idx].find(key)) |existing| {
                if (existing == .readonly and mode == .writable) return error.InvalidAccountLayout;
            }
        }
        return;
    }

    pub fn enterNestedFrameWithLocks(self: *ExecuteContext, locks: []const InvokeLock) Error!void {
        if (self.call_depth + 1 >= MAX_INVOKE_FRAMES) return error.MaxCpiDepthExceeded;
        const target = self.call_depth + 1;
        self.frames[target].init();
        self.frames[target].inheritFrom(&self.frames[self.call_depth]);
        var i: usize = 0;
        while (i < locks.len) : (i += 1) {
            const request = locks[i];
            try self.hasReadableConflictWithActive(&request.key, request.mode);
            self.frames[target].add(request.key, request.mode) catch {
                self.frames[target].lock_count = 0;
                return error.InvalidAccountLayout;
            };
        }
        self.call_depth = target;
        if (target > 1) try self.charge(HELPER_NESTED_FRAME_COST);
    }

    pub fn exitNestedFrame(self: *ExecuteContext) void {
        if (self.call_depth > 0) {
            self.frames[self.call_depth].init();
            self.call_depth -= 1;
        }
    }

    pub fn promoteNestedReturnData(self: *ExecuteContext) void {
        if (self.call_depth == 0) return;
        const child_idx = self.call_depth;
        const parent_idx = child_idx - 1;
        self.frames[parent_idx].return_data_len = self.frames[child_idx].return_data_len;
        if (self.frames[child_idx].return_data_len > 0) {
            @memcpy(
                self.frames[parent_idx].return_data[0..self.frames[child_idx].return_data_len],
                self.frames[child_idx].return_data[0..self.frames[child_idx].return_data_len],
            );
        }
    }

    pub fn setReturnData(self: *ExecuteContext, bytes: []const u8) Error!void {
        try self.frames[self.call_depth].setReturnData(bytes);
    }

    pub fn clearReturnData(self: *ExecuteContext) void {
        self.frames[self.call_depth].clearReturnData();
    }

    pub fn returnDataSlice(self: *ExecuteContext) []const u8 {
        return self.frames[self.call_depth].returnDataSlice();
    }
};

pub const Accessor = struct {
    key: *const types.Pubkey,
    lamports: *u64,
    data: *[]u8,
    owner: *types.Pubkey,
    executable: bool,
    is_signer: bool,
    is_writable: bool,

    pub fn keyBytes(self: Accessor) []const u8 {
        return self.key.bytes[0..];
    }

    pub fn requireWritable(self: Accessor) Error!void {
        if (!self.is_writable) return error.InvalidAccountLayout;
    }

    pub fn requireSigner(self: Accessor) Error!void {
        if (!self.is_signer) return error.Unauthorized;
    }
};

/// Canonical helper-call context for a single program invocation.
/// This keeps helper semantics deterministic and provides strict argument marshalling
/// from raw registers into typed values.
pub const HelperContext = struct {
    regs: *[MAX_REGS]u64,
    accounts: []AccountRef,
    stack: []u8,
    ix_data: []const u8,
    slot: types.Slot,
    exec_ctx: *ExecuteContext,
    allocator: std.mem.Allocator,
    features: HelperFeatures,

    pub fn init(
        regs: *[MAX_REGS]u64,
        accounts: []AccountRef,
        stack: []u8,
        ix_data: []const u8,
        slot: types.Slot,
        exec_ctx: *ExecuteContext,
        allocator: std.mem.Allocator,
        features: HelperFeatures,
    ) HelperContext {
        return .{
            .regs = regs,
            .accounts = accounts,
            .stack = stack,
            .ix_data = ix_data,
            .slot = slot,
            .exec_ctx = exec_ctx,
            .allocator = allocator,
            .features = features,
        };
    }

    pub fn requireFeature(_: *const HelperContext, feature: bool) Error!void {
        if (!feature) return error.FeatureDisabled;
    }

    pub fn charge(self: *HelperContext, units: u64) Error!void {
        try self.exec_ctx.charge(units);
    }

    pub fn reg(self: *const HelperContext, idx: usize) Error!u64 {
        if (idx >= self.regs.len) return error.InvalidInstructionData;
        return self.regs[idx];
    }

    pub fn accountIndex(self: *const HelperContext, idx: usize) Error!usize {
        const raw = try self.reg(idx);
        const parsed = try asIndex(raw);
        if (parsed >= self.accounts.len) return error.InvalidAccountIndex;
        return parsed;
    }

    pub fn accountMut(self: *const HelperContext, idx: usize) Error!*AccountRef {
        const account_idx = try self.accountIndex(idx);
        return &self.accounts[account_idx];
    }

    pub fn accessor(self: *const HelperContext, idx: usize, mode: AccessMode) Error!Accessor {
        const account_idx = try self.accountIndex(idx);
        const a = &self.accounts[account_idx];
        const normalized_mode = try self.normalizedModeForAccountKey(account_idx);

        if (mode == .writable and normalized_mode == .readonly) return error.InvalidAccountLayout;
        if (normalized_mode == .writable and isSysvarAccount(&a.key)) return error.InvalidAccountLayout;
        return .{
            .key = &a.key,
            .lamports = a.lamports,
            .data = a.data,
            .owner = a.owner,
            .executable = a.executable,
            .is_signer = a.is_signer,
            .is_writable = normalized_mode == .writable,
        };
    }

    pub fn accessorRO(self: *const HelperContext, idx: usize) Error!Accessor {
        return self.accessor(idx, .readonly);
    }

    pub fn accessorRW(self: *const HelperContext, idx: usize) Error!Accessor {
        return self.accessor(idx, .writable);
    }

    pub fn inputSlice(self: *const HelperContext, start_reg: usize, len_reg: usize) Error![]const u8 {
        const range = try translateSliceBounds(try self.reg(start_reg), try self.reg(len_reg), self.ix_data.len);
        return self.ix_data[range.start..range.end];
    }

    pub fn stackSliceRO(self: *const HelperContext, start_reg: usize, len_reg: usize) Error![]const u8 {
        const range = try translateSliceBounds(try self.reg(start_reg), try self.reg(len_reg), self.stack.len);
        return self.stack[range.start..range.end];
    }

    pub fn stackSliceRW(self: *HelperContext, start_reg: usize, len_reg: usize) Error![]u8 {
        const range = try translateSliceBounds(try self.reg(start_reg), try self.reg(len_reg), self.stack.len);
        return self.stack[range.start..range.end];
    }

    pub fn stackCString(self: *const HelperContext, start_reg: usize) Error![]const u8 {
        const start = try asIndex(try self.reg(start_reg));
        if (start >= self.stack.len) return error.InvalidInstructionData;

        var end = start;
        while (end < self.stack.len) : (end += 1) {
            if (self.stack[end] == 0) break;
        }

        if (end == self.stack.len) return error.InvalidInstructionData;
        return self.stack[start..end];
    }

    fn normalizedModeForAccountKey(self: *const HelperContext, account_idx: usize) Error!AccessMode {
        const target = self.accounts[account_idx].key;
        var normalized: ?AccessMode = null;

        for (self.accounts) |candidate| {
            if (!isSamePubkey(&candidate.key, &target)) continue;

            const candidate_mode: AccessMode = if (candidate.is_writable) .writable else .readonly;
            if (normalized == null) {
                normalized = candidate_mode;
            } else if (normalized.? != candidate_mode) {
                return error.InvalidAccountLayout;
            }
        }

        return normalized orelse .readonly;
    }
};

pub fn executeLoader(
    accounts: []AccountRef,
    ix_data: []const u8,
    _: types.Slot,
    allocator: std.mem.Allocator,
) Error!void {
    if (ix_data.len < 4) return error.InvalidInstruction;
    const tag = @as(InstructionTag, @enumFromInt(readLE(u32, ix_data, 0)));

    switch (tag) {
        .create_account => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (!accounts[1].is_signer) return error.Unauthorized;
            if (!accounts[1].is_writable) return error.InvalidAccountLayout;
            if (accounts[1].data.len == 0) {
                accounts[1].data.* = try allocator.dupe(u8, &.{});
            }
        },
        .write => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (ix_data.len < 8) return error.InvalidInstruction;
            if (!accounts[1].is_writable) return error.InvalidAccountLayout;

            const offset = readLE(u32, ix_data, 4);
            const payload = ix_data[8..];
            const off = @as(usize, offset);

            if (off > accounts[1].data.*.len) {
                const needed = try addWithOverflow(off, payload.len);
                const next = try allocator.alloc(u8, needed);
                @memset(next, 0);
                @memcpy(next[0..accounts[1].data.*.len], accounts[1].data.*);
                if (payload.len > 0) {
                    @memcpy(next[off .. off + payload.len], payload);
                }

                allocator.free(accounts[1].data.*);
                accounts[1].data.* = next;
                return;
            }

            const end = off + payload.len;
            if (end > accounts[1].data.*.len) {
                const next = try allocator.alloc(u8, end);
                @memset(next, 0);
                @memcpy(next[0..off], accounts[1].data.*[0..off]);
                @memcpy(next[off..end], payload);
                allocator.free(accounts[1].data.*);
                accounts[1].data.* = next;
                return;
            }

            @memcpy(accounts[1].data.*[off..end], payload);
        },
        .finalize => {
            if (accounts.len < 2) return error.InvalidAccountLayout;
            if (!accounts[1].is_writable) return error.InvalidAccountLayout;
            if (!accounts[1].is_signer) return error.Unauthorized;
        },
        .upgrade => {
            if (accounts.len < 1) return error.InvalidAccountLayout;
            if (!accounts[0].is_writable) return error.InvalidAccountLayout;
        },
        .close => {
            if (accounts.len < 1) return error.InvalidAccountLayout;
            if (!accounts[0].is_writable) return error.InvalidAccountLayout;
            allocator.free(accounts[0].data.*);
            accounts[0].data.* = try allocator.dupe(u8, &.{});
        },
        .finalize_upgradeable => {
            if (accounts.len < 1) return error.InvalidAccountLayout;
        },
    }
}

pub fn execute(
    accounts: []AccountRef,
    ix_data: []const u8,
    slot: types.Slot,
    allocator: std.mem.Allocator,
) Error!void {
    return executeLoader(accounts, ix_data, slot, allocator);
}

pub fn executeProgram(
    program: AccountRef,
    accounts: []AccountRef,
    ix_data: []const u8,
    slot: types.Slot,
    allocator: std.mem.Allocator,
) Error!u64 {
    return executeProgramWithFeatures(program, accounts, ix_data, slot, allocator, .{});
}

pub fn executeProgramWithFeatures(
    program: AccountRef,
    accounts: []AccountRef,
    ix_data: []const u8,
    slot: types.Slot,
    allocator: std.mem.Allocator,
    features: HelperFeatures,
) Error!u64 {
    return executeProgramWithFeaturesAndBudget(program, accounts, ix_data, slot, allocator, COMPUTE_BUDGET_UNITS, features);
}

pub fn executeProgramWithFeaturesAndBudget(
    program: AccountRef,
    accounts: []AccountRef,
    ix_data: []const u8,
    slot: types.Slot,
    allocator: std.mem.Allocator,
    compute_budget: u64,
    features: HelperFeatures,
) Error!u64 {
    return (try executeProgramWithFeaturesAndBudgetDetailed(program, accounts, ix_data, slot, allocator, compute_budget, features)).exit_code;
}

pub fn executeProgramWithFeaturesAndBudgetDetailed(
    program: AccountRef,
    accounts: []AccountRef,
    ix_data: []const u8,
    slot: types.Slot,
    allocator: std.mem.Allocator,
    compute_budget: u64,
    features: HelperFeatures,
) Error!ExecutionResult {
    if (program.data.*.len < 4) return error.InvalidInstruction;
    const raw = program.data.*;

    const code = if (std.mem.eql(u8, raw[0..4], &ElfMagic))
        try extractElfText(raw)
    else
        try extractProgramCode(raw);

    try verifyFeatureGatedHelpers(code, features);
    return try executeEbpfDetailed(code, accounts, ix_data, slot, allocator, compute_budget, features);
}

fn executeEbpf(
    code: []const u8,
    accounts: []AccountRef,
    ix_data: []const u8,
    slot: types.Slot,
    allocator: std.mem.Allocator,
    compute_budget: u64,
    features: HelperFeatures,
) Error!u64 {
    return (try executeEbpfDetailed(code, accounts, ix_data, slot, allocator, compute_budget, features)).exit_code;
}

fn executeEbpfDetailed(
    code: []const u8,
    accounts: []AccountRef,
    ix_data: []const u8,
    slot: types.Slot,
    allocator: std.mem.Allocator,
    compute_budget: u64,
    features: HelperFeatures,
) Error!ExecutionResult {
    try verifyEbpfProgram(code);
    if (code.len == 0 or code.len % 8 != 0) return error.InvalidProgramFormat;

    var regs: [MAX_REGS]u64 = [_]u64{0} ** MAX_REGS;
    var stack = [_]u8{0} ** STACK_BYTES;
    regs[10] = STACK_BYTES;
    var exec_ctx = ExecuteContext.init(compute_budget);
    try exec_ctx.enterRootFrame(accounts);
    var ctx = HelperContext.init(&regs, accounts, stack[0..], ix_data, slot, &exec_ctx, allocator, features);

    const insn_count = code.len / 8;
    var pc: usize = 0;
    while (pc < insn_count) {
        const ip = pc * 8;
        const opcode = code[ip];
        const dst_src = code[ip + 1];
        const off = readLE(i16, code, ip + 2);
        const imm = readLE(i32, code, ip + 4);

        const dst = dst_src & 0x0f;
        const src = (dst_src >> 4) & 0x0f;
        pc += 1;
        try exec_ctx.charge(BASE_INSTRUCTION_COST);

        const class = opcode & 0x07;
        switch (class) {
            BPF_LD => {
                try exec_ctx.charge(BASE_ALU_COST);
                if (dst >= regs.len) return error.InvalidAccountLayout;
                const mode = opcode & BPF_MODE_MASK;
                const size = opcode & BPF_SIZE_MASK;
                if (mode == BPF_DW) {
                    if (pc >= insn_count) return error.InvalidInstruction;
                    const hi = readLE(u32, code, (pc * 8) + 4);
                    pc += 1;
                    const lo_u32 = @as(u32, @bitCast(imm));
                    const imm64 = @as(u64, lo_u32) | (@as(u64, hi) << 32);
                    regs[dst] = imm64;
                    continue;
                }
                if (mode != BPF_IMM) return error.UnsupportedOpcode;
                if ((size != BPF_W) and (size != BPF_H) and (size != BPF_B) and (size != BPF_DW))
                    return error.UnsupportedOpcode;
                regs[dst] = zeroExtendImm(size, imm);
            },
            BPF_LDX => {
                try exec_ctx.charge(BASE_STACK_LOAD_COST);
                if (dst >= regs.len or src >= regs.len) return error.InvalidAccountLayout;
                const mode = opcode & BPF_MODE_MASK;
                if (mode != BPF_MEM) return error.UnsupportedOpcode;
                const size = opcode & BPF_SIZE_MASK;
                const size_u = try sizeToBytes(size);
                const base = regs[src];
                const value = try loadFromStack(stack[0..], base, off, size_u);
                regs[dst] = value;
            },
            BPF_ST => {
                try exec_ctx.charge(BASE_STACK_STORE_COST);
                if (dst >= regs.len) return error.InvalidAccountLayout;
                const mode = opcode & BPF_MODE_MASK;
                if (mode != BPF_MEM) return error.UnsupportedOpcode;
                const size = opcode & BPF_SIZE_MASK;
                const size_u = try sizeToBytes(size);
                try storeToStack(stack[0..], regs[dst], off, size_u, immAsU64(size, imm));
            },
            BPF_STX => {
                try exec_ctx.charge(BASE_STACK_STORE_COST);
                if (dst >= regs.len or src >= regs.len) return error.InvalidAccountLayout;
                const mode = opcode & BPF_MODE_MASK;
                if (mode != BPF_MEM) return error.UnsupportedOpcode;
                const size = opcode & BPF_SIZE_MASK;
                const size_u = try sizeToBytes(size);
                try storeToStack(stack[0..], regs[dst], off, size_u, regs[src]);
            },
            BPF_ALU, BPF_ALU64 => {
                try exec_ctx.charge(BASE_ALU_COST);
                if (dst >= regs.len) return error.InvalidAccountLayout;
                const use_64 = class == BPF_ALU64;
                const op = opcode & BPF_OP_MASK;
                const src_is_reg = (opcode & BPF_X) != 0;
                if (src_is_reg and src >= regs.len) return error.InvalidAccountLayout;
                const lhs_raw = regs[dst];
                const rhs = if (src_is_reg) regs[src] else @as(u64, @bitCast(@as(i64, imm)));
                regs[dst] = try executeAluOp(use_64, op, lhs_raw, rhs, imm);
            },
            BPF_JMP, BPF_JMP32 => {
                try exec_ctx.charge(BASE_JUMP_COST);
                if (dst >= regs.len) return error.InvalidAccountLayout;
                const op = opcode & BPF_OP_MASK;
                if (op == BPF_CALL) {
                    const id = @as(u64, @bitCast(@as(i64, imm)));
                    try exec_ctx.charge(BASE_CALL_COST);
                    try exec_ctx.charge(HELPER_CALL_COST);
                    regs[0] = try executeHelper(id, &ctx);
                    continue;
                }
                if (op == BPF_EXIT) return .{
                    .exit_code = regs[0],
                    .compute_used = exec_ctx.consumed,
                };
                if (op == BPF_JA) {
                    pc = jumpWithOffset(pc, off);
                    continue;
                }
                if ((opcode & BPF_X) != 0 and src >= regs.len) return error.InvalidAccountLayout;
                const left = regs[dst];
                const right = if ((opcode & BPF_X) != 0) regs[src] else @as(u64, @bitCast(@as(i64, imm)));
                const cond = switch (op) {
                    BPF_JEQ => left == right,
                    BPF_JGT => left > right,
                    BPF_JGE => left >= right,
                    BPF_JSET => (left & right) != 0,
                    BPF_JNE => left != right,
                    BPF_JSGT => @as(i64, @bitCast(left)) > @as(i64, @bitCast(right)),
                    BPF_JSGE => @as(i64, @bitCast(left)) >= @as(i64, @bitCast(right)),
                    BPF_JLT => left < right,
                    BPF_JLE => left <= right,
                    BPF_JSLT => @as(i64, @bitCast(left)) < @as(i64, @bitCast(right)),
                    BPF_JSLE => @as(i64, @bitCast(left)) <= @as(i64, @bitCast(right)),
                    else => return error.UnsupportedOpcode,
                };
                if (cond) pc = jumpWithOffset(pc, off);
            },
            else => return error.UnsupportedOpcode,
        }
    }

    return .{ .exit_code = regs[0], .compute_used = exec_ctx.consumed };
}

fn executeAluOp(use_64: bool, op: u8, lhs_raw: u64, rhs_raw: u64, imm: i32) Error!u64 {
    const lhs = if (use_64) lhs_raw else @as(u64, @as(u32, @truncate(lhs_raw)));
    const rhs = if (use_64) rhs_raw else @as(u64, @as(u32, @truncate(rhs_raw)));

    if (op == BPF_NEG) {
        const val = if (use_64) @as(u64, ~lhs +% 1) else @as(u64, ~(@as(u32, @truncate(lhs))) +% 1);
        return if (use_64) val else @as(u64, @as(u32, @truncate(val)));
    }

    if (op == BPF_END) {
        return switch (imm) {
            16 => if (use_64) @as(u64, @byteSwap(@as(u16, @truncate(lhs)))) else @as(u64, @as(u32, @byteSwap(@as(u16, @truncate(lhs))))),
            32 => if (use_64) @as(u64, @byteSwap(@as(u32, @truncate(lhs)))) else @as(u64, @byteSwap(@as(u32, @truncate(lhs)))),
            64 => if (use_64) @as(u64, @byteSwap(lhs)) else return error.InvalidInstruction,
            else => return error.InvalidInstruction,
        };
    }

    const result = switch (op) {
        BPF_MOV => rhs,
        BPF_ADD => lhs +| rhs,
        BPF_SUB => lhs -| rhs,
        BPF_MUL => lhs *% rhs,
        BPF_DIV => if (rhs == 0) return error.DivideByZero else lhs / rhs,
        BPF_OR => lhs | rhs,
        BPF_AND => lhs & rhs,
        BPF_XOR => lhs ^ rhs,
        BPF_MOD => if (rhs == 0) return error.DivideByZero else lhs % rhs,
        BPF_LSH => lhs << try normalizeShamt(rhs),
        BPF_RSH => lhs >> try normalizeShamt(rhs),
        BPF_ARSH => blk: {
            const shifted = @as(i64, @bitCast(lhs)) >> try normalizeShamt(rhs);
            break :blk @as(u64, @bitCast(shifted));
        },
        else => return error.UnsupportedOpcode,
    };
    return if (use_64) result else @as(u64, @truncate(result));
}

fn normalizeShamt(shift: u64) Error!u6 {
    if (shift > 63) return error.InvalidInstruction;
    return @as(u6, @intCast(shift));
}

fn jumpWithOffset(pc: usize, off: i16) usize {
    const next = @as(isize, @as(isize, @intCast(pc)) + @as(isize, off));
    if (next < 0) return 0;
    return @as(usize, @intCast(next));
}

fn sizeToBytes(size: u8) Error!usize {
    return switch (size) {
        BPF_W => 4,
        BPF_H => 2,
        BPF_B => 1,
        BPF_DW => 8,
        else => return error.InvalidInstruction,
    };
}

fn immAsU64(size: u8, imm: i32) u64 {
    _ = size;
    return @as(u64, @bitCast(@as(i64, imm)));
}

fn zeroExtendImm(size: u8, imm: i32) u64 {
    const imm_u32 = @as(u32, @bitCast(imm));
    return switch (size) {
        BPF_B => @as(u64, @as(u8, @truncate(imm_u32))),
        BPF_H => @as(u64, @as(u16, @truncate(imm_u32))),
        BPF_W => @as(u64, @as(u32, @truncate(imm_u32))),
        BPF_DW => @as(u64, @bitCast(@as(i64, imm))),
        else => @as(u64, @bitCast(@as(i64, imm))),
    };
}

fn resolveStackAddr(base: u64, off: i16, size: usize, alignment: usize, buffer_len: usize) Error!usize {
    if (size == 0) return error.InvalidInstruction;
    const signed_base = @as(i64, @bitCast(base));
    const abs = @as(i128, signed_base) + @as(i128, off);
    if (abs < 0) return error.InvalidAddress;
    if ((abs % @as(i128, @intCast(alignment))) != 0) return error.InvalidInstruction;

    const end = abs + @as(i128, @intCast(size));
    if (end > @as(i128, @intCast(buffer_len))) return error.InvalidAddress;
    if (end < 0) return error.InvalidAddress;
    return @as(usize, @intCast(abs));
}

fn loadFromStack(
    stack: []const u8,
    base: u64,
    off: i16,
    size_u: usize,
) Error!u64 {
    const addr = try resolveStackAddr(base, off, size_u, size_u, stack.len);
    return switch (size_u) {
        1 => stack[addr],
        2 => readLE(u16, stack, addr),
        4 => readLE(u32, stack, addr),
        8 => readLE(u64, stack, addr),
        else => return error.InvalidInstruction,
    };
}

fn writeLE(comptime T: type, raw: []u8, start: usize, value: T) void {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    var bytes: [size]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    @memcpy(raw[start .. start + size], &bytes);
}

fn storeToStack(
    stack: []u8,
    base: u64,
    off: i16,
    size_u: usize,
    value: u64,
) Error!void {
    const addr = try resolveStackAddr(base, off, size_u, size_u, stack.len);
    switch (size_u) {
        1 => stack[addr] = @as(u8, @truncate(value)),
        2 => writeLE(u16, stack, addr, @as(u16, @truncate(value))),
        4 => writeLE(u32, stack, addr, @as(u32, @truncate(value))),
        8 => writeLE(u64, stack, addr, value),
        else => return error.InvalidInstruction,
    }
}

fn executeHelper(
    id: u64,
    ctx: *HelperContext,
) Error!u64 {
    return switch (id) {
        BPF_HELPER_TRANSFER => return helperTransfer(ctx),
        BPF_HELPER_RESIZE => return helperResize(ctx),
        BPF_HELPER_SET_DATA => return helperSetData(ctx),
        BPF_HELPER_LOG => return helperLog(ctx),
        BPF_HELPER_LOG_U64 => return helperLogU64(ctx),
        BPF_HELPER_LOG_U128 => return helperLogU128(ctx),
        BPF_HELPER_GET_SLOT => return helperGetSlot(ctx),
        BPF_HELPER_GET_IX_DATA_LEN => return helperGetIxDataLen(ctx),
        BPF_HELPER_GET_KEY_BYTES => return helperGetKeyBytes(ctx),
        BPF_HELPER_IS_SYSVAR => return helperIsSysvar(ctx),
        BPF_HELPER_INVOKE => return helperInvoke(ctx),
        BPF_HELPER_GET_COMPUTE_BUDGET => return helperGetComputeBudget(ctx),
        BPF_HELPER_MEMCMP => return helperMemcmp(ctx),
        BPF_HELPER_SHA256 => return helperSha256(ctx),
        BPF_HELPER_SET_RETURN_DATA => return helperSetReturnData(ctx),
        BPF_HELPER_GET_RETURN_DATA => return helperGetReturnData(ctx),
        else => return error.UnsupportedHelper,
    };
}

const SUPPORTED_HELPER_IDS = [_]u64{
    BPF_HELPER_TRANSFER,
    BPF_HELPER_RESIZE,
    BPF_HELPER_SET_DATA,
    BPF_HELPER_LOG,
    BPF_HELPER_GET_SLOT,
    BPF_HELPER_GET_IX_DATA_LEN,
    BPF_HELPER_GET_KEY_BYTES,
    BPF_HELPER_IS_SYSVAR,
    BPF_HELPER_INVOKE,
    BPF_HELPER_GET_COMPUTE_BUDGET,
    BPF_HELPER_LOG_U64,
    BPF_HELPER_LOG_U128,
    BPF_HELPER_MEMCMP,
    BPF_HELPER_SHA256,
    BPF_HELPER_SET_RETURN_DATA,
    BPF_HELPER_GET_RETURN_DATA,
};

fn isSupportedHelper(id: u64) bool {
    for (SUPPORTED_HELPER_IDS) |candidate| {
        if (candidate == id) return true;
    }
    return false;
}

fn helperFeatureEnabled(id: u64, features: HelperFeatures) bool {
    return switch (id) {
        BPF_HELPER_LOG, BPF_HELPER_LOG_U64, BPF_HELPER_LOG_U128 => features.logs,
        BPF_HELPER_GET_KEY_BYTES => features.key_serialization,
        BPF_HELPER_GET_COMPUTE_BUDGET => features.compute_budget,
        BPF_HELPER_INVOKE => features.cpi,
        BPF_HELPER_SET_RETURN_DATA, BPF_HELPER_GET_RETURN_DATA => features.return_data,
        BPF_HELPER_SHA256 => features.sha256,
        BPF_HELPER_MEMCMP => features.memcmp,
        else => true,
    };
}

fn verifyFeatureGatedHelpers(code: []const u8, features: HelperFeatures) Error!void {
    if (code.len % 8 != 0) return;
    const insn_count = code.len / 8;
    var pc: usize = 0;
    while (pc < insn_count) {
        const ip = pc * 8;
        const opcode = code[ip];
        const class = opcode & 0x07;
        const op = opcode & BPF_OP_MASK;
        if (class == BPF_JMP or class == BPF_JMP32) {
            if (op == BPF_CALL) {
                const imm = readLE(i32, code, ip + 4);
                const helper = @as(u64, @bitCast(@as(i64, imm)));
                if (helper == 0) return error.InvalidInstructionData;
                if (!isSupportedHelper(helper)) return error.UnsupportedHelper;
                if (!helperFeatureEnabled(helper, features)) return error.FeatureDisabled;
            }
        }
        pc += 1;
    }
}

fn extractProgramCode(raw: []const u8) Error![]const u8 {
    if (raw.len < 4) return error.InvalidInstruction;
    if (!std.mem.eql(u8, raw[0..4], SBF_MAGIC)) return raw;

    if (raw.len >= 8 and raw[5] == 0 and raw[6] == 0 and raw[7] == 0) {
        if (raw[4] == MIN_LEGACY_SBF_VERSION) {
            return raw[4..];
        }
        if (raw[4] < MIN_PROGRAM_VERSION or raw[4] > MAX_PROGRAM_VERSION) {
            return error.InvalidInstructionData;
        }
        if (raw.len <= 8) return error.InvalidProgramFormat;
        return raw[8..];
    }

    return raw[4..];
}


fn helperLog(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_LOG_COST);
    try ctx.requireFeature(ctx.features.logs);
    const raw_len = try ctx.reg(2);
    const bytes = if (raw_len == 0)
        try ctx.stackCString(1)
    else
        try ctx.stackSliceRO(1, 2);
    const len_cost = @as(u64, @intCast(bytes.len));
    try ctx.charge(HELPER_MISC_COST + (len_cost / 32));
    return 0;
}

fn helperLogU64(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_LOG_U64_COST);
    try ctx.requireFeature(ctx.features.logs);
    _ = try ctx.reg(1);
    return 0;
}

fn helperLogU128(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_LOG_U128_COST);
    try ctx.requireFeature(ctx.features.logs);
    _ = try ctx.reg(1);
    _ = try ctx.reg(2);
    return 0;
}

fn helperGetSlot(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_MISC_COST);
    return ctx.slot;
}

fn helperGetIxDataLen(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_MISC_COST);
    return ctx.ix_data.len;
}

fn helperGetKeyBytes(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_MISC_COST);
    try ctx.requireFeature(ctx.features.key_serialization);
    const account = try ctx.accessorRO(1);
    const out = try ctx.stackSliceRW(2, 3);
    const written = @min(out.len, account.key.bytes.len);
    try ctx.charge(HELPER_MISC_COST + @as(u64, @intCast(written)));
    if (written > 0) @memcpy(out[0..written], account.key.bytes[0..written]);
    return written;
}

pub fn isSysvarAccount(key: *const types.Pubkey) bool {
    return isSamePubkey(key, &sysvar.CLOCK_ID)
        or isSamePubkey(key, &sysvar.RENT_ID)
        or isSamePubkey(key, &sysvar.SLOT_HASHES_ID)
        or isSamePubkey(key, &sysvar.EPOCH_SCHEDULE_ID)
        or isSamePubkey(key, &sysvar.STAKE_HISTORY_ID)
        or isSamePubkey(key, &sysvar.INSTRUCTIONS_ID);
}

fn helperIsSysvar(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_MISC_COST);
    const account = try ctx.accessorRO(1);
    return if (isSysvarAccount(account.key)) 1 else 0;
}

fn helperGetComputeBudget(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_MISC_COST);
    try ctx.requireFeature(ctx.features.compute_budget);
    return ctx.exec_ctx.remaining;
}

fn helperSetReturnData(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_SET_RETURN_DATA_PER_BYTE);
    try ctx.requireFeature(ctx.features.return_data);
    const bytes = try ctx.inputSlice(1, 2);
    if (bytes.len > MAX_RETURN_DATA_LEN) return error.InvalidInstructionData;
    try ctx.charge(HELPER_MISC_COST + @as(u64, @intCast(bytes.len)));
    try ctx.exec_ctx.setReturnData(bytes);
    return 0;
}

fn helperGetReturnData(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_MISC_COST);
    try ctx.requireFeature(ctx.features.return_data);
    const return_data = ctx.exec_ctx.returnDataSlice();
    const dst = try ctx.stackSliceRW(1, 2);
    const copy_len = @min(return_data.len, dst.len);
    try ctx.charge(@as(u64, @intCast(copy_len)));
    if (copy_len > 0) {
        @memcpy(dst[0..copy_len], return_data[0..copy_len]);
    }
    return copy_len;
}

const ParsedCpiInvocation = struct {
    callee_account_index: usize,
    account_count: usize,
    account_indices: [MAX_CPI_ACCOUNTS]usize,
    account_signers: [MAX_CPI_ACCOUNTS]bool,
    account_writables: [MAX_CPI_ACCOUNTS]bool,
    data: []const u8,
};

fn parseCpiInvocation(raw: []const u8, account_len: usize) Error!ParsedCpiInvocation {
    if (raw.len < 2) return error.InvalidInstructionData;
    var offset: usize = 0;
    const callee_account_index = try asIndex(raw[offset]);
    offset += 1;
    if (callee_account_index >= account_len) return error.InvalidAccountIndex;

    const input_count = raw[offset];
    offset += 1;
    if (input_count == 0) return error.InvalidInstructionData;
    if (input_count > MAX_CPI_ACCOUNTS) return error.InvalidInstructionData;

    var parsed = ParsedCpiInvocation{
        .callee_account_index = callee_account_index,
        .account_count = 0,
        .account_indices = [_]usize{0} ** MAX_CPI_ACCOUNTS,
        .account_signers = [_]bool{false} ** MAX_CPI_ACCOUNTS,
        .account_writables = [_]bool{false} ** MAX_CPI_ACCOUNTS,
        .data = &[_]u8{},
    };

    var idx_u8: usize = 0;
    while (idx_u8 < input_count) : (idx_u8 += 1) {
        if (offset + 2 > raw.len) return error.InvalidInstructionData;
        const account_index = try asIndex(raw[offset]);
        offset += 1;
        const flags = raw[offset];
        offset += 1;
        if (account_index >= account_len) return error.InvalidAccountIndex;
        parsed.account_indices[parsed.account_count] = account_index;
        parsed.account_signers[parsed.account_count] = (flags & CPI_META_SIGNER) != 0;
        parsed.account_writables[parsed.account_count] = (flags & CPI_META_WRITABLE) != 0;
        parsed.account_count += 1;
    }

    if (offset + 4 > raw.len) return error.InvalidInstructionData;
    const data_len = try asAllocSize(readLE(u32, raw, offset));
    offset += 4;
    if (offset + data_len > raw.len) return error.InvalidInstructionData;
    parsed.data = raw[offset .. offset + data_len];
    if (offset + data_len != raw.len) return error.InvalidInstructionData;
    return parsed;
}

fn helperMemcmp(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_MEMCMP_COST_BASE);
    try ctx.requireFeature(ctx.features.memcmp);
    const lhs = try ctx.stackSliceRO(1, 3);
    const rhs = try ctx.stackSliceRO(2, 3);
    if (lhs.len == 0 and rhs.len == 0) return 0;
    if (lhs.len != rhs.len) return 1;
    try ctx.charge(HELPER_MEMCMP_COST_PER_BYTE * @as(u64, @intCast(lhs.len + rhs.len)));

    var i: usize = 0;
    while (i < lhs.len) : (i += 1) {
        if (lhs[i] != rhs[i]) return 1;
    }

    return 0;
}

fn helperSha256(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_HASH_COST_BASE);
    try ctx.requireFeature(ctx.features.sha256);
    const bytes = try ctx.inputSlice(1, 2);
    if (bytes.len == 0) {
        try ctx.charge(1);
        try ctx.exec_ctx.setReturnData(&.{});
        return 0;
    }

    const hash_cost = COST_PER_HASH_BYTE * @as(u64, @intCast(bytes.len));
    try ctx.charge(hash_cost);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    if (digest.len > MAX_RETURN_DATA_LEN) return error.InvalidInstructionData;
    try ctx.exec_ctx.setReturnData(&digest);
    return 0;
}

fn helperInvoke(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_INVOKE_COST + HELPER_CPI_OVERHEAD);
    try ctx.requireFeature(ctx.features.cpi);
    const cpi_raw = try ctx.inputSlice(1, 2);
    const parsed = try parseCpiInvocation(cpi_raw, ctx.accounts.len);

    var normalized_count: usize = 0;
    var normalized_parent_indices: [MAX_CPI_ACCOUNTS]usize = undefined;
    var normalized_signers: [MAX_CPI_ACCOUNTS]bool = [_]bool{false} ** MAX_CPI_ACCOUNTS;
    var normalized_writables: [MAX_CPI_ACCOUNTS]bool = [_]bool{false} ** MAX_CPI_ACCOUNTS;
    var normalized_locks: [MAX_CPI_ACCOUNTS]InvokeLock = undefined;
    var callee_child_index: ?usize = null;

    var i: usize = 0;
    while (i < parsed.account_count) : (i += 1) {
        const parent_index = parsed.account_indices[i];
        const parent_ref = ctx.accounts[parent_index];
        const requested_writable = parsed.account_writables[i];
        const requested_signer = parsed.account_signers[i];

        if (requested_writable and !parent_ref.is_writable) return error.InvalidAccountLayout;
        if (requested_signer and !parent_ref.is_signer) return error.Unauthorized;

        var existing: ?usize = null;
        var n: usize = 0;
        while (n < normalized_count) : (n += 1) {
            const known_key = ctx.accounts[normalized_parent_indices[n]].key;
            if (isSamePubkey(&parent_ref.key, &known_key)) {
                existing = n;
                break;
            }
        }

        if (existing) |n_idx| {
            if (normalized_writables[n_idx] != requested_writable) return error.InvalidAccountLayout;
            normalized_signers[n_idx] = normalized_signers[n_idx] or requested_signer;
            continue;
        }

        if (normalized_count >= MAX_CPI_ACCOUNTS) return error.InvalidInstructionData;
        normalized_parent_indices[normalized_count] = parent_index;
        normalized_writables[normalized_count] = requested_writable;
        normalized_signers[normalized_count] = requested_signer;
        normalized_locks[normalized_count] = .{
            .key = parent_ref.key,
            .mode = if (requested_writable) .writable else .readonly,
        };
        if (parent_index == parsed.callee_account_index) {
            callee_child_index = normalized_count;
        }
        normalized_count += 1;
    }

    const child_callee_index = callee_child_index orelse return error.InvalidAccountIndex;
    try ctx.exec_ctx.enterNestedFrameWithLocks(normalized_locks[0..normalized_count]);
    defer ctx.exec_ctx.exitNestedFrame();

    var child_refs: [MAX_CPI_ACCOUNTS]AccountRef = undefined;
    var child_data: [MAX_CPI_ACCOUNTS][]u8 = [_][]u8{&[_]u8{}} ** MAX_CPI_ACCOUNTS;
    var child_lamports: [MAX_CPI_ACCOUNTS]u64 = [_]u64{0} ** MAX_CPI_ACCOUNTS;
    var child_owner: [MAX_CPI_ACCOUNTS]types.Pubkey = [_]types.Pubkey{.{ .bytes = [_]u8{0} ** 32 }} ** MAX_CPI_ACCOUNTS;
    const child_parent_indices: [MAX_CPI_ACCOUNTS]usize = normalized_parent_indices;
    var child_data_owned: [MAX_CPI_ACCOUNTS]bool = [_]bool{false} ** MAX_CPI_ACCOUNTS;

    var m: usize = 0;
    while (m < normalized_count) : (m += 1) {
        const parent_index = normalized_parent_indices[m];
        const parent_ref = ctx.accounts[parent_index];
        child_data[m] = try ctx.allocator.dupe(u8, parent_ref.data.*);
        child_lamports[m] = parent_ref.lamports.*;
        child_owner[m] = parent_ref.owner.*;
        child_refs[m] = .{
            .key = parent_ref.key,
            .lamports = &child_lamports[m],
            .data = &child_data[m],
            .owner = &child_owner[m],
            .executable = parent_ref.executable,
            .is_signer = normalized_signers[m],
            .is_writable = normalized_writables[m],
        };
    }

    defer {
        var f: usize = 0;
        while (f < normalized_count) : (f += 1) {
            if (!child_data_owned[f] and child_data[f].len > 0) ctx.allocator.free(child_data[f]);
        }
    }

    const callee_ref = child_refs[child_callee_index];
    if (!callee_ref.executable) return error.InvalidAccountLayout;
    if (normalized_writables[child_callee_index]) return error.InvalidAccountLayout;
    if (!isSamePubkey(callee_ref.owner, &ID)) return error.Unauthorized;

    const child_result = try executeProgramWithFeaturesAndBudgetDetailed(
        callee_ref,
        child_refs[0..normalized_count],
        parsed.data,
        ctx.slot,
        ctx.allocator,
        ctx.exec_ctx.remaining,
        ctx.features,
    );
    if (child_result.exit_code != 0) return error.ProgramFailed;
    ctx.exec_ctx.promoteNestedReturnData();

    var c: usize = 0;
    while (c < normalized_count) : (c += 1) {
        if (!normalized_writables[c]) continue;

        const parent_index = child_parent_indices[c];
        const parent_ref = &ctx.accounts[parent_index];
        const child_ref = child_refs[c];
        const child_slice = child_data[c];

        parent_ref.lamports.* = child_ref.lamports.*;
        parent_ref.owner.* = child_owner[c];
        if (parent_ref.data.len != child_slice.len) {
            if (parent_ref.data.len > 0) ctx.allocator.free(parent_ref.data.*);
            parent_ref.data.* = child_slice;
            child_data_owned[c] = true;
            continue;
        }

        if (child_slice.len > 0) @memcpy(parent_ref.data.*[0..], child_slice);
        ctx.allocator.free(child_data[c]);
        child_data_owned[c] = true;
    }

    return 0;
}

fn verifyEbpfProgram(code: []const u8) Error!void {
    if (code.len == 0) return error.InvalidProgramFormat;
    if (code.len % 8 != 0) return error.InvalidProgramFormat;

    const insn_count = code.len / 8;
    if (insn_count > MAX_INSTRUCTIONS) return error.InvalidProgramFormat;

    var pc: usize = 0;
    while (pc < insn_count) {
        const base = pc * 8;
        const opcode = code[base];
        const dst_src = code[base + 1];
        const off = readLE(i16, code, base + 2);
        const imm = readLE(i32, code, base + 4);

        const class = opcode & 0x07;
        const op = opcode & 0xf0;
        const mode = opcode & BPF_MODE_MASK;
        const size = opcode & BPF_SIZE_MASK;
        const dst = dst_src & 0x0f;
        const src = (dst_src >> 4) & 0x0f;

        if (dst > 10 or src > 10) return error.InvalidInstruction;

        // Destinations cannot write through r10 (frame pointer / stack pointer).
        switch (class) {
            BPF_LD => {},
            BPF_LDX => {},
            BPF_ST => {
                if (dst == 10) return error.InvalidInstruction;
            },
            BPF_STX => {
                if (dst == 10) return error.InvalidInstruction;
            },
            BPF_ALU, BPF_ALU64 => {},
            BPF_JMP, BPF_JMP32 => {},
            else => return error.UnsupportedOpcode,
        }

        switch (class) {
            BPF_LD,
            BPF_LDX,
            BPF_ST,
            BPF_STX => _ = sizeToBytes(size) catch return error.InvalidInstruction,
            else => {},
        }

    switch (class) {
        BPF_LD => {
                if (mode == BPF_DW) {
                    if (pc + 1 >= insn_count) return error.InvalidInstruction;
                    const next_opcode = code[(pc + 1) * 8];
                    const next_imm = readLE(u32, code, (pc + 1) * 8 + 4);
                    _ = next_imm;
                    // Reject non-imm pseudo load.
                    if (next_opcode != 0x00 or (next_opcode & 0x07) != BPF_LD or (next_opcode & BPF_IMM) != BPF_IMM) {
                        return error.InvalidInstruction;
                    }
                }
            },
            BPF_JMP, BPF_JMP32 => {
                const jump_opcode = op;
                if (jump_opcode == BPF_CALL) {
                    const helper = @as(u64, @bitCast(@as(i64, imm)));
                    if (helper == 0) return error.InvalidInstructionData;
                    if (!isSupportedHelper(helper)) return error.UnsupportedHelper;
                } else if (jump_opcode == BPF_JA) {
                    if (!jumpOffsetInRange(pc, off, insn_count, code)) return error.InvalidInstruction;
                } else if (jump_opcode <= BPF_JSLE) {
                    if (!jumpOffsetInRange(pc, off, insn_count, code)) return error.InvalidInstruction;
                } else if (jump_opcode != BPF_EXIT) {
                    return error.UnsupportedOpcode;
                }
            },
            else => {},
        }

        pc += 1;
    }
}

fn jumpOffsetInRange(pc: usize, off: i16, insn_count: usize, code: []const u8) bool {
    const base = @as(isize, @intCast(pc));
    const target = base + 1 + @as(isize, off);
    if (target < 0) return false;
    const target_usize = @as(usize, @intCast(target));
    if (target_usize >= insn_count) return false;
    if (isJumpIntoLdDwordSecondHalf(target_usize, code)) return false;
    return true;
}

fn isJumpIntoLdDwordSecondHalf(target: usize, code: []const u8) bool {
    if (target == 0) return false;
    const prev_base = (target - 1) * 8;
    if (prev_base + 8 > code.len) return false;
    const prev_opcode = code[prev_base];
    if ((prev_opcode & 0x07) != BPF_LD) return false;
    return (prev_opcode & BPF_MODE_MASK) == BPF_DW;
}

fn helperTransfer(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_TRANSFER_COST);
    if (ctx.accounts.len == 0) return error.InvalidAccountLayout;
    const src = try ctx.accessorRW(1);
    const dst = try ctx.accessorRW(2);
    const amount = try ctx.reg(3);

    if (amount == 0) return 0;
    try src.requireSigner();
    try src.requireWritable();
    try dst.requireWritable();
    if (src.lamports.* < amount) return error.InvalidInstruction;

    src.lamports.* -= amount;
    dst.lamports.* +|= amount;
    return 0;
}

fn helperResize(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_RESIZE_COST);
    const account = try ctx.accessorRW(1);
    const size = try asAllocSize(try ctx.reg(2));
    try ctx.charge(HELPER_RESIZE_COST + @as(u64, @intCast(size)));

    const next = try ctx.allocator.alloc(u8, size);
    @memset(next, 0);
    const keep = @min(size, account.data.*.len);
    @memcpy(next[0..keep], account.data.*[0..keep]);
    if (account.data.*.len > 0) ctx.allocator.free(account.data.*);
    account.data.* = next;
    return 0;
}

fn helperSetData(ctx: *HelperContext) Error!u64 {
    try ctx.charge(HELPER_MISC_COST);
    const account = try ctx.accessorRW(1);
    const bytes = try ctx.inputSlice(2, 3);
    try ctx.charge(HELPER_SET_DATA_PER_BYTE * @as(u64, @intCast(bytes.len)));

    const next = try ctx.allocator.alloc(u8, bytes.len);
    @memset(next, 0);
    @memcpy(next, bytes);
    if (account.data.*.len > 0) ctx.allocator.free(account.data.*);
    account.data.* = next;
    return 0;
}

fn asIndex(v: u64) Error!usize {
    if (v > std.math.maxInt(usize)) return error.InvalidInstructionData;
    return @intCast(v);
}

fn asAllocSize(v: u64) Error!usize {
    if (v > std.math.maxInt(usize)) return error.InvalidInstructionData;
    return @intCast(v);
}

fn isSamePubkey(a: *const types.Pubkey, b: *const types.Pubkey) bool {
    return std.mem.eql(u8, a.bytes[0..], b.bytes[0..]);
}

fn translateSliceBounds(start_v: u64, len_v: u64, upper: usize) Error!SliceRange {
    const start = try asIndex(start_v);
    const len = try asAllocSize(len_v);
    const end = try addWithOverflow(start, len);
    if (end > upper) return error.InvalidInstructionData;
    return .{ .start = start, .end = end };
}

fn extractElfText(raw: []const u8) ![]const u8 {
    if (raw.len < 64) return error.InvalidProgramFormat;
    if (!std.mem.eql(u8, raw[0..4], &ElfMagic)) return error.InvalidProgramFormat;
    if (raw[4] != ELF_CLASS_64) return error.InvalidProgramFormat;

    const phoff = readLE(u64, raw, 32);
    const phentsize = readLE(u16, raw, 54);
    const phnum = readLE(u16, raw, 56);
    if (phoff == 0) return error.InvalidProgramFormat;
    if (phentsize == 0) return error.InvalidProgramFormat;
    if (phentsize < 40) return error.InvalidProgramFormat;
    if (phoff + (@as(u64, phentsize) * phnum) > raw.len) return error.InvalidProgramFormat;

    const phoff_usize = try asAllocSize(phoff);
    const phentsize_usize = try asAllocSize(phentsize);
    const phnum_usize = try asAllocSize(phnum);

    var i: usize = 0;
    while (i < phnum_usize) : (i += 1) {
        const base = phoff_usize + (i * phentsize_usize);
        if (base + phentsize_usize > raw.len) return error.InvalidProgramFormat;

        const ptype = readLE32(raw, base);
        if (ptype != PT_LOAD) continue;

        const pflags = readLE32(raw, base + 4);
        if ((pflags & PF_X) == 0) continue;

        const p_offset = readLE64(raw, base + 8);
        const p_filesz = readLE64(raw, base + 32);
        if (p_filesz == 0) continue;

        const code_start = try asAllocSize(p_offset);
        const code_size = try asAllocSize(p_filesz);
        const code_end = try addWithOverflow(code_start, code_size);
        if (code_end > raw.len) return error.InvalidProgramFormat;
        return raw[code_start..code_end];
    }

    return error.InvalidProgramFormat;
}

fn readLE(comptime T: type, raw: []const u8, start: usize) T {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    var bytes: [size]u8 = undefined;
    @memcpy(&bytes, raw[start .. start + size]);
    return std.mem.readInt(T, &bytes, .little);
}

fn readLE32(raw: []const u8, offset: usize) u32 {
    return readLE(u32, raw, offset);
}

fn readLE64(raw: []const u8, offset: usize) u64 {
    return readLE(u64, raw, offset);
}

fn addWithOverflow(a: usize, b: usize) Error!usize {
    const sum = a + b;
    if (sum < a or sum < b) return error.InvalidInstructionData;
    return sum;
}

test "bpf loader write instruction stages bytes into target account" {
    var payer: u64 = 0;
    var program: u64 = 0;
    const payer_owner = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    const prog_owner = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    var payer_data = try std.testing.allocator.dupe(u8, &[_]u8{0, 0, 0, 0});
    defer std.testing.allocator.free(payer_data);
    var prog_data = try std.testing.allocator.dupe(u8, &[_]u8{0} ** 16);
    defer std.testing.allocator.free(prog_data);

    const payer_ref = AccountRef{
        .key = .{ .bytes = [_]u8{7} ** 32 },
        .lamports = &payer,
        .data = &payer_data,
        .owner = &payer_owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };
    const prog_ref = AccountRef{
        .key = .{ .bytes = [_]u8{8} ** 32 },
        .lamports = &program,
        .data = &prog_data,
        .owner = &prog_owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };
    const payload = [_]u8{ 9, 8, 7, 6 };
    var ix: [8 + payload.len]u8 = undefined;
    std.mem.writeInt(u32, ix[0..4], @intFromEnum(InstructionTag.write), .little);
    std.mem.writeInt(u32, ix[4..8], 4, .little);
    @memcpy(ix[8..], &payload);

    try executeLoader(&[_]AccountRef{ payer_ref, prog_ref }, ix[0..], 0, std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 9, 8, 7, 6 }, prog_ref.data.*);
}

test "bpf vm executes bytecode transfer instruction" {
    const loader_owner = ID;
    var lamports: [2]u64 = .{ 50, 1 };
    const owner = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    const code = blk: {
        var bytes: [56]u8 = undefined;
        @memset(&bytes, 0);
        @memcpy(bytes[0..4], SBF_MAGIC[0..4]);

        var p: usize = 4;
        // r1 = 0
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x01;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        p += 8;

        // r2 = 1
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x02;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 1, .little);
        p += 8;

        // r3 = 10
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x03;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 10, .little);
        p += 8;

        // helper transfer
        bytes[p + 0] = 0x85;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], @intCast(BPF_HELPER_TRANSFER), .little);
        p += 8;

        // exit
        bytes[p + 0] = 0x95;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);

        break :blk bytes;
    };
    const empty = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(empty);

    var prog_data = try std.testing.allocator.dupe(u8, &code);
    defer std.testing.allocator.free(prog_data);
    var from_data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(from_data);
    var to_data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(to_data);

    const from_ref = AccountRef{
        .key = .{ .bytes = [_]u8{11} ** 32 },
        .lamports = &lamports[0],
        .data = &from_data,
        .owner = &owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };
    const to_ref = AccountRef{
        .key = .{ .bytes = [_]u8{22} ** 32 },
        .lamports = &lamports[1],
        .data = &to_data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = true,
    };
    const program_ref = AccountRef{
        .key = .{ .bytes = [_]u8{33} ** 32 },
        .lamports = &lamports[0],
        .data = &prog_data,
        .owner = &loader_owner,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };

    try executeProgram(program_ref, &[_]AccountRef{ from_ref, to_ref }, &.{}, 0, std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 40), from_ref.lamports.*);
    try std.testing.expectEqual(@as(u64, 11), to_ref.lamports.*);
}

test "helper context exposes sysvar marker" {
    const sysvar_owner = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    var prog_lamports: u64 = 100;
    var sysvar_data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(sysvar_data);

    const clock_ref = AccountRef{
        .key = sysvar.CLOCK_ID,
        .lamports = &prog_lamports,
        .data = &sysvar_data,
        .owner = &sysvar_owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    var accounts = [_]AccountRef{clock_ref};
    const ix_data = &[_]u8{};
    var stack = [_]u8{0} ** STACK_BYTES;
    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &accounts, stack[0..], ix_data, 1, &exec_ctx, std.testing.allocator, .{});
    try std.testing.expectEqual(@as(u64, 1), try helperIsSysvar(&ctx));
}

test "sysvar writable access via helper is rejected" {
    const sysvar_owner = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    var program_lamports: u64 = 0;
    var sysvar_lamports: u64 = 10;
    const code = blk: {
        var insns: [32]u8 = undefined;
        @memset(&insns, 0);
        @memcpy(insns[0..4], SBF_MAGIC[0..4]);

        var p: usize = 4;
        insns[p + 0] = 0xb7;
        insns[p + 1] = 0x01;
        std.mem.writeInt(i16, insns[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, insns[p + 4 .. p + 8], 0, .little);
        p += 8;

        insns[p + 0] = 0xb7;
        insns[p + 1] = 0x02;
        std.mem.writeInt(i16, insns[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, insns[p + 4 .. p + 8], 8, .little);
        p += 8;

        insns[p + 0] = 0x85;
        insns[p + 1] = 0x00;
        std.mem.writeInt(i16, insns[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, insns[p + 4 .. p + 8], @intCast(BPF_HELPER_RESIZE), .little);
        p += 8;

        insns[p + 0] = 0x95;
        insns[p + 1] = 0x00;
        std.mem.writeInt(i16, insns[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, insns[p + 4 .. p + 8], 0, .little);

        break :blk insns;
    };

    var program_data = try std.testing.allocator.dupe(u8, &code);
    defer std.testing.allocator.free(program_data);

    const program_ref = AccountRef{
        .key = .{ .bytes = [_]u8{33} ** 32 },
        .lamports = &program_lamports,
        .data = &program_data,
        .owner = &sysvar_owner,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    var sysvar_data = try std.testing.allocator.dupe(u8, &[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    defer std.testing.allocator.free(sysvar_data);

    const sysvar_acc = AccountRef{
        .key = sysvar.CLOCK_ID,
        .lamports = &sysvar_lamports,
        .data = &sysvar_data,
        .owner = &sysvar_owner,
        .executable = false,
        .is_signer = false,
        .is_writable = true,
    };

    try std.testing.expectError(error.InvalidAccountLayout, executeProgramWithFeatures(program_ref, &[_]AccountRef{sysvar_acc}, &.{}, 0, std.testing.allocator, .{}));
}

test "helper log uses explicit stack marshalling" {
    const owner = types.Pubkey{ .bytes = [_]u8{5} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);

    const account = AccountRef{
        .key = .{ .bytes = [_]u8{7} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    regs[1] = 16;
    regs[2] = 4;

    var accounts = [_]AccountRef{account};
    var stack = [_]u8{0} ** STACK_BYTES;
    @memcpy(stack[16..20], "log!");

    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{}, 123, &exec_ctx, std.testing.allocator, .{ .logs = true });
    try std.testing.expectEqual(@as(u64, 0), try helperLog(&ctx));
    @memset(stack[16..20], 0);
    @memset(stack[21..32], 0xAA);
    @memset(stack[30..32], 0);
    regs[1] = 16;
    regs[2] = 0;
    stack[21] = 'x';
    stack[22] = 'y';
    stack[23] = 0;
    try std.testing.expectEqual(@as(u64, 0), try helperLog(&ctx));
    try std.testing.expectEqual(@as(u8, 0), stack[20]);

    regs[1] = STACK_BYTES;
    regs[2] = 1;
    try std.testing.expectError(error.InvalidInstructionData, helperLog(&ctx));
}

test "helper log rejects unterminated c-string" {
    const owner = types.Pubkey{ .bytes = [_]u8{6} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);

    const account = AccountRef{
        .key = .{ .bytes = [_]u8{8} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    regs[1] = 4;
    regs[2] = 0;

    var stack = [_]u8{0x41} ** STACK_BYTES;

    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &[_]AccountRef{account}, stack[0..], &[_]u8{}, 7, &exec_ctx, std.testing.allocator, .{ .logs = true });
    try std.testing.expectError(error.InvalidInstructionData, helperLog(&ctx));
}

test "helper get-key-bytes truncates to output length and preserves tail" {
    const owner = types.Pubkey{ .bytes = [_]u8{0x22} ** 32 };
    const key = types.Pubkey{ .bytes = [_]u8{0x55} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);

    const account = AccountRef{
        .key = key,
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    regs[1] = 0;
    regs[2] = 16;
    regs[3] = 8;
    var accounts = [_]AccountRef{account};
    var stack = [_]u8{0xAA} ** STACK_BYTES;

    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{}, 0, &exec_ctx, std.testing.allocator, .{ .key_serialization = true });
    try std.testing.expectEqual(@as(u64, 8), try helperGetKeyBytes(&ctx));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x55} ** 8, stack[16 .. 24]);
    try std.testing.expectEqual(@as(u8, 0xAA), stack[24]);
}

test "return data copy does not overwrite destination past copied bytes" {
    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);
    const owner = types.Pubkey{ .bytes = [_]u8{3} ** 32 };
    const account = AccountRef{
        .key = .{ .bytes = [_]u8{9} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    var stack = [_]u8{0} ** STACK_BYTES;
    @memset(stack[24..32], 0xAA);
    regs[1] = 24;
    regs[2] = 8;

    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &[_]AccountRef{account}, stack[0..], &[_]u8{}, 2, &exec_ctx, std.testing.allocator, .{ .return_data = true });
    try exec_ctx.setReturnData(&[_]u8{ 9, 8, 7 });

    try std.testing.expectEqual(@as(u64, 3), try helperGetReturnData(&ctx));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA }, stack[24..32]);
}

test "return data copy truncates when destination is shorter than source" {
    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);
    const owner = types.Pubkey{ .bytes = [_]u8{4} ** 32 };
    const account = AccountRef{
        .key = .{ .bytes = [_]u8{10} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    var stack = [_]u8{0x55} ** STACK_BYTES;
    regs[1] = 40;
    regs[2] = 3;

    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &[_]AccountRef{account}, stack[0..], &[_]u8{}, 2, &exec_ctx, std.testing.allocator, .{ .return_data = true });
    try exec_ctx.setReturnData(&[_]u8{ 9, 8, 7, 6 });

    try std.testing.expectEqual(@as(u64, 3), try helperGetReturnData(&ctx));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 9, 8, 7, 0x55, 0x55, 0x55 }, stack[40..46]);
}

test "set_return_data fails without clobbering existing return data on error" {
    const owner = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);

    const account = AccountRef{
        .key = .{ .bytes = [_]u8{2} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    regs[1] = 0;
    regs[2] = MAX_RETURN_DATA_LEN + 1;
    var stack = [_]u8{0} ** STACK_BYTES;
    const big_data = try std.testing.allocator.alloc(u8, MAX_RETURN_DATA_LEN + 1);
    defer std.testing.allocator.free(big_data);
    @memset(big_data, 0x77);

    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &[_]AccountRef{account}, stack[0..], big_data, 2, &exec_ctx, std.testing.allocator, .{ .return_data = true });
    try exec_ctx.setReturnData(&[_]u8{ 0x22, 0x22 });

    try std.testing.expectError(error.InvalidInstructionData, helperSetReturnData(&ctx));
    try std.testing.expectEqual(@as(usize, 2), exec_ctx.returnDataSlice().len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x22, 0x22}, exec_ctx.returnDataSlice()[0..2]);
    try std.testing.expectEqual(@as(u8, 0x22), exec_ctx.returnDataSlice()[3]);
}

test "return data zero-length write clears previous frame data" {
    const owner = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);

    const account = AccountRef{
        .key = .{ .bytes = [_]u8{3} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var set_regs = [_]u64{0} ** MAX_REGS;
    var get_regs = [_]u64{0} ** MAX_REGS;
    set_regs[1] = 0;
    set_regs[2] = 0;
    get_regs[1] = 64;
    get_regs[2] = 4;

    var stack = [_]u8{0xAA} ** STACK_BYTES;
    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var set_ctx = HelperContext.init(&set_regs, &[_]AccountRef{account}, stack[0..], &[_]u8{}, 2, &exec_ctx, std.testing.allocator, .{ .return_data = true });
    var get_ctx = HelperContext.init(&get_regs, &[_]AccountRef{account}, stack[0..], &[_]u8{}, 2, &exec_ctx, std.testing.allocator, .{ .return_data = true });

    try exec_ctx.setReturnData(&[_]u8{0xFF});
    try std.testing.expectEqual(@as(u64, 0), try helperSetReturnData(&set_ctx));
    try std.testing.expectEqual(@as(u64, 0), try helperGetReturnData(&get_ctx));
    try std.testing.expectEqual(@as(u8, 0xAA), stack[64]);
    try std.testing.expectEqual(@as(usize, 0), exec_ctx.returnDataSlice().len);
}

test "return data unavailable returns zero-length copy" {
    const owner = types.Pubkey{ .bytes = [_]u8{4} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);

    const account = AccountRef{
        .key = .{ .bytes = [_]u8{5} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    regs[1] = 32;
    regs[2] = 4;
    var stack = [_]u8{0xEE} ** STACK_BYTES;
    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &[_]AccountRef{account}, stack[0..], &[_]u8{}, 2, &exec_ctx, std.testing.allocator, .{ .return_data = true });

    try std.testing.expectEqual(@as(u64, 0), try helperGetReturnData(&ctx));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xEE} ** 4, stack[32..36]);
}

test "child return data is visible to parent via shared invoke-frame context" {
    const owner = types.Pubkey{ .bytes = [_]u8{7} ** 32 };
    const child_value = [_]u8{ 'p', 'o', 'n', 'g' };

    var parent_lamports: u64 = 0;
    var child_lamports: u64 = 0;

    var child_prog = blk: {
        var bytes: [40]u8 = undefined;
        @memset(&bytes, 0);
        @memcpy(bytes[0..4], SBF_MAGIC[0..4]);

        var p: usize = 4;
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x01;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x02;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], child_value.len, .little);
        p += 8;

        bytes[p + 0] = 0x85;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], @intCast(BPF_HELPER_SET_RETURN_DATA), .little);
        p += 8;

        bytes[p + 0] = 0x95;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        break :blk bytes[0 .. p + 8];
    };

    var child_prog_data = try std.testing.allocator.dupe(u8, &child_prog);
    defer std.testing.allocator.free(child_prog_data);

    var parent_prog_data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(parent_prog_data);
    const child_ref = AccountRef{
        .key = .{ .bytes = [_]u8{34} ** 32 },
        .lamports = &child_lamports,
        .data = &child_prog_data,
        .owner = &ID,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    const parent_ref = AccountRef{
        .key = .{ .bytes = [_]u8{33} ** 32 },
        .lamports = &parent_lamports,
        .data = &parent_prog_data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var cpi_payload = [_]u8{0} ** 12;
    cpi_payload[0] = 1;
    cpi_payload[1] = 1;
    cpi_payload[2] = 1;
    cpi_payload[3] = 0;
    std.mem.writeInt(u32, cpi_payload[4..8], child_value.len, .little);
    @memcpy(cpi_payload[8..12], &child_value);

    var regs = [_]u64{0} ** MAX_REGS;
    regs[1] = 0;
    regs[2] = cpi_payload.len;

    var stack = [_]u8{0xAA} ** STACK_BYTES;
    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var parent_ctx = HelperContext.init(&regs, &[_]AccountRef{ parent_ref, child_ref }, stack[0..], &cpi_payload, 0, &exec_ctx, std.testing.allocator, .{ .cpi = true, .return_data = true });
    try std.testing.expectEqual(@as(u64, 0), try helperInvoke(&parent_ctx));

    regs[1] = 16;
    regs[2] = 8;
    try std.testing.expectEqual(@as(u64, 4), try helperGetReturnData(&parent_ctx));
    try std.testing.expectEqualSlices(u8, &child_value, stack[16 .. 20]);

    try std.testing.expectEqualSlices(u8, &child_value, exec_ctx.returnDataSlice());
}

test "helperInvoke commits writable child account mutations" {
    var parent_lamports: u64 = 1;
    var child_lamports: u64 = 1;
    var source_lamports: u64 = 5;

    const parent_owner = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    const owner = types.Pubkey{ .bytes = [_]u8{3} ** 32 };

    const parent_program = blk: {
        var bytes: [56]u8 = undefined;
        @memset(&bytes, 0);
        @memcpy(bytes[0..4], SBF_MAGIC[0..4]);

        var p: usize = 4;
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x01;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x02;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 12, .little);
        p += 8;

        bytes[p + 0] = 0x85;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], @intCast(BPF_HELPER_INVOKE), .little);
        p += 8;

        bytes[p + 0] = 0x95;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        break :blk bytes[0 .. p + 8];
    };

    const child_program = blk: {
        var bytes: [56]u8 = undefined;
        @memset(&bytes, 0);
        @memcpy(bytes[0..4], SBF_MAGIC[0..4]);

        var p: usize = 4;
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x01;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 1, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x02;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x03;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 2, .little);
        p += 8;

        bytes[p + 0] = 0x85;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], @intCast(BPF_HELPER_SET_DATA), .little);
        p += 8;

        bytes[p + 0] = 0x95;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        p += 8;

        break :blk bytes[0 .. p + 8];
    };

    const child_payload = [_]u8{ 'o', 'k' };
    var invoke_payload = [_]u8{
        1, // callee account index
        2, // account count
        1, 0,
        2, CPI_META_WRITABLE,
        0, 0, 0, 0,
        child_payload[0],
        child_payload[1],
    };
    std.mem.writeInt(u32, invoke_payload[6 .. 10], child_payload.len, .little);

    var parent_prog_data = try std.testing.allocator.dupe(u8, &parent_program);
    defer std.testing.allocator.free(parent_prog_data);
    var child_prog_data = try std.testing.allocator.dupe(u8, &child_program);
    defer std.testing.allocator.free(child_prog_data);
    var source_data = try std.testing.allocator.dupe(u8, &[_]u8{ 9, 9 });
    defer std.testing.allocator.free(source_data);

    const parent_ref = AccountRef{
        .key = .{ .bytes = [_]u8{10} ** 32 },
        .lamports = &parent_lamports,
        .data = &parent_prog_data,
        .owner = &parent_owner,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    const child_ref = AccountRef{
        .key = .{ .bytes = [_]u8{11} ** 32 },
        .lamports = &child_lamports,
        .data = &child_prog_data,
        .owner = &ID,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    const source_ref = AccountRef{
        .key = .{ .bytes = [_]u8{12} ** 32 },
        .lamports = &source_lamports,
        .data = &source_data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = true,
    };

    try executeProgramWithFeatures(
        parent_ref,
        &[_]AccountRef{ parent_ref, child_ref, source_ref },
        &invoke_payload,
        0,
        std.testing.allocator,
        .{ .cpi = true },
    );
    try std.testing.expectEqualSlices(u8, &child_payload, source_ref.data.*);
}

test "helperInvoke returns ProgramFailed and rolls back writable child writes on child failure" {
    var parent_lamports: u64 = 1;
    var child_lamports: u64 = 1;
    var source_lamports: u64 = 5;

    const parent_owner = types.Pubkey{ .bytes = [_]u8{2} ** 32 };
    const owner = types.Pubkey{ .bytes = [_]u8{3} ** 32 };

    const parent_program = blk: {
        var bytes: [56]u8 = undefined;
        @memset(&bytes, 0);
        @memcpy(bytes[0..4], SBF_MAGIC[0..4]);

        var p: usize = 4;
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x01;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x02;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 12, .little);
        p += 8;

        bytes[p + 0] = 0x85;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], @intCast(BPF_HELPER_INVOKE), .little);
        p += 8;

        bytes[p + 0] = 0x95;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        break :blk bytes[0 .. p + 8];
    };

    const child_program = blk: {
        var bytes: [56]u8 = undefined;
        @memset(&bytes, 0);
        @memcpy(bytes[0..4], SBF_MAGIC[0..4]);

        var p: usize = 4;
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x01;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 1, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x02;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x03;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 2, .little);
        p += 8;

        bytes[p + 0] = 0x85;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], @intCast(BPF_HELPER_SET_DATA), .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 1, .little);
        p += 8;

        bytes[p + 0] = 0x95;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);

        break :blk bytes[0 .. p + 8];
    };

    var parent_prog_data = try std.testing.allocator.dupe(u8, &parent_program);
    defer std.testing.allocator.free(parent_prog_data);
    var child_prog_data = try std.testing.allocator.dupe(u8, &child_program);
    defer std.testing.allocator.free(child_prog_data);
    var source_data = try std.testing.allocator.dupe(u8, &[_]u8{ 9, 9 });
    defer std.testing.allocator.free(source_data);

    const parent_ref = AccountRef{
        .key = .{ .bytes = [_]u8{10} ** 32 },
        .lamports = &parent_lamports,
        .data = &parent_prog_data,
        .owner = &parent_owner,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    const child_ref = AccountRef{
        .key = .{ .bytes = [_]u8{11} ** 32 },
        .lamports = &child_lamports,
        .data = &child_prog_data,
        .owner = &ID,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    const source_ref = AccountRef{
        .key = .{ .bytes = [_]u8{12} ** 32 },
        .lamports = &source_lamports,
        .data = &source_data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = true,
    };

    const before = try std.testing.allocator.dupe(u8, source_data);
    defer std.testing.allocator.free(before);

    const child_payload = [_]u8{ 'x', 'x' };
    var invoke_payload = [_]u8{
        1, // callee account index
        2, // account count
        1, 0, // callee
        2, CPI_META_WRITABLE, // writable source
        0, 0, 0, 0,
        child_payload[0],
        child_payload[1],
    };
    std.mem.writeInt(u32, invoke_payload[6 .. 10], child_payload.len, .little);
    try std.testing.expectError(
        error.ProgramFailed,
        executeProgramWithFeatures(
            parent_ref,
            &[_]AccountRef{ parent_ref, child_ref, source_ref },
            &invoke_payload,
            0,
            std.testing.allocator,
            .{ .cpi = true },
        ),
    );
    try std.testing.expectEqualSlices(u8, before, source_ref.data.*);
}

test "helperInvoke propagates signer requirement to child accounts" {
    var payer_lamports: u64 = 10;
    var dest_lamports: u64 = 0;
    var parent_lamports: u64 = 1;
    var child_lamports: u64 = 1;

    const owner = types.Pubkey{ .bytes = [_]u8{3} ** 32 };

    const parent_program = blk: {
        var bytes: [56]u8 = undefined;
        @memset(&bytes, 0);
        @memcpy(bytes[0..4], SBF_MAGIC[0..4]);

        var p: usize = 4;
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x01;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x02;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 12, .little);
        p += 8;

        bytes[p + 0] = 0x85;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], @intCast(BPF_HELPER_INVOKE), .little);
        p += 8;

        bytes[p + 0] = 0x95;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        break :blk bytes[0 .. p + 8];
    };

    const child_program = blk: {
        var bytes: [56]u8 = undefined;
        @memset(&bytes, 0);
        @memcpy(bytes[0..4], SBF_MAGIC[0..4]);

        var p: usize = 4;
        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x01;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 1, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x02;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 2, .little);
        p += 8;

        bytes[p + 0] = 0xb7;
        bytes[p + 1] = 0x03;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 4, .little);
        p += 8;

        bytes[p + 0] = 0x85;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], @intCast(BPF_HELPER_TRANSFER), .little);
        p += 8;

        bytes[p + 0] = 0x95;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);

        break :blk bytes[0 .. p + 8];
    };

    var parent_prog_data = try std.testing.allocator.dupe(u8, &parent_program);
    defer std.testing.allocator.free(parent_prog_data);
    var child_prog_data = try std.testing.allocator.dupe(u8, &child_program);
    defer std.testing.allocator.free(child_prog_data);

    var payer_data = try std.testing.allocator.dupe(u8, &[_]u8{ 1, 2, 3 });
    defer std.testing.allocator.free(payer_data);
    var dest_data = try std.testing.allocator.dupe(u8, &[_]u8{ 4, 5, 6 });
    defer std.testing.allocator.free(dest_data);

    const parent_ref = AccountRef{
        .key = .{ .bytes = [_]u8{10} ** 32 },
        .lamports = &parent_lamports,
        .data = &parent_prog_data,
        .owner = &owner,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    const child_ref = AccountRef{
        .key = .{ .bytes = [_]u8{11} ** 32 },
        .lamports = &child_lamports,
        .data = &child_prog_data,
        .owner = &ID,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    const signer_payer_ref = AccountRef{
        .key = .{ .bytes = [_]u8{12} ** 32 },
        .lamports = &payer_lamports,
        .data = &payer_data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = true,
    };
    const to_ref = AccountRef{
        .key = .{ .bytes = [_]u8{13} ** 32 },
        .lamports = &dest_lamports,
        .data = &dest_data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = true,
    };

    var invoke_payload = [_]u8{
        1, // callee account index
        3, // account count
        1, 0, // callee
        2, CPI_META_WRITABLE | CPI_META_SIGNER, // signer + writable source
        3, CPI_META_WRITABLE, // writable destination
        0, 0, 0, 0, // data length
    };
    std.mem.writeInt(u32, invoke_payload[8 .. 12], 0, .little);

    try std.testing.expectError(
        error.Unauthorized,
        executeProgramWithFeatures(
            parent_ref,
            &[_]AccountRef{ parent_ref, child_ref, signer_payer_ref, to_ref },
            &invoke_payload,
            0,
            std.testing.allocator,
            .{ .cpi = true },
        ),
    );
    try std.testing.expectEqual(@as(u64, 10), payer_lamports);
    try std.testing.expectEqual(@as(u64, 0), dest_lamports);
}

test "helperInvoke enforces writable-readonly conflict against parent lock" {
    var parent_lamports: u64 = 1;
    var child_lamports: u64 = 1;
    var ro_lamports: u64 = 20;

    const owner = types.Pubkey{ .bytes = [_]u8{3} ** 32 };

    const child_program = blk: {
        var bytes: [24]u8 = undefined;
        @memset(&bytes, 0);
        @memcpy(bytes[0..4], SBF_MAGIC[0..4]);
        const p: usize = 4;
        bytes[p + 0] = 0x95;
        bytes[p + 1] = 0x00;
        std.mem.writeInt(i16, bytes[p + 2 .. p + 4], 0, .little);
        std.mem.writeInt(i32, bytes[p + 4 .. p + 8], 0, .little);
        break :blk bytes[0 .. p + 8];
    };

    var parent_prog_data = try std.testing.allocator.dupe(u8, &child_program);
    defer std.testing.allocator.free(parent_prog_data);
    var child_prog_data = try std.testing.allocator.dupe(u8, &child_program);
    defer std.testing.allocator.free(child_prog_data);
    var ro_data = try std.testing.allocator.dupe(u8, &[_]u8{ 1, 1, 1, 1 });
    defer std.testing.allocator.free(ro_data);

    const parent_ref = AccountRef{
        .key = .{ .bytes = [_]u8{10} ** 32 },
        .lamports = &parent_lamports,
        .data = &parent_prog_data,
        .owner = &owner,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    const child_ref = AccountRef{
        .key = .{ .bytes = [_]u8{11} ** 32 },
        .lamports = &child_lamports,
        .data = &child_prog_data,
        .owner = &ID,
        .executable = true,
        .is_signer = false,
        .is_writable = false,
    };
    const ro_ref = AccountRef{
        .key = .{ .bytes = [_]u8{12} ** 32 },
        .lamports = &ro_lamports,
        .data = &ro_data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    const invoke_payload = [_]u8{ 1, 2, 1, 0, 2, CPI_META_WRITABLE, 0, 0, 0, 0 };
    try std.testing.expectError(
        error.InvalidAccountLayout,
        executeProgramWithFeatures(
            parent_ref,
            &[_]AccountRef{ parent_ref, child_ref, ro_ref },
            &invoke_payload,
            0,
            std.testing.allocator,
            .{ .cpi = true },
        ),
    );
}

fn nextRandLcg(v: *u64) u64 {
    v.* = v.* *% 1103515245 +% 12345;
    return v.*;
}

test "property: parseCpiInvocation is total over bounded boundary inputs" {
    var rng = @as(u64, 0x1d2f_3f4f_5a6b_7c8d);
    var iterations: usize = 0;

    while (iterations < 256) : (iterations += 1) {
        const account_len = @as(usize, @intCast((nextRandLcg(&rng) & 0xff)));
        const raw_len = @as(usize, @intCast((nextRandLcg(&rng) & 0x7f)));
        var raw = try std.testing.allocator.alloc(u8, raw_len);
        defer std.testing.allocator.free(raw);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            raw[i] = @truncate(nextRandLcg(&rng) >> 24);
        }

        const parsed = parseCpiInvocation(raw, account_len) catch |err| {
            try std.testing.expect(err == error.InvalidInstructionData or err == error.InvalidAccountIndex);
            continue;
        };
        try std.testing.expect(parsed.account_count <= MAX_CPI_ACCOUNTS);
        try std.testing.expect(parsed.account_count <= 64);
        try std.testing.expect(account_len > 0);
        try std.testing.expect(parsed.callee_account_index < account_len);

        var j: usize = 0;
        while (j < parsed.account_count) : (j += 1) {
            try std.testing.expect(parsed.account_indices[j] < account_len);
        }
    }
}

test "helper get-key-bytes marshalling and feature gating" {
    const owner = types.Pubkey{ .bytes = [_]u8{9} ** 32 };
    const key = types.Pubkey{ .bytes = [_]u8{0xAA} ** 32 };
    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);

    const account = AccountRef{
        .key = key,
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    regs[1] = 0; // account index
    regs[2] = 32; // destination pointer
    regs[3] = 32; // destination length
    var accounts = [_]AccountRef{account};
    var stack = [_]u8{0} ** STACK_BYTES;

    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{}, 0, &exec_ctx, std.testing.allocator, .{ .key_serialization = true });
    try std.testing.expectEqual(@as(u64, 32), try helperGetKeyBytes(&ctx));
    try std.testing.expectEqualSlices(u8, &[_]u8{0xAA} ** 32, stack[32 .. 64]);
    var ctx_disabled = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{}, 0, &exec_ctx, std.testing.allocator, .{});
    try std.testing.expectError(error.FeatureDisabled, helperGetKeyBytes(&ctx_disabled));
    regs[2] = STACK_BYTES;
    regs[3] = 1;
    try std.testing.expectError(error.InvalidInstructionData, helperGetKeyBytes(&ctx));
}

test "helper feature gating is deterministic" {
    var regs = [_]u64{0} ** MAX_REGS;
    regs[1] = 0;
    regs[2] = 16;
    regs[3] = 32;

    var lamports: u64 = 0;
    var data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(data);
    const owner = types.Pubkey{ .bytes = [_]u8{3} ** 32 };
    const account = AccountRef{
        .key = .{ .bytes = [_]u8{7} ** 32 },
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var accounts = [_]AccountRef{account};
    var stack = [_]u8{0} ** STACK_BYTES;
    var exec_ctx_disabled = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var exec_ctx_log = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var exec_ctx_compute = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var exec_ctx_key = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var exec_ctx_cpi = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx_disabled = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{}, 0, &exec_ctx_disabled, std.testing.allocator, .{});
    var ctx_log = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{}, 0, &exec_ctx_log, std.testing.allocator, .{ .logs = true });
    var ctx_compute = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{ 1, 2, 3 }, 0, &exec_ctx_compute, std.testing.allocator, .{ .compute_budget = true });
    var ctx_key = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{}, 0, &exec_ctx_key, std.testing.allocator, .{ .key_serialization = true });
    var ctx_cpi = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{}, 0, &exec_ctx_cpi, std.testing.allocator, .{ .cpi = true });

    try std.testing.expectError(error.FeatureDisabled, helperLog(&ctx_disabled));
    try std.testing.expectEqual(@as(u64, 0), try helperLogU64(&ctx_log));
    try std.testing.expectError(error.FeatureDisabled, helperGetComputeBudget(&ctx_disabled));
    try std.testing.expectEqual(@as(u64, COMPUTE_BUDGET_UNITS), try helperGetComputeBudget(&ctx_compute));
    try std.testing.expectError(error.FeatureDisabled, helperGetKeyBytes(&ctx_disabled));
    try std.testing.expectError(error.InvalidInstructionData, helperInvoke(&ctx_cpi));
    try std.testing.expectError(error.FeatureDisabled, helperInvoke(&ctx_disabled));
    try std.testing.expectEqual(@as(u64, 32), try helperGetKeyBytes(&ctx_key));
}

test "helper accessors reject mixed writable/readonly duplicates in the same frame" {
    var lamports: [2]u64 = .{ 15, 7 };
    const shared_key = types.Pubkey{ .bytes = [_]u8{0xAB} ** 32 };
    const owner = types.Pubkey{ .bytes = [_]u8{3} ** 32 };

    var writable_data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(writable_data);
    var readonly_data = try std.testing.allocator.dupe(u8, &[_]u8{});
    defer std.testing.allocator.free(readonly_data);

    const writable_account = AccountRef{
        .key = shared_key,
        .lamports = &lamports[0],
        .data = &writable_data,
        .owner = &owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };
    const readonly_account = AccountRef{
        .key = shared_key,
        .lamports = &lamports[1],
        .data = &readonly_data,
        .owner = &owner,
        .executable = false,
        .is_signer = false,
        .is_writable = false,
    };

    var regs = [_]u64{0} ** MAX_REGS;
    regs[1] = 0;
    regs[2] = 1;
    regs[3] = 1;

    var accounts = [_]AccountRef{ writable_account, readonly_account };
    var stack = [_]u8{0} ** STACK_BYTES;
    var exec_ctx = ExecuteContext.init(COMPUTE_BUDGET_UNITS);
    var ctx = HelperContext.init(&regs, &accounts, stack[0..], &[_]u8{}, 0, &exec_ctx, std.testing.allocator, .{});

    try std.testing.expectError(error.InvalidAccountLayout, helperTransfer(&ctx));
}

test "vm stack memory ops enforce alignment and bounds checks" {
    var stack = [_]u8{0} ** STACK_BYTES;

    try std.testing.expectError(error.InvalidInstruction, loadFromStack(&stack, 0, 1, 2));
    try std.testing.expectError(error.InvalidInstruction, storeToStack(&stack, 0, 1, 4, 0x1234));
    try std.testing.expectError(error.InvalidAddress, loadFromStack(&stack, STACK_BYTES, 0, 1));
    try std.testing.expectError(error.InvalidAddress, storeToStack(&stack, STACK_BYTES, 0, 4, 0x1234));
}
