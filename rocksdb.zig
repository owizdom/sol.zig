const std = @import("std");

const c = @cImport({
    @cInclude("rocksdb/c.h");
});

const CFTag = enum {
    default,
    accounts,
    slot_meta,
    blockhashes,
};

const KvEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const KvIterator = struct {
    allocator: std.mem.Allocator,
    entries: std.array_list.Managed(KvEntry),
    index: usize,

    pub fn seekToFirst(self: *KvIterator) void {
        self.index = 0;
    }

    pub fn next(self: *KvIterator) void {
        if (self.index < self.entries.items.len) self.index += 1;
    }

    pub fn valid(self: *const KvIterator) bool {
        return self.index < self.entries.items.len;
    }

    pub fn key(self: *const KvIterator) ?[]const u8 {
        if (!self.valid()) return null;
        return self.entries.items[self.index].key;
    }

    pub fn value(self: *const KvIterator) ?[]const u8 {
        if (!self.valid()) return null;
        return self.entries.items[self.index].value;
    }

    pub fn deinit(self: *KvIterator) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.entries.deinit();
    }
};

pub const Error = error{
    RocksDbError,
};

pub const RocksDb = struct {
    allocator: std.mem.Allocator,
    db: *c.rocksdb_t,
    base_path: []const u8,
    read_opts: *c.rocksdb_readoptions_t,
    write_opts: *c.rocksdb_writeoptions_t,
    read_prefixed: u8 = 0,
    default_cf: CFTag = .default,
    accounts_cf: CFTag = .accounts,
    slot_meta_cf: CFTag = .slot_meta,
    blockhashes_cf: CFTag = .blockhashes,

    fn cfPrefix(cf: CFTag) u8 {
        return switch (cf) {
            .default => 0,
            .accounts => 1,
            .slot_meta => 2,
            .blockhashes => 3,
        };
    }

    fn withPrefixedKey(self: *RocksDb, cf: CFTag, key: []const u8) ![]u8 {
        const out = try self.allocator.alloc(u8, key.len + 1);
        out[0] = cfPrefix(cf);
        @memcpy(out[1..], key);
        return out;
    }

    fn maybeErr(err: ?[*:0]u8) !void {
        if (err == null) return;
        c.rocksdb_free(@constCast(err.?));
        return Error.RocksDbError;
    }

    pub fn open(path: []const u8) !RocksDb {
        const allocator = std.heap.page_allocator;
        const db_path = if (path.len == 0) "accounts_db" else path;

        try std.fs.cwd().makePath(db_path);

        const base_path = try allocator.dupe(u8, db_path);
        errdefer allocator.free(base_path);

        const path_z = try allocator.dupeZ(u8, db_path);
        defer allocator.free(path_z);

        const opts = c.rocksdb_options_create();
        c.rocksdb_options_set_create_if_missing(opts, 1);
        var errptr: ?[*:0]u8 = null;
        const db = c.rocksdb_open(opts, path_z.ptr, &errptr);
        if (db == null) {
            c.rocksdb_options_destroy(opts);
            return maybeErr(errptr);
        }

        const read_opts = c.rocksdb_readoptions_create();
        const write_opts = c.rocksdb_writeoptions_create();

        c.rocksdb_options_destroy(opts);

        return RocksDb{
            .allocator = allocator,
            .db = db.?,
            .base_path = base_path,
            .read_opts = read_opts,
            .write_opts = write_opts,
        };
    }

    pub fn close(self: *RocksDb) void {
        c.rocksdb_close(self.db);
        c.rocksdb_readoptions_destroy(self.read_opts);
        c.rocksdb_writeoptions_destroy(self.write_opts);
        self.allocator.free(self.base_path);
    }

    pub fn put(self: *RocksDb, key: []const u8, value: []const u8) !void {
        return self.putInCF(.accounts, key, value);
    }

    pub fn putInCF(self: *RocksDb, cf: CFTag, key: []const u8, value: []const u8) !void {
        if (key.len > std.math.maxInt(u32)) return Error.RocksDbError;

        const real_key = try self.withPrefixedKey(cf, key);
        defer self.allocator.free(real_key);

        var errptr: ?[*:0]u8 = null;
        c.rocksdb_put(
            self.db,
            self.write_opts,
            real_key.ptr,
            real_key.len,
            value.ptr,
            value.len,
            &errptr,
        );
        try maybeErr(errptr);
    }

    pub fn get(self: *RocksDb, key: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        return self.getInCF(.accounts, key, allocator);
    }

    pub fn getInCF(self: *RocksDb, cf: CFTag, key: []const u8, allocator: std.mem.Allocator) !?[]u8 {
        const real_key = try self.withPrefixedKey(cf, key);
        defer self.allocator.free(real_key);

        var errptr: ?[*:0]u8 = null;
        var value_len: usize = 0;
        const value_ptr = c.rocksdb_get(
            self.db,
            self.read_opts,
            real_key.ptr,
            real_key.len,
            &value_len,
            &errptr,
        );
        if (value_ptr == null) {
            if (errptr != null) return maybeErr(errptr);
            return null;
        }

        defer c.rocksdb_free(value_ptr);
        try maybeErr(errptr);
        const borrowed = value_ptr[0..value_len];
        const copied = try allocator.dupe(u8, borrowed);
        return copied;
    }

    pub fn delete(self: *RocksDb, key: []const u8) !void {
        return self.deleteInCF(.accounts, key);
    }

    pub fn deleteInCF(self: *RocksDb, cf: CFTag, key: []const u8) !void {
        const real_key = try self.withPrefixedKey(cf, key);
        defer self.allocator.free(real_key);

        var errptr: ?[*:0]u8 = null;
        c.rocksdb_delete(
            self.db,
            self.write_opts,
            real_key.ptr,
            real_key.len,
            &errptr,
        );
        try maybeErr(errptr);
    }

    pub fn accountIterator(self: *RocksDb) KvIterator {
        const iter = c.rocksdb_create_iterator(self.db, self.read_opts);
        defer c.rocksdb_iter_destroy(iter);

        var entries = std.array_list.Managed(KvEntry).init(self.allocator);

        c.rocksdb_iter_seek_to_first(iter);
        const accounts_prefix = cfPrefix(.accounts);
        while (c.rocksdb_iter_valid(iter) != 0) {
            var key_len: usize = 0;
            const key_ptr = c.rocksdb_iter_key(iter, &key_len);
            if (key_ptr == null or key_len == 0) {
                c.rocksdb_iter_next(iter);
                continue;
            }

            const key = key_ptr[0..key_len];
            if (key[0] != accounts_prefix) {
                c.rocksdb_iter_next(iter);
                continue;
            }

            if (key.len <= 1) {
                c.rocksdb_iter_next(iter);
                continue;
            }

            var value_len: usize = 0;
            const value_ptr = c.rocksdb_iter_value(iter, &value_len);

            const key_copy = self.allocator.dupe(u8, key[1..]) catch break;
            const value_copy = if (value_ptr == null)
                &.{}
            else
                self.allocator.dupe(u8, value_ptr[0..value_len]) catch {
                    self.allocator.free(key_copy);
                    break;
                };

            entries.append(.{
                .key = key_copy,
                .value = value_copy,
            }) catch {
                self.allocator.free(key_copy);
                if (value_ptr != null) self.allocator.free(value_copy);
                break;
            };
            c.rocksdb_iter_next(iter);
        }

        return KvIterator{
            .allocator = self.allocator,
            .entries = entries,
            .index = 0,
        };
    }
};

test "rocksdb wrapper stores, reads, iterates and deletes" {
    const test_path = "rocksdb_test_path_native";
    if (std.fs.cwd().openDir(test_path, .{})) |dir| {
        dir.close();
        try std.fs.cwd().deleteTree(test_path);
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    try std.fs.cwd().makePath(test_path);

    var db = try RocksDb.open(test_path);
    defer {
        db.close();
        std.fs.cwd().deleteTree(test_path) catch {};
    }
    const key = "acc-1";
    const value = "value";

    try db.put(key, value);
    const read = try db.get(key, std.testing.allocator) orelse unreachable;
    defer std.testing.allocator.free(read);
    try std.testing.expect(std.mem.eql(u8, value, read));

    var it = db.accountIterator();
    defer it.deinit();
    it.seekToFirst();
    try std.testing.expect(it.valid());
    try std.testing.expectEqualStrings(key, it.key().?);

    it.next();
    try std.testing.expect(!it.valid());
    try db.delete(key);
    const absent = try db.get(key, std.testing.allocator);
    try std.testing.expect(absent == null);
}
