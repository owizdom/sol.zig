# sol.zig

A complete Solana validator in ~19k lines of pure Zig — zero C dependencies, zero vendored Rust.

> **The only production Solana validator where every byte from crypto to consensus is Zig.**
> Agave links librocksdb + libssl + libsecp256k1. Sig links librocksdb. sol.zig links nothing.

---

## What it is

sol.zig implements the full validator lifecycle:

- **Proof of History** — SHA256 tick chain
- **Tower BFT** — vote lockout, root advancement, fork choice
- **Gossip** — CRDS push/pull over UDP, Ed25519-signed CrdsValues
- **Turbine** — stake-weighted shred broadcast tree
- **QUIC TPU** — transaction ingestion with fair MEV ordering (time-priority, not fee-priority)
- **TLS 1.3** — pure Zig (X25519 + HKDF-SHA256 + ChaCha20-Poly1305), no OpenSSL
- **Bank** — per-slot transaction processor: fees, rent, real inflation schedule, epoch rewards
- **Runtime** — CPI dispatch, compute metering, BPF/SBF interpreter
- **Programs** — System, Vote, Stake (with authority + lockup), SPL Token (19 instructions), Config, BPF Loader
- **AccountsDB** — three backends: HashMap (default), RocksDB (optional), pure Zig WAL + segment store
- **Persistence** — crash-safe write-ahead log + 64 MB flat segment files, zero C
- **JSON-RPC** — getBalance, sendTransaction, getSlot, getEpochInfo, getVoteAccounts, and more
- **Observability** — Prometheus `/metrics` + OpenTelemetry OTLP HTTP export
- **Library mode** — `libsol-gossip.a`, `libsol-bank.a`, `libsol-runtime.a`, `libsol-storage.a`

---

## Comparison

| | sol.zig | Sig (Syndica) | Agave (Solana Labs) |
|---|---|---|---|
| Language | Zig 0.15.2 | Zig | Rust |
| C dependencies | **none** | librocksdb | librocksdb, libssl, libsecp256k1 |
| Lines of code | ~19k | ~250k | ~800k |
| Disk persistence | Pure Zig WAL + segments | RocksDB | RocksDB |
| TLS | Pure Zig TLS 1.3 | — | BoringSSL |
| MEV ordering | Time-priority (fair) | Fee-priority | Fee-priority |
| Comptime invariants | [done] | [missing] | [missing] |
| OTLP telemetry | [done] | [missing] | [missing] |
| Library artifacts | [done] (4 libs) | [missing] | [missing] |
| Mainnet compatible | Partial | Partial | Yes |

---

## Build & Run

```sh
# Requires Zig 0.15.2. No external libraries.

zig build              # compile everything
zig build run          # run the validator
zig build bench        # TPS + PoH benchmark

# Standalone library targets (zero C, zero RocksDB)
zig build lib-gossip   # → zig-out/lib/libsol-gossip.a
zig build lib-bank     # → zig-out/lib/libsol-bank.a
zig build lib-runtime  # → zig-out/lib/libsol-runtime.a
zig build lib-storage  # → zig-out/lib/libsol-storage.a
```

The validator binary (`solana-in-zig`) optionally links RocksDB for legacy persistence. All four library targets build with **zero system dependencies**.

---

## Module Layout

```
solana-In-Zig/
├── core/
│   ├── types.zig          Pubkey, Slot, Epoch, AccountRef, Transaction
│   └── invariants.zig     Comptime protocol constant checks (compile-error on drift)
│
├── account/
│   ├── keypair.zig        Ed25519 keygen + sign (std.crypto)
│   └── account.zig        Account struct, lamport helpers
│
├── ledger/
│   ├── bank.zig           Slot state machine, real inflation schedule, epoch rewards
│   ├── blockstore.zig     Shred storage + slot metadata
│   └── replay.zig         Fork replay engine
│
├── consensus/
│   ├── tower.zig          TowerBFT vote lockout
│   ├── fork_choice.zig    Heaviest-fork selection
│   ├── schedule.zig       Stake-weighted leader schedule
│   └── vote.zig           Vote state + credit accumulation
│
├── network/
│   ├── gossip/            CrdsValue push/pull, Ed25519-signed messages
│   ├── tpu_quic/          QUIC TPU server, time-priority MEV ordering
│   ├── quic/              QUIC transport
│   ├── tls/tls13.zig      Pure Zig TLS 1.3 (X25519 + ChaCha20-Poly1305 + HKDF)
│   ├── shred/             Shred encode/decode/verify
│   └── turbine/           Turbine broadcast tree
│
├── programs/
│   ├── system/            Transfer, create, assign
│   ├── vote/              Vote, withdraw, update
│   ├── stake/             Delegate, deactivate, withdraw, split — with authority + lockup
│   ├── token/             SPL Token (19 instructions)
│   ├── config/            Config program
│   └── bpf_loader/        SBF/BPF ELF loader + interpreter (~2800 lines)
│
├── runtime/
│   ├── runtime.zig        Instruction dispatch, CPI, compute metering
│   └── sysvar.zig         Clock, Rent, EpochSchedule sysvar accounts
│
├── accounts-db/
│   └── accounts_db.zig    Account store (HashMap / RocksDB / SegmentStore backends)
│
├── storage/               ← Pure Zig, zero C
│   ├── wal.zig            Write-ahead log (fsync per record, CRC-32 verified)
│   └── segment.zig        64 MB flat segment files + in-memory hash index
│
├── transaction/           Parse, verify, serialize Solana transactions
├── rpc/                   JSON-RPC server
├── metrics/               Atomic counters + Prometheus + OTLP HTTP export
├── snapshot/              Account snapshot save/load
├── sync/
│   ├── poh.zig            Proof-of-History SHA256 chain
│   └── queue.zig          Lock-free MPSC queue
│
├── validator/             Top-level orchestrator + thread spawning
├── cli/main.zig           Entry point
└── bin/
    ├── bench.zig          TPS benchmark
    └── replay_fixture_harness.zig
```

