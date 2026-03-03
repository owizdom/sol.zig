const std = @import("std");
const keypair = @import("keypair");
const validator_mod = @import("validator");
const gossip = @import("net/gossip");

const GOSSIP_PING_BYTES: usize = 68;
const GOSSIP_PRUNE_ENTRY_BYTES: usize = 32;

const RpcFixture = struct {
    name: []const u8,
    body: []const u8,
    override_len: ?usize,
};

fn sendRpcFrame(
    allocator: std.mem.Allocator,
    port: u16,
    body: []const u8,
    override_len: ?usize,
) ![]u8 {
    const content_length = override_len orelse body.len;
    const req = try std.fmt.allocPrint(
        allocator,
        "POST / HTTP/1.1\r\n" ++
            "Host: 127.0.0.1:{d}\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n\r\n" ++
            "{s}",
        .{ port, content_length, body },
    );
    defer allocator.free(req);

    const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(sock);

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const os_addr = addr.any;
    try std.posix.connect(sock, &os_addr, addr.getOsSockLen());
    _ = try std.posix.send(sock, req, 0);

    var resp = std.array_list.Managed(u8).init(allocator);
    defer resp.deinit();
    const deadline_ns = std.time.nanoTimestamp() + 2 * std.time.ns_per_s;
    while (true) {
        var buf: [1024]u8 = undefined;
        if (std.time.nanoTimestamp() >= deadline_ns) return error.Timeout;
        const n = std.posix.recv(sock, &buf, std.posix.MSG.DONTWAIT) catch |err| {
            if (err != error.WouldBlock) return err;
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        if (n == 0) break;
        try resp.appendSlice(buf[0..n]);
    }

    return try resp.toOwnedSlice();
}

fn sendDatagram(
    sock: std.posix.socket_t,
    dest: *const std.posix.sockaddr,
    dest_len: std.posix.socklen_t,
    payload: []const u8,
) !void {
    _ = try std.posix.sendto(sock, payload, 0, dest, dest_len);
}

fn makePingLike(payload: []u8, src: keypair.KeyPair, tick: u64) void {
    std.debug.assert(payload.len >= GOSSIP_PING_BYTES);
    std.mem.writeInt(u32, payload[0..4], @intFromEnum(gossip.GossipMsgKind.ping), .little);
    payload[4..36].* = src.publicKey().bytes;
    var i: usize = 0;
    while (i < 32) : (i += 1) payload[36 + i] = @truncate(tick + i);
}

fn makePongLike(payload: []u8, src: keypair.KeyPair, tick: u64) void {
    std.debug.assert(payload.len >= GOSSIP_PING_BYTES);
    std.mem.writeInt(u32, payload[0..4], @intFromEnum(gossip.GossipMsgKind.pong), .little);
    payload[4..36].* = src.publicKey().bytes;
    var i: usize = 0;
    while (i < 32) : (i += 1) payload[36 + i] = @truncate(tick + i + 128);
}

fn makePrune(payload: []u8, a: keypair.KeyPair, b: keypair.KeyPair) usize {
    const count: usize = 2;
    std.debug.assert(payload.len >= 8 + count * GOSSIP_PRUNE_ENTRY_BYTES);
    std.mem.writeInt(u32, payload[0..4], @intFromEnum(gossip.GossipMsgKind.prune_message), .little);
    std.mem.writeInt(u32, payload[4..8], @intCast(count), .little);
    const pk_a = a.publicKey();
    const pk_b = b.publicKey();
    std.mem.copyForwards(u8, payload[8..40], &pk_a.bytes);
    std.mem.copyForwards(u8, payload[40..72], &pk_b.bytes);
    return 8 + count * GOSSIP_PRUNE_ENTRY_BYTES;
}

fn parseIntArg(args: [][:0]u8, idx: *usize, default: usize) usize {
    if (idx.* >= args.len) return default;
    const a = args[idx.*];
    idx.* += 1;
    return std.fmt.parseInt(usize, a[0..a.len], 10) catch default;
}

pub fn main() !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var it: usize = 1;
    const iterations = if (args.len > 1) parseIntArg(args, &it, 500) else 500;
    const delay_ms = if (args.len > 2) parseIntArg(args, &it, 25) else 25;
    const rpc_port: u16 = if (args.len > 3)
        @intCast(std.fmt.parseInt(u16, args[it][0..args[it].len], 10) catch 18901)
    else
        18901;
    const rpc_port_for_services: ?u16 = if (rpc_port == 0) null else rpc_port;

    const identity = keypair.KeyPair.generate();
    var v = try validator_mod.Validator.init(allocator, identity);
    defer v.deinit();

    try v.startServices(null, rpc_port_for_services, null);
    defer v.stopServices();

    const gossip_recv_port: u16 = rpc_port + 1;
    const gossip_send_port: u16 = rpc_port + 2;

    var node_recv = try gossip.GossipNode.init(
        allocator,
        keypair.KeyPair.generate(),
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, gossip_recv_port),
        0,
    );
    defer node_recv.deinit();

    var node_send = try gossip.GossipNode.init(
        allocator,
        keypair.KeyPair.generate(),
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, gossip_send_port),
        0,
    );
    defer node_send.deinit();

    const receiver_addr = node_recv.my_info.gossip;
    const receiver_sockaddr = receiver_addr.any;
    const receiver_len = receiver_addr.getOsSockLen();

    const rpc_fixtures = [_]RpcFixture{
        .{ .name = "health", .body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getHealth\"}", .override_len = null },
        .{ .name = "slot", .body = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"getSlot\"}", .override_len = null },
        .{ .name = "latest-blockhash", .body = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"getLatestBlockhash\",\"params\":{\"commitment\":\"confirmed\"}}", .override_len = null },
        .{ .name = "balance", .body = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"getBalance\",\"params\":[\"11111111111111111111111111111111\"]}", .override_len = null },
        .{ .name = "bad-jsonrpc", .body = "{\"jsonrpc\":\"1.0\",\"id\":5,\"method\":\"getHealth\"}", .override_len = null },
        .{ .name = "bad-content-length", .body = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"getHealth\"}", .override_len = 64 },
    };

    var ok_count: usize = 0;
    var err_count: usize = 0;
    var replayed_push: usize = 0;
    var replayed_ping: usize = 0;
    var replayed_pong: usize = 0;
    var replayed_prune: usize = 0;
    var i: usize = 0;

    while (i < iterations) : (i += 1) {
        const r = rpc_fixtures[i % rpc_fixtures.len];
        const response = sendRpcFrame(
            allocator,
            rpc_port,
            r.body,
            r.override_len,
        ) catch |err| {
            if (err == error.Timeout) {
                err_count += 1;
                continue;
            }
            return err;
        };
        defer allocator.free(response);

        if (std.mem.indexOf(u8, response, "\"error\"")) |idx| {
            _ = idx;
            err_count += 1;
        } else {
            ok_count += 1;
        }

        const method_selector = i % 4;
        switch (method_selector) {
            0 => {
                var buf: [gossip.MAX_GOSSIP_PACKET]u8 = undefined;
                const serialized_len = gossip.serializePush(node_send.my_info, &buf);
                try sendDatagram(node_send.sock, &receiver_sockaddr, receiver_len, buf[0..serialized_len]);
                node_recv.recvOnce() catch |err| {
                    if (err != error.NoData) return err;
                };
                replayed_push += 1;
            },
            1 => {
                var ping: [GOSSIP_PING_BYTES]u8 = undefined;
                makePingLike(&ping, node_send.kp, i);
                try sendDatagram(node_send.sock, &receiver_sockaddr, receiver_len, &ping);
                node_recv.recvOnce() catch |err| {
                    if (err != error.NoData) return err;
                };
                replayed_ping += 1;
            },
            2 => {
                var pong: [GOSSIP_PING_BYTES]u8 = undefined;
                makePongLike(&pong, node_send.kp, i);
                try sendDatagram(node_send.sock, &receiver_sockaddr, receiver_len, &pong);
                node_recv.recvOnce() catch |err| {
                    if (err != error.NoData) return err;
                };
                replayed_pong += 1;
            },
            3 => {
                var prune: [72]u8 = undefined;
                const prune_len = makePrune(&prune, node_send.kp, node_recv.kp);
                try sendDatagram(node_send.sock, &receiver_sockaddr, receiver_len, prune[0..prune_len]);
                node_recv.recvOnce() catch |err| {
                    if (err != error.NoData) return err;
                };
                replayed_prune += 1;
            },
            else => unreachable,
        }

        try stdout.print("iter={d}/{d} fixture={s} ok={d} err={d} peers={d}\n", .{ i + 1, iterations, r.name, ok_count, err_count, node_recv.crds.count() });
        std.Thread.sleep(@as(u64, delay_ms) * std.time.ns_per_ms);
    }

    try stdout.print("done: total={d} ok={d} err={d} push={d} ping={d} pong={d} prune={d} peers={d}\n", .{
        iterations,
        ok_count,
        err_count,
        replayed_push,
        replayed_ping,
        replayed_pong,
        replayed_prune,
        node_recv.crds.count(),
    });
}
