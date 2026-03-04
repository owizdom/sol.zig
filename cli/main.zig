const std = @import("std");
const base58 = @import("base58");
const keypair = @import("keypair");
const validator_mod = @import("validator");

pub fn main() !void {
    const out = std.fs.File.stdout().deprecatedWriter();

    const identity = keypair.KeyPair.generate();
    var node = try validator_mod.Validator.init(std.heap.page_allocator, identity);
    defer node.deinit();

    const identity_pk = identity.publicKey();

    var pk_buf: [64]u8 = undefined;
    const pk_text = try base58.encode(&identity_pk.bytes, &pk_buf);

    var bh_buf: [64]u8 = undefined;
    const initial_hash = try base58.encode(&node.latestBlockhash().bytes, &bh_buf);

    try out.print("Solana-in-Zig validator boot\n", .{});
    try out.print("  node: {s}\n", .{pk_text});
    try out.print("  slot: {d}\n", .{node.currentSlot()});
    try out.print("  latest hash: {s}\n", .{initial_hash});

    const final_hash = try node.runSlots(3);
    const final_text = try base58.encode(&final_hash.bytes, &bh_buf);
    try out.print("  after replay: slot={d}, hash={s}\n", .{ node.currentSlot(), final_text });
    try out.print("  balance (self): {d}\n", .{node.balance(identity_pk)});
}

test {
    _ = @import("types");
    _ = @import("base58");
    _ = @import("encoding");
    _ = @import("keypair");
    _ = @import("account");
    _ = @import("transaction");
    _ = @import("poh");
    _ = @import("system_program");
    _ = @import("accounts_db");
    _ = @import("sysvar");
    _ = @import("programs/system");
    _ = @import("programs/vote_program");
    _ = @import("runtime");
    _ = @import("net/shred");
    _ = @import("net/gossip");
    _ = @import("net/turbine");
    _ = @import("consensus/vote");
    _ = @import("consensus/tower");
    _ = @import("consensus/fork_choice");
    _ = @import("consensus/schedule");
    _ = @import("bank");
    _ = @import("blockstore");
    _ = @import("replay");
    _ = @import("rpc");
    _ = @import("validator");
}