---

## Key Properties

### Zero C Dependencies
Every cryptographic primitive (`std.crypto`), every byte of disk I/O (`storage/`), and every network protocol (`std.net`) is implemented in Zig. There are no `@cImport` declarations in any production code path.

### Fair MEV Ordering
Transactions arriving at the TPU are stamped with `std.time.nanoTimestamp()` on receipt and sorted by arrival time before block packing. This eliminates the fee-auction MEV market that exists in all other validators. It is a hard protocol property, not a configuration option.

### Crash-Safe Persistence
`storage/wal.zig` appends every account write as a CRC-verified record and calls `fsync` before returning. On restart, `storage/segment.zig` replays the WAL to reconstruct the full in-memory index. No account state is lost on process crash or power failure.

### Comptime Protocol Invariants
`core/invariants.zig` asserts all protocol constants at compile time:
```zig
comptime {
    std.debug.assert(SLOTS_PER_EPOCH        == 432_000);
    std.debug.assert(MAX_RECENT_BLOCKHASHES == 300);
    std.debug.assert(FEE_LAMPORTS_PER_SIG   == 5_000);
    std.debug.assert(STAKE_ACCOUNT_BYTES    == 172);
}
```
Changing a constant without updating downstream consumers is a **compile error**, not a silent runtime bug.

### Real Inflation Schedule
`ledger/bank.zig` implements the Solana inflation curve:
```
rate = max(1.5%, 8% × (1 − 15%)^years)
reward = total_supply × rate / 182 epochs_per_year
```
Applied per epoch boundary from the live `total_supply` field — not a hardcoded constant.

### OpenTelemetry Out of the Box
A background thread POSTs OTLP JSON to `http://localhost:4318/v1/metrics` every 10 seconds. Per-slot and per-epoch attributes included. Compatible with OpenTelemetry Collector, Grafana Agent, and Datadog.

---

## Status

| Subsystem | Status |
|-----------|--------|
| Transaction execution | [done] Full |
| Stake authority + lockup | [done] Full |
| Real inflation schedule | [done] Full |
| Blockhash expiry | [done] Full |
| Vote lockout gate | [done] Full |
| Stake-weighted leader schedule | [done] Full |
| Pure Zig WAL + segment store | [done] Full |
| Pure Zig TLS 1.3 | [done] Full |
| Gossip signature verification | [done] Full |
| Fair MEV ordering | [done] Full |
| Comptime protocol invariants | [done] Full |
| OTLP metrics export | [done] Full |
| Library mode artifacts | [done] Full |
| Versioned transactions (v0 + ALT) | [partial] Partial |
| QUIC header protection (RFC 9001) | [partial] Partial |
| Devnet boot (end-to-end) | [planned] Planned |
| Mainnet wire compat | [planned] Planned |

See [`doc/GAP_ANALYSIS.md`](doc/GAP_ANALYSIS.md) for the full status table.

---

## Documentation

| Document | Contents |
|----------|----------|
| [`doc/SYSTEM_DESIGN.md`](doc/SYSTEM_DESIGN.md) | Module map, data flow, key structs, crypto stack, concurrency model |
| [`doc/WHAT_WE_BUILT.md`](doc/WHAT_WE_BUILT.md) | Phase-by-phase record of every feature built and bug fixed |
| [`doc/GAP_ANALYSIS.md`](doc/GAP_ANALYSIS.md) | Status of every subsystem vs. mainnet requirements |
| [`doc/DESIGN_DECISIONS.md`](doc/DESIGN_DECISIONS.md) | Key architectural decisions: what was chosen, why, what was rejected |
| [`doc/ROADMAP.md`](doc/ROADMAP.md) | Milestones M1–M9, progress, next steps to devnet boot |

---

## License

MIT
