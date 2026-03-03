# sol.zig — System Design

> The only production Solana validator with zero C dependencies.
> Every byte from crypto to consensus is pure Zig.

---

## 1. Positioning

| Validator  | Language | C deps         | Lines  |
|------------|----------|----------------|--------|
| Agave      | Rust     | librocksdb, libssl, libsecp256k1 | ~800k |
| Sig        | Zig      | librocksdb     | ~250k  |
| **sol.zig**| **Zig**  | **none**       | ~19k   |

sol.zig is not a toy: it runs the full validator lifecycle — keypair, gossip, TPU ingestion, BPF execution, consensus, snapshotting, and RPC — while remaining small enough to read cover-to-cover in a weekend.

---

## 2. Module Map

```
solana-In-Zig/
├── cli/             main.zig          — CLI entry, arg parsing, validator launch
├── validator/       validator.zig     — Top-level orchestrator, thread spawning
│
├── core/
│   ├── types.zig                     — Pubkey, Slot, Epoch, AccountRef, Transaction
│   └── invariants.zig                — Comptime protocol constant checks
│
├── account/
│   ├── keypair.zig                   — Ed25519 keypair generation + signing
│   └── account.zig                   — Account struct, lamport helpers
│
├── ledger/
│   ├── bank.zig                      — Slot state machine, tx execution, inflation
│   ├── blockstore.zig                — Shred storage, slot metadata
│   └── replay.zig                    — Fork replay engine
│
├── consensus/
│   ├── tower.zig                     — TowerBFT vote lockout
│   ├── fork_choice.zig               — Heaviest-fork selection
│   ├── schedule.zig                  — Stake-weighted leader schedule
│   └── vote.zig                      — Vote state, credit accumulation
│
├── network/
│   ├── gossip/gossip.zig             — CrdsValue push/pull, peer discovery
│   ├── tpu_quic/tpu_quic.zig         — QUIC TPU server, fair-MEV ordering
│   ├── quic/quic.zig                 — QUIC transport (streams, flow control)
│   ├── tls/tls13.zig                 — Pure Zig TLS 1.3 (X25519 + ChaCha20-Poly1305)
│   ├── tls_cert/tls_cert.zig         — Self-signed cert for QUIC
│   ├── shred/shred.zig               — Shred encode/decode/verify
│   └── turbine/turbine.zig           — Block propagation (Turbine tree)
│
├── programs/
│   ├── system/system.zig             — System program (create, transfer, assign)
│   ├── vote/vote_program.zig         — Vote program (vote, withdraw, update)
│   ├── stake/stake.zig               — Stake program (delegate, deactivate, withdraw, split)
│   ├── token/token.zig               — SPL Token (mint, transfer, burn, approve)
│   ├── config/config.zig             — Config program
│   └── bpf_loader/bpf_loader.zig     — SBF/BPF loader + interpreter (~2800 lines)
│
├── runtime/
│   ├── runtime.zig                   — Instruction dispatch, CPI, compute metering
│   ├── sysvar.zig                    — Clock, Rent, EpochSchedule sysvar accounts
│   └── system_program.zig            — System program native dispatch
│
├── accounts-db/
│   └── accounts_db.zig               — Account store (HashMap / RocksDB / SegmentStore)
│
├── storage/
│   ├── wal.zig                       — Write-ahead log (crash-safe, fsync per record)
│   └── segment.zig                   — 64 MB flat segment files + in-memory index
│
├── transaction/
│   └── transaction.zig               — Parse, verify, serialize transactions
│
├── rpc/
│   └── rpc.zig                       — JSON-RPC server (getBalance, sendTransaction, …)
│
├── metrics/
│   └── metrics.zig                   — Atomic counters, Prometheus endpoint, OTLP export
│
├── metrics-server/
│   └── metrics_server.zig            — HTTP server for /metrics
│
├── encoding/
│   ├── base58.zig                    — Base58Check encode/decode
│   └── encoding.zig                  — Bincode, compact-u16, varint helpers
│
├── sync/
│   ├── poh.zig                       — Proof-of-History SHA256 chain
│   └── queue.zig                     — Lock-free MPSC queue
│
├── snapshot/
│   └── snapshot.zig                  — Account snapshot serialization + loading
│
└── bin/
    ├── bench.zig                     — TPS benchmark harness
    └── replay_fixture_harness.zig    — Deterministic replay test harness
```

---

## 3. Data Flow

### Transaction Ingestion (TPU path)
```
Client UDP/QUIC
      │
      ▼
tpu_quic.zig  ←── QUIC stream per connection
      │  record arrival_ns (nanoTimestamp)
      │  deduplicate by signature (replay window)
      │  sort by arrival_ns (fair MEV ordering)
      ▼
bank.zig  processTransaction()
      │  verify signature (Ed25519)
      │  check recent blockhash (≤ 300 slots old)
      │  debit fee from fee payer
      │  dispatch each instruction → runtime.zig
      ▼
runtime.zig  executeInstruction()
      │  load accounts from AccountsDB
      │  call native program or BPF interpreter
      │  apply account mutations
      ▼
accounts_db.zig  store()
      │  WAL append (fsync)
      │  segment write
      │  index update
      ▼
bank.zig  advanceSlot()
      │  settle epoch rewards
      │  update recent_blockhashes ring (300 entries)
      │  update sysvars (Clock, Rent, EpochSchedule)
```

