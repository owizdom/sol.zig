const std = @import("std");
const types = @import("types");
const base58 = @import("base58");
const net = std.net;

const BootstrapError = error{
    NetworkFailure,
    ParseFailure,
};

fn readAll(conn: anytype, allocator: std.mem.Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = conn.read(&buf) catch return BootstrapError.NetworkFailure;
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }

    return out.toOwnedSlice();
}

fn httpBody(response: []const u8) []const u8 {
    if (std.mem.indexOf(u8, response, "\r\n\r\n")) |idx| {
        return response[idx + 4 ..];
    }
    return response;
}

pub fn httpPost(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    body: []const u8,
) ![]u8 {
    var conn = try std.net.tcpConnectToHost(allocator, host, port);
    defer conn.close();

    const req = try std.fmt.allocPrint(
        allocator,
        "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ path, host, body.len, body },
    );
    defer allocator.free(req);
    try conn.writeAll(req);

    return readAll(conn, allocator);
}

fn parseJsonNumber(json: []const u8, key: []const u8) ?[]const u8 {
    const needle = std.mem.indexOf(u8, json, key) orelse return null;
    var pos = needle + key.len;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) pos += 1;
    if (pos >= json.len) return null;
    const start = pos;
    while (pos < json.len) {
        const c = json[pos];
        if ((c >= '0' and c <= '9') or c == '-') {
            pos += 1;
            continue;
        }
        break;
    }
    if (start == pos) return null;
    return json[start..pos];
}

fn parseJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const needle = std.mem.indexOf(u8, json, key) orelse return null;
    var pos = needle + key.len;
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ')) pos += 1;
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;
    const start = pos;
    while (pos < json.len and json[pos] != '"') pos += 1;
    if (pos >= json.len) return null;
    return json[start..pos];
}

fn parseUint16(json: []const u8) ?u16 {
    if (json.len == 0) return null;
    return std.fmt.parseInt(u16, json, 10) catch null;
}

/// Parse a dotted IPv4 string (no port) + a separate port into an Address.
pub fn parseIpv4(ip_str: []const u8, port: u16) ?std.net.Address {
    var ip: [4]u8 = undefined;
    var parts_seen: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    // trim trailing whitespace
    var end = ip_str.len;
    while (end > 0 and (ip_str[end - 1] == ' ' or ip_str[end - 1] == '\r' or ip_str[end - 1] == '\n')) end -= 1;
    const s = ip_str[0..end];
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == '.') {
            if (parts_seen >= 4) return null;
            const part = s[start..i];
            if (part.len == 0 or part.len > 3) return null;
            ip[parts_seen] = std.fmt.parseInt(u8, part, 10) catch return null;
            parts_seen += 1;
            start = i + 1;
        }
    }
    if (parts_seen != 4) return null;
    return net.Address.initIp4(ip, port);
}

/// Fetch this machine's public IPv4 address via api4.ipify.org.
/// Caller frees the returned slice.
pub fn fetchPublicIp(allocator: std.mem.Allocator) ![]u8 {
    var conn = std.net.tcpConnectToHost(allocator, "api4.ipify.org", 80) catch return BootstrapError.NetworkFailure;
    defer conn.close();
    const req = "GET / HTTP/1.1\r\nHost: api4.ipify.org\r\nConnection: close\r\n\r\n";
    conn.writeAll(req) catch return BootstrapError.NetworkFailure;
    const raw = try readAll(conn, allocator);
    defer allocator.free(raw);
    const body = httpBody(raw);
    var s: []const u8 = body;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\r' or s[0] == '\n')) s = s[1..];
    var e = s.len;
    while (e > 0 and (s[e - 1] == ' ' or s[e - 1] == '\r' or s[e - 1] == '\n')) e -= 1;
    if (e == 0) return BootstrapError.ParseFailure;
    return allocator.dupe(u8, s[0..e]);
}

