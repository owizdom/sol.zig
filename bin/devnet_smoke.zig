const std = @import("std");
const keypair = @import("keypair");
const validator_mod = @import("validator");
const base58 = @import("base58");
const bootstrap = @import("snapshot/bootstrap");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse flags.
    var persist = false;
    var snapshot_dir: ?[]const u8 = null;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip argv[0]
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--persist")) persist = true;
        if (std.mem.eql(u8, arg, "--snapshot-dir")) snapshot_dir = args.next();
    }

    const identity = keypair.KeyPair.generate();
    var id_b58: [44]u8 = undefined;
    const id_str = base58.encode(&identity.publicKey().bytes, &id_b58) catch "?";

    std.debug.print("Identity (base58): {s}\n", .{id_str});
    std.debug.print("  Verify: solana gossip --url devnet | grep {s}\n\n", .{id_str});

    var v = try validator_mod.Validator.init(allocator, identity);
    defer v.deinit();

    if (snapshot_dir) |dir| {
        try v.setSnapshotDir(dir);
        std.debug.print("snapshot dir: {s}\n", .{dir});
    }
    std.debug.print("\nRequired inbound UDP:\n", .{});
    std.debug.print("  8001 \xe2\x80\x94 gossip (CrdsValue exchange)\n", .{});
    std.debug.print("  8002 \xe2\x80\x94 TVU    (Turbine shred receive)\n\n", .{});

    v.bootstrapFromDevnet();
    v.startServices(8001, 8899, 9090) catch |err| switch (err) {
        error.AccessDenied => {
            std.debug.print("[warn] strict ports denied, trying fallback ports\n", .{});
            try v.startServices(9001, 9899, 9990);
        },
        else => return err,
    };
    defer v.stopServices();

    std.Thread.sleep(300 * std.time.ns_per_ms);
    v.seedGossipFromDevnet();

    // Advance 100 local slots.
    const start_slot = v.currentSlot();
    const target_slot = start_slot + 100;
    var i: usize = 0;
    while (v.currentSlot() < target_slot) : (i += 1) {
        _ = try v.runSlots(1);
        if ((i + 1) % 20 == 0) std.debug.print("slot {d}\n", .{v.currentSlot()});
    }
    std.debug.print("Done. Slot {d} -> {d}\n\n", .{ start_slot, v.currentSlot() });
    if (v.currentSlot() < target_slot) return error.InsufficientSlots;

    if (!persist) {
        // Quick check then exit.
        std.debug.print("Checking devnet visibility (waiting 15s)...\n", .{});
        std.Thread.sleep(15 * std.time.ns_per_s);
        const visible = bootstrap.isVisibleOnDevnet(allocator, identity.publicKey().bytes) catch false;
        if (visible) {
            std.debug.print("VISIBLE on devnet getClusterNodes ✓\n  Identity: {s}\n", .{id_str});
        } else {
            std.debug.print("NOT visible yet in getClusterNodes\n", .{});
            std.debug.print("  Identity: {s}\n", .{id_str});
            std.debug.print("  Firewall check: UDP port 8001 must be open inbound\n", .{});
            std.debug.print("  Run with --persist to keep polling\n", .{});
        }
        return;
    }

    // --persist mode: keep advancing slots + poll getClusterNodes every 30s.
    std.debug.print("Persist mode — polling getClusterNodes every 30s. Ctrl+C to stop.\n\n", .{});
    var poll_tick: usize = 0;
    var slot_tick: usize = 0;
    var visible_count: usize = 0;

    while (true) {
        // Run one slot, sleep ~10ms to avoid hammering CPU.
        _ = v.runSlots(1) catch {};
        slot_tick += 1;
        std.Thread.sleep(10 * std.time.ns_per_ms);

        // Re-seed gossip every 60s to refresh peer list.
        if (slot_tick % 6000 == 0) {
            v.seedGossipFromDevnet();
        }

        // Poll visibility every 30s (~3000 10ms ticks).
        poll_tick += 1;
        if (poll_tick % 3000 == 0) {
            const elapsed_s = poll_tick / 100;
            const shreds = v.shreds_received.load(.monotonic);
            std.debug.print("[{d}s] slot={d} shreds_recv={d}  checking getClusterNodes...\n",
                .{ elapsed_s, v.currentSlot(), shreds });

            const visible = bootstrap.isVisibleOnDevnet(allocator, identity.publicKey().bytes) catch |err| blk: {
                std.debug.print("  visibility check error: {s}\n", .{@errorName(err)});
                break :blk false;
            };

            if (visible) {
                visible_count += 1;
                std.debug.print("  VISIBLE ✓ (confirmed {d}x)\n", .{visible_count});
                std.debug.print("  Identity: {s}\n", .{id_str});
                if (visible_count >= 3) {
                    std.debug.print("\nStably visible on devnet ({d} consecutive checks). Done.\n", .{visible_count});
                    return;
                }
            } else {
                visible_count = 0;
                std.debug.print("  not visible yet — UDP 8001 inbound must be open\n", .{});
                std.debug.print("  manual: solana gossip --url devnet | grep {s}\n", .{id_str});
            }
        }
    }
}