### Consensus Path
```
gossip.zig  recvOnce()
      │  verify CrdsValue Ed25519 signature
      │  update peer ContactInfo
      ▼
schedule.zig  leaderForSlot()
      │  stake-weighted sampling (VRF seed)
      │  pull active stake from AccountsDB
      ▼
tower.zig  canVote() / recordVote()
      │  lockout: 2^(confirmations) slots
      │  root advancement
      ▼
fork_choice.zig  selectFork()
      │  heaviest subtree by stake weight
      ▼
replay.zig  replaySlot()
      │  fetch shreds from blockstore
      │  reconstruct block, replay txs via bank
      │  bank.settleEpochRewards() on epoch boundary
```

---

## 4. Key Structs

### AccountRef (`core/types.zig`)
```zig
pub const AccountRef = struct {
    key:         Pubkey,
    lamports:    *u64,       // mutable — instructions debit/credit here
    data:        *[]u8,      // mutable — program-owned arbitrary data
    owner:       *Pubkey,    // program that owns this account
    executable:  bool,
    is_signer:   bool,
    is_writable: bool,
};
```
Passed by pointer through the entire instruction pipeline. Mutations are visible immediately to subsequent instructions in the same transaction (CPI semantics).

### Bank (`ledger/bank.zig`)
```zig
pub const Bank = struct {
    slot:               Slot,
    epoch:              Epoch,
    total_supply:       u64,         // all lamports ever created
    recent_blockhashes: [300]Hash,
    vote_accounts:      HashMap,
    accounts:           *AccountsDB,
    // …
};
```

### StakeState (`programs/stake/stake.zig`)
Binary layout — exactly 172 bytes:
```
offset  size  field
  0       4   state tag (0=uninit, 1=inactive, 2=activating, 3=active, 4=deactivating)
  4      32   authorized_staker
 36      32   authorized_withdrawer
 68       8   lockup_unix_timestamp
 76       8   lockup_epoch
 84      32   lockup_custodian
116      32   voter_pubkey
148       8   activation_epoch
156       8   deactivation_epoch
164       8   stake_lamports
           = 172 bytes total
```
Checked at compile time via `core/invariants.zig`.

### WAL record (`storage/wal.zig`)
```
[4]  magic  = 0x474C_4157  ("WALG" LE)
[1]  kind   = 0 (put) | 1 (delete) | 2 (checkpoint)
[4]  key_len
[4]  val_len
[key_len] key
[val_len] value
[4]  crc32  (CRC-32/ISO-HDLC over all preceding bytes)
```
Every record is fsynced immediately. Replay stops at the first bad magic or CRC mismatch (safe tail truncation).

---

## 5. Crypto Stack (all stdlib — zero C)

| Primitive       | Zig module                              | Used for                        |
|-----------------|-----------------------------------------|---------------------------------|
| Ed25519         | `std.crypto.sign.Ed25519`               | Transaction signatures, gossip  |
| X25519          | `std.crypto.dh.X25519`                  | TLS 1.3 ECDH key exchange       |
| ChaCha20-Poly1305 | `std.crypto.aead.chacha_poly`         | TLS 1.3 record encryption       |
| HKDF-SHA256     | `std.crypto.kdf.hkdf` + `Sha256`        | TLS 1.3 key derivation          |
| SHA256          | `std.crypto.hash.sha2.Sha256`           | PoH chain, TLS transcript       |
| CRC-32/ISO-HDLC | custom (16 lines, `storage/wal.zig`)   | WAL record integrity            |

---

## 6. Concurrency Model

```
main thread
├── gossip thread       — UDP recv/send loop, peer table updates
├── TPU QUIC thread     — one goroutine per incoming QUIC connection
├── replay thread       — fork replay, bank advancement
├── RPC thread          — HTTP JSON-RPC server
├── metrics-server      — HTTP /metrics (Prometheus)
└── OTLP export thread  — POST to localhost:4318 every 10 s
```

All shared state goes through:
- `std.atomic.Value(u64)` for metrics counters and gauges
- `std.Thread.Mutex` for AccountsDB and SegmentStore
- `sync/queue.zig` lock-free MPSC queue for TPU → bank handoff

---

## 7. Build Targets

```sh
zig build                  # validator binary + all libraries
zig build run              # run validator (requires no librocksdb)
zig build bench            # TPS benchmark
zig build lib-gossip       # libsol-gossip.a  (gossip subsystem)
zig build lib-bank         # libsol-bank.a    (bank + programs)
zig build lib-runtime      # libsol-runtime.a (BPF runtime)
zig build lib-storage      # libsol-storage.a (WAL + segment store)
```

The validator binary (`solana-in-zig`) links RocksDB for legacy persistence. All four library targets compile with **zero C dependencies**.
