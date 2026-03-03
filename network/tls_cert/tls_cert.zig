const std = @import("std");

fn toHex(dst: []u8, src: []const u8) []const u8 {
    const hex = "0123456789abcdef";
    var off: usize = 0;
    for (src) |b| {
        dst[off] = hex[b >> 4];
        dst[off + 1] = hex[b & 0x0f];
        off += 2;
    }
    return dst[0..off];
}

fn buildPemBlob(
    writer: anytype,
    title: []const u8,
    payload: []const u8,
) !void {
    try writer.writeAll("-----BEGIN ");
    try writer.writeAll(title);
    try writer.writeAll("-----\n");

    var i: usize = 0;
    while (i < payload.len) {
        const line_end = @min(i + 48, payload.len);
        try writer.writeAll(payload[i..line_end]);
        try writer.writeAll("\n");
        i = line_end;
    }

    try writer.writeAll("-----END ");
    try writer.writeAll(title);
    try writer.writeAll("-----\n");
}

pub const CertBundle = struct {
    allocator: std.mem.Allocator,
    cert_path: []u8,
    key_path: []u8,

    pub fn deinit(self: *CertBundle) void {
        std.fs.cwd().deleteFile(self.cert_path) catch {};
        std.fs.cwd().deleteFile(self.key_path) catch {};
        self.allocator.free(self.cert_path);
        self.allocator.free(self.key_path);
    }
};

pub fn generateSelfSigned(allocator: std.mem.Allocator, tmp_dir: []const u8) !CertBundle {
    try ensureDir(tmp_dir);

    var now = std.time.timestamp();
    if (now < 0) now = 0;
    var cert_secret: [32]u8 = undefined;
    var key_secret: [32]u8 = undefined;
    std.crypto.random.bytes(&cert_secret);
    std.crypto.random.bytes(&key_secret);

    var cert_hex: [64]u8 = undefined;
    var key_hex: [64]u8 = undefined;
    const cert_seed = toHex(&cert_hex, &cert_secret);
    const key_seed = toHex(&key_hex, &key_secret);

    var cert_header: [512]u8 = undefined;
    var cert_buf: [1024]u8 = undefined;
    var cert_fbs = std.io.fixedBufferStream(&cert_buf);
    try buildPemBlob(
        cert_fbs.writer(),
        "CERTIFICATE",
        try std.fmt.bufPrint(&cert_header, "created={d}\nseed={s}", .{ now, cert_seed }),
    );
    const cert_body = cert_fbs.getWritten();

    var key_header: [512]u8 = undefined;
    var key_buf: [1024]u8 = undefined;
    var key_fbs = std.io.fixedBufferStream(&key_buf);
    try buildPemBlob(
        key_fbs.writer(),
        "PRIVATE KEY",
        try std.fmt.bufPrint(&key_header, "created={d}\nseed={s}", .{ now, key_seed }),
    );
    const key_body = key_fbs.getWritten();

    var cert_name: [256]u8 = undefined;
    var key_name: [256]u8 = undefined;
    const cert_file = try std.fmt.bufPrint(&cert_name, "{s}/validator-{d}-cert.pem", .{ tmp_dir, now });
    const key_file = try std.fmt.bufPrint(&key_name, "{s}/validator-{d}-key.pem", .{ tmp_dir, now });

    var cert = try std.fs.cwd().createFile(cert_file, .{ .truncate = true });
    defer cert.close();
    try cert.writeAll(cert_body);

    var key = try std.fs.cwd().createFile(key_file, .{ .truncate = true });
    defer key.close();
    try key.writeAll(key_body);

    return CertBundle{
        .allocator = allocator,
        .cert_path = try allocator.dupe(u8, cert_file),
        .key_path = try allocator.dupe(u8, key_file),
    };
}

fn ensureDir(path: []const u8) !void {
    if (path.len == 0) return;
    std.fs.cwd().makeDir(path) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

test "tls cert path creation" {
    const bundle = try generateSelfSigned(std.testing.allocator, "./tmp_snapshot_test");
    try std.testing.expect(bundle.cert_path.len > 0);
    try std.testing.expect(bundle.key_path.len > 0);
    defer bundle.deinit();
}
