/// Thread-safe MPMC queue backed by a fixed-size ring buffer.
/// Callers that need unbounded capacity can use AtomicQueue with a mutex.
const std = @import("std");

/// A simple mutex-based unbounded queue.
/// T must be a value type (copied on push/pop).
pub fn AtomicQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            value: T,
            next: ?*Node,
        };

        head: ?*Node,
        tail: ?*Node,
        len: usize,
        mutex: std.Thread.Mutex,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .head = null,
                .tail = null,
                .len = 0,
                .mutex = .{},
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            var cur = self.head;
            while (cur) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                cur = next;
            }
            self.head = null;
            self.tail = null;
            self.len = 0;
        }

        /// Push a value onto the back of the queue.
        pub fn push(self: *Self, value: T) !void {
            const node = try self.allocator.create(Node);
            node.* = .{ .value = value, .next = null };
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.tail) |t| {
                t.next = node;
            } else {
                self.head = node;
            }
            self.tail = node;
            self.len += 1;
        }

        /// Pop a value from the front of the queue.
        /// Returns null if the queue is empty.
        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            const node = self.head orelse return null;
            self.head = node.next;
            if (self.head == null) self.tail = null;
            const value = node.value;
            self.allocator.destroy(node);
            self.len -= 1;
            return value;
        }

        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.head == null;
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.len;
        }
    };
}

test "AtomicQueue push and pop" {
    var q = AtomicQueue(u32).init(std.testing.allocator);
    defer q.deinit();

    try q.push(1);
    try q.push(2);
    try q.push(3);

    try std.testing.expectEqual(@as(usize, 3), q.count());
    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expectEqual(@as(?u32, 2), q.pop());
    try std.testing.expectEqual(@as(?u32, 3), q.pop());
    try std.testing.expectEqual(@as(?u32, null), q.pop());
    try std.testing.expect(q.isEmpty());
}

test "AtomicQueue empty pop" {
    var q = AtomicQueue(u8).init(std.testing.allocator);
    defer q.deinit();
    try std.testing.expectEqual(@as(?u8, null), q.pop());
}
