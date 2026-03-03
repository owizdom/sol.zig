const std = @import("std");
const metrics = @import("metrics");

pub const MetricsServer = struct {
    sock: std.posix.socket_t,
    metrics: *metrics.Metrics,
    running: std.atomic.Value(bool),

    pub fn init(bind_addr: std.net.Address, m: *metrics.Metrics) !MetricsServer {
        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        errdefer std.posix.close(sock);

        try std.posix.setsockopt(sock, std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        const os_addr = bind_addr.any;
        try std.posix.bind(sock, &os_addr, bind_addr.getOsSockLen());
        try std.posix.listen(sock, 32);

        return .{
            .sock = sock,
            .metrics = m,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn start(self: *MetricsServer) !std.Thread {
        return std.Thread.spawn(.{}, run, .{self});
    }

    pub fn stop(self: *MetricsServer) void {
        if (self.running.load(.acquire)) {
            self.running.store(false, .release);
        }

        if (self.sock != -1) {
            const fd = self.sock;
            self.sock = -1;
            std.posix.close(fd);
        }
    }

    pub fn deinit(self: *MetricsServer) void {
        self.stop();
    }

    fn run(self: *MetricsServer) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            var peer: std.posix.sockaddr = undefined;
            var peer_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            const conn = std.posix.accept(self.sock, &peer, &peer_len, 0) catch {
                if (!self.running.load(.acquire)) return;
                continue;
            };
            defer std.posix.close(conn);

            var req: [2048]u8 = undefined;
            const n = std.posix.recv(conn, &req, 0) catch continue;
            if (n < 11) {
                sendNotFound(conn) catch {};
                continue;
            }

            const is_metrics = std.mem.eql(u8, req[0..11], "GET /metrics") and req[5] == ' ';
            if (!is_metrics) {
                sendNotFound(conn) catch {};
                continue;
            }

            var body = std.array_list.Managed(u8).init(std.heap.page_allocator);
            defer body.deinit();
            try self.metrics.renderPrometheus(body.writer());
            try sendResponse(conn, body.items);
        }
    }
};

fn sendResponse(conn: std.posix.socket_t, body: []const u8) !void {
    var header: [256]u8 = undefined;
    const header_len = try std.fmt.bufPrint(
        &header,
        "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    );
    try writeAll(conn, header_len);
    try writeAll(conn, body);
}

fn sendNotFound(conn: std.posix.socket_t) !void {
    const body = "not found";
    var header: [128]u8 = undefined;
    const header_len = try std.fmt.bufPrint(
        &header,
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    );
    try writeAll(conn, header_len);
    try writeAll(conn, body);
}

fn writeAll(conn: std.posix.socket_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const sent = try std.posix.send(conn, data[off..], 0);
        off += sent;
    }
}