/// Query devnet getClusterNodes and return true if our identity pubkey appears.
pub fn isVisibleOnDevnet(allocator: std.mem.Allocator, identity: [32]u8) !bool {
    var b58_buf: [44]u8 = undefined;
    const our_b58 = base58.encode(&identity, &b58_buf) catch return BootstrapError.ParseFailure;
    const req_body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getClusterNodes\"}";
    const resp = try httpPost(allocator, "api.devnet.solana.com", 80, "/", req_body);
    defer allocator.free(resp);
    const payload = httpBody(resp);
    return std.mem.indexOf(u8, payload, our_b58) != null;
}

fn parseIpv4Address(allocator: std.mem.Allocator, raw: []const u8) ?std.net.Address {
    _ = allocator;
    const port_sep = std.mem.lastIndexOf(u8, raw, ":") orelse return null;
    const host = raw[0..port_sep];
    const port_txt = raw[port_sep + 1 ..];
    const port = parseUint16(port_txt) orelse return null;

    var ip: [4]u8 = undefined;
    var parts_seen: u8 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= host.len) : (i += 1) {
        if (i == host.len or host[i] == '.') {
            if (parts_seen >= 4) return null;
            const part = host[start..i];
            if (part.len == 0 or part.len > 3) return null;
            const value = std.fmt.parseInt(u8, part, 10) catch return null;
            ip[parts_seen] = value;
            parts_seen += 1;
            start = i + 1;
        }
    }
    if (parts_seen != 4) return null;
    return net.Address.initIp4(ip, port);
}

pub fn fetchCurrentSlot(allocator: std.mem.Allocator) !types.Slot {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getSlot\"}";
    const resp = try httpPost(allocator, "api.devnet.solana.com", 80, "/", body);
    defer allocator.free(resp);
    const payload = httpBody(resp);
    const slot_str = parseJsonNumber(payload, "\"result\":") orelse return BootstrapError.ParseFailure;
    return std.fmt.parseInt(types.Slot, slot_str, 10) catch return BootstrapError.ParseFailure;
}

pub fn fetchGenesisHash(allocator: std.mem.Allocator) ![]u8 {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getGenesisHash\"}";
    const resp = try httpPost(allocator, "api.devnet.solana.com", 80, "/", body);
    defer allocator.free(resp);
    const payload = httpBody(resp);
    const result = parseJsonString(payload, "\"result\":") orelse return BootstrapError.ParseFailure;
    return allocator.dupe(u8, result);
}

pub fn fetchGossipPeers(allocator: std.mem.Allocator, max: usize) !std.array_list.Managed(std.net.Address) {
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getClusterNodes\"}";
    const resp = try httpPost(allocator, "api.devnet.solana.com", 80, "/", body);
    defer allocator.free(resp);
    const payload = httpBody(resp);

    const marker = "\"gossip\":\"";
    var out = std.array_list.Managed(std.net.Address).init(allocator);
    var offset: usize = 0;
    var count: usize = 0;

    while (count < max) {
        const loc = std.mem.indexOfPos(u8, payload, offset, marker) orelse break;
        const start = loc + marker.len;
        const end = std.mem.indexOfPos(u8, payload, start, "\"") orelse break;
        const endpoint = payload[start..end];
        if (parseIpv4Address(allocator, endpoint)) |addr| {
            out.append(addr) catch break;
            count += 1;
        }
        offset = end + 1;
    }

    return out;
}

pub fn downloadSnapshot(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    dest_path: []const u8,
) !void {
    const body = try httpGet(allocator, host, port, path);
    defer allocator.free(body);
    const data = httpBody(body);
    var file = try std.fs.cwd().createFile(dest_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn httpGet(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
) ![]u8 {
    var conn = try std.net.tcpConnectToHost(allocator, host, port);
    defer conn.close();

    const req = try std.fmt.allocPrint(
        allocator,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n",
        .{ path, host },
    );
    defer allocator.free(req);
    try conn.writeAll(req);

    return readAll(conn, allocator);
}
