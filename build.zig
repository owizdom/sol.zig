const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const rocksdb_source = b.option(
        []const u8,
        "rocksdb-source",
        "Path to a RocksDB source tree (ignored; pure-Zig mode)",
    );
    const rocksdb_include = b.option(
        []const u8,
        "rocksdb-include",
        "Path to RocksDB headers (ignored; pure-Zig mode)",
    );
    const rocksdb_lib = b.option(
        []const u8,
        "rocksdb-lib",
        "Path to RocksDB libraries (ignored; pure-Zig mode)",
    );

    if (rocksdb_source) |path| {
        std.debug.print("[warn] rocksdb-source is ignored in pure-Zig build: {s}\n", .{path});
    }
    if (rocksdb_include) |path| {
        std.debug.print("[warn] rocksdb-include is ignored in pure-Zig build: {s}\n", .{path});
    }
    if (rocksdb_lib) |path| {
        std.debug.print("[warn] rocksdb-lib is ignored in pure-Zig build: {s}\n", .{path});
    }

    // Pure-Zig default: no RocksDB, no external C toolchain.
    const use_rocksdb = false;
    const resolved_rocksdb_lib_path: ?std.Build.LazyPath = null;
    const rocksdb_build_step: ?*std.Build.Step = null;

    // ── Storage modules (pure Zig, zero C deps) ───────────────────────────
    const storage_wal_mod = b.addModule("storage/wal", .{
        .root_source_file = b.path("storage/wal.zig"),
    });
    const storage_segment_mod = b.addModule("storage/segment", .{
        .root_source_file = b.path("storage/segment.zig"),
        .imports = &.{
            .{ .name = "wal", .module = storage_wal_mod },
        },
    });
    const tls13_mod = b.addModule("net/tls13", .{
        .root_source_file = b.path("network/tls/tls13.zig"),
    });
    const invariants_mod = b.addModule("core/invariants", .{
        .root_source_file = b.path("core/invariants.zig"),
    });

    // ── Base modules ──────────────────────────────────────────────────────
    const types_mod = b.addModule("types", .{
        .root_source_file = b.path("core/types.zig"),
    });
    const encoding_mod = b.addModule("encoding", .{
        .root_source_file = b.path("encoding/encoding.zig"),
    });
    const base58_mod = b.addModule("base58", .{
        .root_source_file = b.path("encoding/base58.zig"),
    });
    const snapshot_bootstrap_mod = b.addModule("snapshot/bootstrap", .{
        .root_source_file = b.path("snapshot/bootstrap.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "base58", .module = base58_mod },
        },
    });
    const keypair_mod = b.addModule("keypair", .{
        .root_source_file = b.path("account/keypair.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });
    const account_mod = b.addModule("account", .{
        .root_source_file = b.path("account/account.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });
    const rocksdb_mod = b.addModule("rocksdb", .{
        .root_source_file = b.path("rocksdb_stub.zig"),
    });
    const transaction_mod = b.addModule("transaction", .{
        .root_source_file = b.path("transaction/transaction.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "encoding", .module = encoding_mod },
        },
    });
    const poh_mod = b.addModule("poh", .{
        .root_source_file = b.path("sync/poh.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });
    const system_program_mod = b.addModule("system_program", .{
        .root_source_file = b.path("runtime/system_program.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });
    const sysvar_mod = b.addModule("sysvar", .{
        .root_source_file = b.path("runtime/sysvar.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });
    const accounts_db_mod = b.addModule("accounts_db", .{
        .root_source_file = b.path("accounts-db/accounts_db.zig"),
        .imports = &.{
            .{ .name = "types",           .module = types_mod },
            .{ .name = "rocksdb",         .module = rocksdb_mod },
            .{ .name = "storage/segment", .module = storage_segment_mod },
        },
    });
    const snapshot_mod = b.addModule("snapshot", .{
        .root_source_file = b.path("snapshot/snapshot.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "accounts_db", .module = accounts_db_mod },
        },
    });
    const consensus_vote_mod = b.addModule("consensus/vote", .{
        .root_source_file = b.path("consensus/vote.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    // ── Native programs ──────────────────────────────────────────────────
    const programs_system_mod = b.addModule("programs/system", .{
        .root_source_file = b.path("programs/system/system.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });
    const programs_vote_mod = b.addModule("programs/vote_program", .{
        .root_source_file = b.path("programs/vote/vote_program.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "consensus/vote", .module = consensus_vote_mod },
            .{ .name = "programs/system", .module = programs_system_mod },
        },
    });
    const programs_stake_mod = b.addModule("programs/stake", .{
        .root_source_file = b.path("programs/stake/stake.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });
    const programs_config_mod = b.addModule("programs/config", .{
        .root_source_file = b.path("programs/config/config.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });
    const programs_token_mod = b.addModule("programs/token", .{
        .root_source_file = b.path("programs/token/token.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "base58", .module = base58_mod },
        },
    });
    const programs_bpf_loader_mod = b.addModule("programs/bpf_loader", .{
        .root_source_file = b.path("programs/bpf_loader/bpf_loader.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "sysvar", .module = sysvar_mod },
        },
    });
    const metrics_mod = b.addModule("metrics", .{
        .root_source_file = b.path("metrics/metrics.zig"),
    });
    const queue_mod = b.addModule("sync/queue", .{
        .root_source_file = b.path("sync/queue.zig"),
    });
    const metrics_server_mod = b.addModule("metrics_server", .{
        .root_source_file = b.path("metrics-server/metrics_server.zig"),
        .imports = &.{.{ .name = "metrics", .module = metrics_mod }},
    });

    // ── Consensus and networking modules ────────────────────────────────
    const consensus_tower_mod = b.addModule("consensus/tower", .{
        .root_source_file = b.path("consensus/tower.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "consensus/vote", .module = consensus_vote_mod },
        },
    });
    const consensus_fork_choice_mod = b.addModule("consensus/fork_choice", .{
        .root_source_file = b.path("consensus/fork_choice.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "consensus/vote", .module = consensus_vote_mod },
        },
    });
    const consensus_schedule_mod = b.addModule("consensus/schedule", .{
        .root_source_file = b.path("consensus/schedule.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "sysvar", .module = sysvar_mod },
        },
    });

    const net_shred_mod = b.addModule("net/shred", .{
        .root_source_file = b.path("network/shred/shred.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "keypair", .module = keypair_mod },
        },
    });
    const net_gossip_mod = b.addModule("net/gossip", .{
        .root_source_file = b.path("network/gossip/gossip.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "keypair", .module = keypair_mod },
            .{ .name = "metrics", .module = metrics_mod },
        },
    });
    const net_turbine_mod = b.addModule("net/turbine", .{
        .root_source_file = b.path("network/turbine/turbine.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "net/shred", .module = net_shred_mod },
            .{ .name = "net/gossip", .module = net_gossip_mod },
        },
    });
    const net_quic_mod = b.addModule("net/quic", .{
        .root_source_file = b.path("network/quic/quic.zig"),
        .imports = &.{
            .{ .name = "net/tls13", .module = tls13_mod },
        },
    });
    const net_tls_cert_mod = b.addModule("net/tls_cert", .{
        .root_source_file = b.path("network/tls_cert/tls_cert.zig"),
    });

    // ── Runtime and ledger modules ─────────────────────────────────────
    const runtime_mod = b.addModule("runtime", .{
        .root_source_file = b.path("runtime/runtime.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "transaction", .module = transaction_mod },
            .{ .name = "accounts_db", .module = accounts_db_mod },
            .{ .name = "sysvar", .module = sysvar_mod },
            .{ .name = "programs/system", .module = programs_system_mod },
            .{ .name = "programs/vote_program", .module = programs_vote_mod },
            .{ .name = "programs/stake", .module = programs_stake_mod },
            .{ .name = "programs/config", .module = programs_config_mod },
            .{ .name = "programs/token", .module = programs_token_mod },
            .{ .name = "programs/bpf_loader", .module = programs_bpf_loader_mod },
            .{ .name = "metrics", .module = metrics_mod },
        },
    });
    const bank_mod = b.addModule("bank", .{
        .root_source_file = b.path("ledger/bank.zig"),
        .imports = &.{
            .{ .name = "types",               .module = types_mod },
            .{ .name = "transaction",          .module = transaction_mod },
            .{ .name = "accounts_db",          .module = accounts_db_mod },
            .{ .name = "keypair",              .module = keypair_mod },
            .{ .name = "sysvar",              .module = sysvar_mod },
            .{ .name = "programs/bpf_loader", .module = programs_bpf_loader_mod },
            .{ .name = "programs/stake/stake", .module = programs_stake_mod },
            .{ .name = "runtime",             .module = runtime_mod },
            .{ .name = "metrics",             .module = metrics_mod },
        },
    });
    const net_tpu_quic_mod = b.addModule("net/tpu_quic", .{
        .root_source_file = b.path("network/tpu_quic/tpu_quic.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "transaction", .module = transaction_mod },
            .{ .name = "bank", .module = bank_mod },
            .{ .name = "net/quic", .module = net_quic_mod },
        },
    });
    const blockstore_mod = b.addModule("blockstore", .{
        .root_source_file = b.path("ledger/blockstore.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "net/shred", .module = net_shred_mod },
            .{ .name = "snapshot", .module = snapshot_mod },
        },
    });
    const replay_mod = b.addModule("replay", .{
        .root_source_file = b.path("ledger/replay.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "accounts_db", .module = accounts_db_mod },
            .{ .name = "bank", .module = bank_mod },
            .{ .name = "blockstore", .module = blockstore_mod },
            .{ .name = "consensus/fork_choice", .module = consensus_fork_choice_mod },
            .{ .name = "consensus/tower", .module = consensus_tower_mod },
            .{ .name = "transaction", .module = transaction_mod },
            .{ .name = "metrics", .module = metrics_mod },
            .{ .name = "snapshot", .module = snapshot_mod },
        },
    });
    const rpc_mod = b.addModule("rpc", .{
        .root_source_file = b.path("rpc/rpc.zig"),
        .imports = &.{
            .{ .name = "base58", .module = base58_mod },
            .{ .name = "types", .module = types_mod },
            .{ .name = "bank", .module = bank_mod },
            .{ .name = "metrics", .module = metrics_mod },
            .{ .name = "sync/queue", .module = queue_mod },
            .{ .name = "accounts_db", .module = accounts_db_mod },
        },
    });
    const validator_mod = b.addModule("validator", .{
        .root_source_file = b.path("validator/validator.zig"),
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "keypair", .module = keypair_mod },
            .{ .name = "accounts_db", .module = accounts_db_mod },
            .{ .name = "bank", .module = bank_mod },
            .{ .name = "blockstore", .module = blockstore_mod },
            .{ .name = "consensus/fork_choice", .module = consensus_fork_choice_mod },
            .{ .name = "consensus/schedule", .module = consensus_schedule_mod },
            .{ .name = "consensus/tower", .module = consensus_tower_mod },
            .{ .name = "net/gossip", .module = net_gossip_mod },
            .{ .name = "replay", .module = replay_mod },
            .{ .name = "rpc", .module = rpc_mod },
            .{ .name = "transaction", .module = transaction_mod },
            .{ .name = "metrics", .module = metrics_mod },
            .{ .name = "metrics_server", .module = metrics_server_mod },
            .{ .name = "snapshot", .module = snapshot_mod },
            .{ .name = "snapshot/bootstrap", .module = snapshot_bootstrap_mod },
            .{ .name = "net/tpu_quic", .module = net_tpu_quic_mod },
            .{ .name = "net/tls_cert", .module = net_tls_cert_mod },
            .{ .name = "net/turbine",  .module = net_turbine_mod },
            .{ .name = "net/shred",    .module = net_shred_mod },
        },
    });

    // ── Main executable ─────────────────────────────────────────────────
    const exe_root_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_root_mod.addImport("types", types_mod);
    exe_root_mod.addImport("keypair", keypair_mod);
    exe_root_mod.addImport("base58", base58_mod);
    exe_root_mod.addImport("validator", validator_mod);

    const exe = b.addExecutable(.{
        .name = "solana-in-zig",
        .root_module = exe_root_mod,
    });
    exe.linkLibC();
    if (use_rocksdb) exe.linkSystemLibrary("rocksdb");
    if (resolved_rocksdb_lib_path) |lib_path| exe.addLibraryPath(lib_path);
    if (rocksdb_build_step) |step| exe.step.dependOn(step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the Solana-in-Zig demo");
    run_step.dependOn(&run_cmd.step);

    // ── Benchmark binary ─────────────────────────────────────────────────
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bin/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("types", types_mod);
    bench_mod.addImport("keypair", keypair_mod);
    bench_mod.addImport("base58", base58_mod);
    bench_mod.addImport("poh", poh_mod);
    bench_mod.addImport("transaction", transaction_mod);
    bench_mod.addImport("validator", validator_mod);

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    bench_exe.linkLibC();
    if (use_rocksdb) bench_exe.linkSystemLibrary("rocksdb");
    if (resolved_rocksdb_lib_path) |lib_path| bench_exe.addLibraryPath(lib_path);
    if (rocksdb_build_step) |step| bench_exe.step.dependOn(step);
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run throughput benchmarks");
    bench_step.dependOn(&run_bench.step);

    // ── Long-run fixture replay harness ──────────────────────────────────
    const harness_mod = b.createModule(.{
        .root_source_file = b.path("bin/replay_fixture_harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness_mod.addImport("types", types_mod);
    harness_mod.addImport("keypair", keypair_mod);
    harness_mod.addImport("validator", validator_mod);
    harness_mod.addImport("net/gossip", net_gossip_mod);

    const harness_exe = b.addExecutable(.{
        .name = "replay-harness",
        .root_module = harness_mod,
    });
    harness_exe.linkLibC();
    if (use_rocksdb) harness_exe.linkSystemLibrary("rocksdb");
    if (resolved_rocksdb_lib_path) |lib_path| harness_exe.addLibraryPath(lib_path);
    if (rocksdb_build_step) |step| harness_exe.step.dependOn(step);
    b.installArtifact(harness_exe);

    const run_harness = b.addRunArtifact(harness_exe);
    const harness_step = b.step("replay-harness", "Run continuous fixture replay against local validator services");
    harness_step.dependOn(&run_harness.step);

    // ── Devnet smoke test binary ───────────────────────────────────────
    const devnet_smoke_mod = b.createModule(.{
        .root_source_file = b.path("bin/devnet_smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    devnet_smoke_mod.addImport("keypair", keypair_mod);
    devnet_smoke_mod.addImport("validator", validator_mod);
    devnet_smoke_mod.addImport("base58", base58_mod);
    devnet_smoke_mod.addImport("snapshot/bootstrap", snapshot_bootstrap_mod);

    const devnet_smoke_exe = b.addExecutable(.{
        .name = "devnet-smoke",
        .root_module = devnet_smoke_mod,
    });
    devnet_smoke_exe.linkLibC();
    if (use_rocksdb) devnet_smoke_exe.linkSystemLibrary("rocksdb");
    if (resolved_rocksdb_lib_path) |lib_path| devnet_smoke_exe.addLibraryPath(lib_path);
    if (rocksdb_build_step) |step| devnet_smoke_exe.step.dependOn(step);
    b.installArtifact(devnet_smoke_exe);

    const run_devnet_smoke = b.addRunArtifact(devnet_smoke_exe);
    const devnet_smoke_step = b.step("devnet-smoke", "Run devnet smoke harness");
    devnet_smoke_step.dependOn(&run_devnet_smoke.step);

    // ── Tests (all modules via main test block) ────────────────────────
    const test_root_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root_mod.addImport("types", types_mod);
    test_root_mod.addImport("base58", base58_mod);
    test_root_mod.addImport("encoding", encoding_mod);
    test_root_mod.addImport("keypair", keypair_mod);
    test_root_mod.addImport("account", account_mod);
    test_root_mod.addImport("transaction", transaction_mod);
    test_root_mod.addImport("poh", poh_mod);
    test_root_mod.addImport("system_program", system_program_mod);
    test_root_mod.addImport("sysvar", sysvar_mod);
    test_root_mod.addImport("accounts_db", accounts_db_mod);
    test_root_mod.addImport("programs/system", programs_system_mod);
    test_root_mod.addImport("programs/vote_program", programs_vote_mod);
    test_root_mod.addImport("runtime", runtime_mod);
    test_root_mod.addImport("net/shred", net_shred_mod);
    test_root_mod.addImport("net/gossip", net_gossip_mod);
    test_root_mod.addImport("net/turbine", net_turbine_mod);
    test_root_mod.addImport("net/quic", net_quic_mod);
    test_root_mod.addImport("net/tpu_quic", net_tpu_quic_mod);
    test_root_mod.addImport("net/tls_cert", net_tls_cert_mod);
    test_root_mod.addImport("net/tls13", tls13_mod);
    test_root_mod.addImport("storage/wal", storage_wal_mod);
    test_root_mod.addImport("storage/segment", storage_segment_mod);
    test_root_mod.addImport("core/invariants", invariants_mod);
    test_root_mod.addImport("consensus/vote", consensus_vote_mod);
    test_root_mod.addImport("consensus/tower", consensus_tower_mod);
    test_root_mod.addImport("consensus/fork_choice", consensus_fork_choice_mod);
    test_root_mod.addImport("consensus/schedule", consensus_schedule_mod);
    test_root_mod.addImport("bank", bank_mod);
    test_root_mod.addImport("blockstore", blockstore_mod);
    test_root_mod.addImport("replay", replay_mod);
    test_root_mod.addImport("rpc", rpc_mod);
    test_root_mod.addImport("sync/queue", queue_mod);
    test_root_mod.addImport("snapshot", snapshot_mod);
    test_root_mod.addImport("validator", validator_mod);

    const tests = b.addTest(.{
        .root_module = test_root_mod,
    });
    tests.linkLibC();
    if (use_rocksdb) tests.linkSystemLibrary("rocksdb");
    if (resolved_rocksdb_lib_path) |lib_path| tests.addLibraryPath(lib_path);
    if (rocksdb_build_step) |step| tests.step.dependOn(step);

    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);

    // ── Library mode (Phase 5d) ────────────────────────────────────────────
    // Each subsystem is exposed as a standalone static library artifact so
    // external projects can embed just the piece they need (e.g. gossip only).
    // Build with: zig build lib-gossip | lib-bank | lib-runtime | lib-storage

    const lib_gossip = b.addLibrary(.{
        .name        = "sol-gossip",
        .linkage     = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("network/gossip/gossip.zig"),
            .target           = target,
            .optimize         = optimize,
            .imports          = &.{
                .{ .name = "types",   .module = types_mod },
                .{ .name = "keypair", .module = keypair_mod },
                .{ .name = "metrics", .module = metrics_mod },
            },
        }),
    });
    b.installArtifact(lib_gossip);
    const lib_gossip_step = b.step("lib-gossip", "Build the gossip subsystem as a standalone static library");
    lib_gossip_step.dependOn(&lib_gossip.step);

    const lib_bank = b.addLibrary(.{
        .name        = "sol-bank",
        .linkage     = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("ledger/bank.zig"),
            .target           = target,
            .optimize         = optimize,
            .imports          = &.{
                .{ .name = "types",               .module = types_mod },
                .{ .name = "transaction",          .module = transaction_mod },
                .{ .name = "accounts_db",          .module = accounts_db_mod },
                .{ .name = "keypair",              .module = keypair_mod },
                .{ .name = "sysvar",              .module = sysvar_mod },
                .{ .name = "programs/bpf_loader", .module = programs_bpf_loader_mod },
                .{ .name = "programs/stake/stake", .module = programs_stake_mod },
                .{ .name = "runtime",             .module = runtime_mod },
                .{ .name = "metrics",             .module = metrics_mod },
            },
        }),
    });
    b.installArtifact(lib_bank);
    const lib_bank_step = b.step("lib-bank", "Build the bank (transaction processor) as a standalone static library");
    lib_bank_step.dependOn(&lib_bank.step);

    const lib_runtime = b.addLibrary(.{
        .name        = "sol-runtime",
        .linkage     = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/runtime.zig"),
            .target           = target,
            .optimize         = optimize,
            .imports          = &.{
                .{ .name = "types",                .module = types_mod },
                .{ .name = "transaction",           .module = transaction_mod },
                .{ .name = "accounts_db",           .module = accounts_db_mod },
                .{ .name = "sysvar",               .module = sysvar_mod },
                .{ .name = "programs/system",      .module = programs_system_mod },
                .{ .name = "programs/vote_program", .module = programs_vote_mod },
                .{ .name = "programs/stake",       .module = programs_stake_mod },
                .{ .name = "programs/config",      .module = programs_config_mod },
                .{ .name = "programs/token",       .module = programs_token_mod },
                .{ .name = "programs/bpf_loader",  .module = programs_bpf_loader_mod },
                .{ .name = "metrics",              .module = metrics_mod },
            },
        }),
    });
    b.installArtifact(lib_runtime);
    const lib_runtime_step = b.step("lib-runtime", "Build the runtime (program executor) as a standalone static library");
    lib_runtime_step.dependOn(&lib_runtime.step);

    const lib_storage = b.addLibrary(.{
        .name        = "sol-storage",
        .linkage     = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("storage/segment.zig"),
            .target           = target,
            .optimize         = optimize,
            .imports          = &.{
                .{ .name = "wal", .module = storage_wal_mod },
            },
        }),
    });
    b.installArtifact(lib_storage);
    const lib_storage_step = b.step("lib-storage", "Build the pure-Zig WAL+segment store as a standalone static library");
    lib_storage_step.dependOn(&lib_storage.step);
}
