// Benchmark: measures raw throughput of core subsystems.
// Run: zig build bench
//
// Reports:
//   - TPS (transactions/sec through bank)
//   - PoH ticks/sec (SHA-256 hash rate)
//   - RPC requests/sec (HTTP round-trips)
const std = @import("std");
const types     = @import("types");
const keypair   = @import("keypair");
const base58    = @import("base58");
const poh_mod   = @import("poh");
const transaction = @import("transaction");
const validator_mod = @import("validator");

// ── helpers ──────────────────────────────────────────────────────────────────

fn makeTransfer(
    from: types.Pubkey,
    to:   types.Pubkey,
    bh:   types.Hash,
    amt:  u64,
) transaction.Transaction {
    var ix_data: [12]u8 = undefined;
    std.mem.writeInt(u32, ix_data[0..4], 2, .little);  // transfer tag
    std.mem.writeInt(u64, ix_data[4..12], amt, .little);
    const sys = types.Pubkey{ .bytes = [_]u8{0} ** 32 };
    const ix = transaction.CompiledInstruction{
        .program_id_index = 2,
        .accounts = &[_]u8{ 0, 1 },
        .data = &ix_data,
    };
    return .{
        .signatures = &[_]types.Signature{.{ .bytes = [_]u8{0} ** 64 }},
        .message = .{
            .header = .{
                .num_required_signatures   = 1,
                .num_readonly_signed_accounts   = 0,
                .num_readonly_unsigned_accounts = 1,
            },
            .account_keys   = &[_]types.Pubkey{ from, to, sys },
            .recent_blockhash = bh,
            .instructions   = &[_]transaction.CompiledInstruction{ix},
        },
    };
}

fn sendRpc(allocator: std.mem.Allocator, port: u16, body: []const u8) !usize {
    const req = try std.fmt.allocPrint(
        allocator,
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ port, body.len, body },
    );
    defer allocator.free(req);

    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    try std.posix.connect(sock, &addr.any, addr.getOsSockLen());
    _ = try std.posix.send(sock, req, 0);

    var total: usize = 0;
    var buf: [2048]u8 = undefined;
    while (true) {
        const n = try std.posix.recv(sock, &buf, 0);
        if (n == 0) break;
        total += n;
    }
    return total;
}

// ── benchmark runners ─────────────────────────────────────────────────────────

fn benchTps(v: *validator_mod.Validator, out: anytype, n: usize) !void {
    const identity = v.identity.publicKey();
    const recipient = types.Pubkey{ .bytes = [_]u8{0xBB} ** 32 };

    const t0 = std.time.nanoTimestamp();
    var ok: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const bh = v.latestBlockhash();
        const tx = makeTransfer(identity, recipient, bh, 1);
        const r = v.submit(&[_]transaction.Transaction{tx}) catch continue;
        if (r.transactions_ok > 0) ok += 1;
    }
    const elapsed_ns = std.time.nanoTimestamp() - t0;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const tps = @as(f64, @floatFromInt(ok)) / elapsed_s;

    try out.print("  TPS benchmark ({d} txs)\n", .{n});
    try out.print("    ok={d}  time={d:.3}s  tps={d:.0}\n", .{ ok, elapsed_s, tps });
}

fn benchPoh(out: anytype, ticks: usize) !void {
    var p = poh_mod.PoH.init(types.Hash.ZERO);
    const t0 = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < ticks) : (i += 1) _ = p.tick();
    const elapsed_ns = std.time.nanoTimestamp() - t0;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const rate = @as(f64, @floatFromInt(ticks)) / elapsed_s;

    try out.print("  PoH benchmark ({d} ticks)\n", .{ticks});
    try out.print("    time={d:.3}s  ticks/s={d:.0}\n", .{ elapsed_s, rate });
}

fn benchRpc(allocator: std.mem.Allocator, port: u16, out: anytype, n: usize) !void {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getHealth\"}";

    // warm-up
    _ = sendRpc(allocator, port, body) catch {};

    const t0 = std.time.nanoTimestamp();
    var ok: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = sendRpc(allocator, port, body) catch continue;
        ok += 1;
    }
    const elapsed_ns = std.time.nanoTimestamp() - t0;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const rps = @as(f64, @floatFromInt(ok)) / elapsed_s;
    const avg_ms = elapsed_s * 1000.0 / @as(f64, @floatFromInt(ok));

    try out.print("  RPC benchmark ({d} requests)\n", .{n});
    try out.print("    ok={d}  time={d:.3}s  req/s={d:.0}  avg_latency={d:.2}ms\n", .{
        ok, elapsed_s, rps, avg_ms,
    });
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const out   = std.fs.File.stdout().deprecatedWriter();

    const rpc_port: u16 = 19000;

    const identity = keypair.KeyPair.generate();
    var v = try validator_mod.Validator.init(alloc, identity);
    defer v.deinit();

    try v.startServices(null, rpc_port, null);
    defer v.stopServices();
    std.Thread.sleep(50 * std.time.ns_per_ms); // let RPC thread bind

    var pk_buf: [64]u8 = undefined;
    const pk_txt = try base58.encode(&identity.publicKey().bytes, &pk_buf);
    try out.print("solana-in-zig benchmark\n", .{});
    try out.print("  identity : {s}\n", .{pk_txt});
    try out.print("  rpc_port : {d}\n\n", .{rpc_port});

    try out.print("[1] Proof of History (SHA-256 chain)\n", .{});
    try benchPoh(out, 1_000_000);

    try out.print("\n[2] Bank transaction throughput\n", .{});
    try benchTps(v, out, 10_000);

    try out.print("\n[3] JSON-RPC request throughput\n", .{});
    try benchRpc(alloc, rpc_port, out, 500);

    try out.print("\ndone.\n", .{});
}
