const std = @import("std");
const types = @import("types");

/// The Config Program ID in this project uses a deterministic placeholder pubkey.
pub const ID: types.Pubkey = .{
    .bytes = [_]u8{
        0x03, 0x06, 0x4a, 0xa3, 0x00, 0x2f, 0x74, 0xdc,
        0xc8, 0x6e, 0x43, 0x31, 0x0f, 0x0c, 0x05, 0x2a,
        0xf8, 0xc5, 0xda, 0x27, 0xf6, 0x10, 0x40, 0x19,
        0xa3, 0x23, 0xef, 0xa0, 0x00, 0x00, 0x00, 0x00,
    },
};

pub const AccountRef = types.AccountRef;

pub const Error = error{
    InvalidInstruction,
    InvalidAccountLayout,
    InvalidSigner,
    NotWritable,
    NotEnoughData,
};

pub const InstructionTag = enum(u32) {
    store_config = 0,
};

fn readTag(ix_data: []const u8) !InstructionTag {
    if (ix_data.len < 4) return error.InvalidInstruction;
    const raw = std.mem.readInt(u32, ix_data[0..4], .little);
    return switch (raw) {
        0 => .store_config,
        else => error.InvalidInstruction,
    };
}

pub fn execute(
    accounts: []AccountRef,
    ix_data: []const u8,
    _: types.Slot,
    _: std.mem.Allocator,
) Error!void {
    if (accounts.len < 1) return error.InvalidAccountLayout;
    const tag = try readTag(ix_data);

    const cfg = &accounts[0];
    if (!cfg.is_signer) return error.InvalidSigner;
    if (!cfg.is_writable) return error.NotWritable;

    switch (tag) {
        .store_config => {
            if (ix_data.len < 4) return error.InvalidInstruction;
            const payload = ix_data[4..];
            if (cfg.data.len < payload.len) return error.NotEnoughData;
            @memcpy(cfg.data.*[0..payload.len], payload);
        },
    }
}

test "config store instruction truncates into provided buffer" {
    const owner = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    const cfg = types.Pubkey{ .bytes = [_]u8{9} ** 32 };
    var data = [_]u8{0} ** 16;
    var lamports: u64 = 0;
    var payload = [_]u8{1, 2, 3, 4};
    const cfg_ref = AccountRef{
        .key = cfg,
        .lamports = &lamports,
        .data = &data,
        .owner = &owner,
        .executable = false,
        .is_signer = true,
        .is_writable = true,
    };
    const ix = &[_]u8{
        0x00, 0x00, 0x00, 0x00, // store_config tag
        1, 2, 3, 4,
    };
    try execute(&[_]AccountRef{cfg_ref}, ix, 0, std.testing.allocator);
    try std.testing.expectEqualSlices(u8, payload[0..], data[0..4]);
}
