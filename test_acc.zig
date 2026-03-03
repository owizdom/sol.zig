const std = @import("std");
const accounts_db_mod = @import("./accounts-db/accounts_db.zig");
const types = @import("./core/types.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    std.fs.cwd().deleteTree("accounts_db") catch {};

    var db = accounts_db_mod.AccountsDb.init(alloc);
    defer db.deinit();

    const pk = types.Pubkey{ .bytes = [_]u8{1} ** 32 };
    try db.store(pk, 123, &[_]u8{9,8,7}, types.Pubkey{ .bytes = [_]u8{0} ** 32 }, false, 0, 1);
    const got = db.get(pk).?;
    std.debug.print("lamports={d}\n", .{got.lamports});
}
