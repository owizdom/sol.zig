const std = @import("std");

pub const KvIterator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KvIterator {
        return .{ .allocator = allocator };
    }

    pub fn seekToFirst(self: *KvIterator) void {
        _ = self;
    }

    pub fn next(self: *KvIterator) void {
        _ = self;
    }

    pub fn valid(self: *const KvIterator) bool {
        _ = self;
        return false;
    }

    pub fn key(self: *const KvIterator) ?[]const u8 {
        _ = self;
        return null;
    }

    pub fn value(self: *const KvIterator) ?[]const u8 {
        _ = self;
        return null;
    }

    pub fn deinit(self: *KvIterator) void {
        _ = self;
    }
};

pub const Error = error{
    RocksDbError,
    DisabledBackend,
};

pub const RocksDb = struct {
    allocator: std.mem.Allocator,
    base_path: []const u8,

    pub fn open(path: []const u8) !RocksDb {
        _ = path;
        return Error.DisabledBackend;
    }

    pub fn close(self: *RocksDb) void {
        self.allocator.free(self.base_path);
    }

    pub fn put(self: *RocksDb, key: []const u8, value: []const u8) !void {
        _ = self;
        _ = key;
        _ = value;
        return Error.DisabledBackend;
    }

    pub fn putInCF(self: *RocksDb, cf: anytype, key: []const u8, value: []const u8) !void {
        _ = self;
        _ = cf;
        _ = key;
        _ = value;
        return Error.DisabledBackend;
    }

    pub fn get(self: *RocksDb, key: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        _ = self;
        _ = key;
        _ = allocator;
        return Error.DisabledBackend;
    }

    pub fn getInCF(self: *RocksDb, cf: anytype, key: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        _ = self;
        _ = cf;
        _ = key;
        _ = allocator;
        return Error.DisabledBackend;
    }

    pub fn delete(self: *RocksDb, key: []const u8) !void {
        _ = self;
        _ = key;
        return Error.DisabledBackend;
    }

    pub fn deleteInCF(self: *RocksDb, cf: anytype, key: []const u8) !void {
        _ = self;
        _ = cf;
        _ = key;
        return Error.DisabledBackend;
    }

    pub fn accountIterator(self: *RocksDb) KvIterator {
        _ = self;
        return .{ .allocator = std.heap.page_allocator };
    }
};
