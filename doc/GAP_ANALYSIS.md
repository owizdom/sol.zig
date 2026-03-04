# sol.zig — Gap Analysis

Status of each subsystem relative to mainnet-production requirements.

Legend: [done] complete · [partial] partial · [missing] missing · [deferred] intentionally deferred

---

## Protocol Correctness

| Area | Status | Detail |
|------|--------|--------|
| Transaction signature verification | [done] | Ed25519 via `std.crypto.sign.Ed25519` |
| Fee deduction | [done] | 5,000 lamports × sig count, checked vs `FEE_LAMPORTS_PER_SIG` at compile time |
| Recent blockhash expiry | [done] | Reject if blockhash slot < `current_slot - 300`; ring trimmed in `advanceSlot()` |
| Compute unit metering | [done] | Budget enforced per instruction in `runtime.zig` |
| Inflation schedule | [done] | 8% → 1.5% decay curve (15%/yr taper), applied per epoch from `total_supply` |
| Epoch reward settlement | [done] | `bank.settleEpochRewards()` credits vote accounts proportionally |
| Vote lockout enforcement | [done] | `tower.canVote()` gates votes on TowerBFT lockout math |
| Active-stake filter on vote credits | [done] | Credits only if a delegated active stake account exists |
| Stake authority + lockup checks | [done] | `delegate/deactivate/withdraw` verify `authorized_staker/withdrawer`; lockup blocks withdrawal |
| Stake split correctness | [done] | Full `StakeState` copied to destination (fixed from lamports-only bug) |
| Stake account byte layout | [done] | 172 bytes (was 120, now checked via `core/invariants.zig`) |
| Leader schedule (stake-weighted) | [done] | VRF seed, iterates active stake accounts from AccountsDB |
| Versioned transactions (v0 + ALT) | [done] | v0 prefix detected; `resolveAddressLookups()` expands ALT indexes before instruction dispatch |
| Precompile programs (secp256k1, ed25519) | [missing] | Not implemented |
| Address lookup table program | [missing] | ALT create/extend/deactivate/close not implemented |
| Nonce accounts | [missing] | Durable nonces not implemented |

---

## Networking

| Area | Status | Detail |
|------|--------|--------|
| UDP gossip (push/pull) | [done] | Full CrdsValue push-pull cycle |
| Gossip signature verification | [done] | Ed25519 verify on `signed_push` (kind=6); unsigned legacy fallback |
| ContactInfo propagation | [done] | Peers discovered and stored; public IP fetched from `api4.ipify.org` and broadcast via `setAdvertisedAddr()` |
| TPU QUIC server | [done] | Accept QUIC streams, parse transactions |
| Fair MEV ordering | [done] | Transactions sorted by `arrival_ns` before block packing |
| Replay deduplication | [done] | `replay_window` HashMap(signature → timestamp), 30 s TTL |
| TLS 1.3 handshake (pure Zig) | [done] | X25519 ECDH, HKDF-SHA256, ChaCha20-Poly1305; used in QUIC crypto frames |
| QUIC packet number protection | [done] | `applyHeaderProtection()` / `deriveQuicHpKey()` — AES-128-ECB mask per RFC 9001 §5.4 |
| Shred propagation (Turbine) | [done] | Turbine tree built from stake-weighted peer set |
| Turbine shred receiver (TVU) | [done] | `TurbineReceiver` bound on `gossip_port+1` (O_NONBLOCK); `turbineLoop` accumulates FecSets, counts `shreds_received`; TVU addr correctly advertised |
| Shred Merkle proof validation | [partial] | Proof structure present; bit-for-bit Agave layout match not verified |
| Gossip bit-for-bit mainnet compat | [partial] | Protocol is correct; bincode serialization may diverge on edge cases |
| QUIC handshake interop (Agave peers) | [partial] | TLS wired via `onCryptoFrame`; devnet smoke confirms gossip peering; full QUIC stream interop pending firewall / shred replay |
| Shred assembly + entry replay | [missing] | FEC reassembly done; bincode Entry parsing and bank replay deferred M7 |
| Reed-Solomon FEC recovery | [missing] | Coding shreds stored but recovery not implemented; deferred M7 |

---

## Persistence

| Area | Status | Detail |
|------|--------|--------|
| In-memory HashMap store | [done] | Default backend; zero setup required |
| RocksDB store | [done] | Optional (`PERSISTENT=true`); requires librocksdb |
| Pure Zig segment store (WAL) | [done] | `storage/wal.zig` + `storage/segment.zig`; crash-safe via fsync |
| Crash recovery via WAL replay | [done] | Index rebuilt deterministically from WAL records |
| Segment compaction | [done] | `compact()` rewrites live entries, checkpoints WAL, deletes old segments |
| Snapshot auto-save on shutdown | [done] | `Validator.saveSnapshot()` called from `deinit()`; writes SOLSNAP1 to `--snapshot-dir` |
| Snapshot auto-load on restart | [done] | `maybeLoadSnapshot()` picks highest-slot file in dir; `bank.slot` restored; fixed zstd frame header bug (FHD 0x20→0xE0 with 8-byte FCS) |
| Genesis snapshot on first boot | [done] | `bootstrapFromDevnet()` writes slot-0 snapshot if no prior snapshot exists |
| WAL restart (bank.slot persistence) | [done] | Shutdown saves slot N → restart loads slot N → continues from N+1 |
| Snapshot hash verification | [partial] | Hash computed but not cross-checked against gossip snapshot hash |
| Devnet snapshot bootstrap (tar.bz2) | [missing] | Solana's snapshot format (bincode + RocksDB) is incompatible with SOLSNAP1; deferred M7 |
| Incremental snapshots | [missing] | Full snapshot only; no delta snapshots |
| AccountsDB parallelism | [missing] | Single mutex; no sharded locking |

---

## Programs (Native)

| Program | Status | Notes |
|---------|--------|-------|
| System | [done] | Create, transfer, assign, allocate |
| Vote | [done] | Vote, withdraw, update validator info |
| Stake | [done] | Initialize, delegate, deactivate, withdraw, split |
| Config | [done] | Store validator config |
| SPL Token | [done] | Mint, transfer, burn, approve, revoke, freeze, thaw, multisig |
| BPF/SBF Loader | [done] | Full eBPF/SBF interpreter (~2800 lines), CPI, return data |
| Associated Token Account | [missing] | Not implemented |
| Memo | [missing] | Not implemented |
| Address Lookup Table | [missing] | Not implemented |

---

## RPC

| Method | Status |
|--------|--------|
| `getBalance` | [done] |
| `getAccountInfo` | [done] |
| `sendTransaction` | [done] |
| `getRecentBlockhash` / `getLatestBlockhash` | [done] |
| `getSlot` | [done] |
| `getEpochInfo` | [done] |
| `getVoteAccounts` | [done] |
| `getProgramAccounts` | [partial] (no filter support) |
| `getTransaction` (historical) | [missing] |
| `simulateTransaction` | [missing] |
| WebSocket subscriptions | [missing] |

---

## Observability

| Area | Status | Detail |
|------|--------|--------|
| Prometheus `/metrics` endpoint | [done] | Counters, gauges, histogram sums/counts |
| OpenTelemetry OTLP HTTP export | [done] | JSON POST to `localhost:4318` every 10 s, per-slot attributes |
| Structured logging | [partial] | `std.debug.print` only; no structured log format |
| Distributed tracing | [missing] | Not implemented |

---

## Known Pre-existing Bugs Fixed During Phase 1-5

| Bug | File | Fix |
|-----|------|-----|
| `STAKE_ACCOUNT_BYTES = 120` (should be 172) | `stake.zig` | Corrected to 172, layout documented |
| `delegate()` wrote voter_pubkey to wrong offset | `stake.zig` | Uses `persistStakeData` at correct offset 116 |
| `&&` used for boolean AND | `bpf_loader.zig` | Replaced with `and` (×3 sites) |
| Nested `fn` inside test block | `bpf_loader.zig` | Hoisted to module scope as `nextRandLcg` |
| Duplicate `execute` name | `token.zig` | Private dispatcher renamed to `dispatchByTag` |
| `u3` counter overflow in CRC32 | `wal.zig` | Changed to `u4` |
| `try` in void-returning function | `tpu_quic.zig` | Changed to `catch {}` |
| Variable shadowing (`const tx` × 2) | `tpu_quic.zig` | Renamed to `wire_bytes` / `parsed_tx` |
| `File.reader()` API change (Zig 0.15.2) | `wal.zig` | Replaced with `readFull()` helper |
| `ArrayList.init(alloc)` removed (Zig 0.15.2) | `segment.zig` | Changed to `.empty`, allocator passed per-call |
| `X25519.secret_length_bytes` wrong name | `tls13.zig` | Changed to `[X25519.secret_length]u8` |
| `X25519.KeyPair.create(null)` removed | `tls13.zig` | Changed to `KeyPair.generate()` |
| `pub` used as variable name | `tls13.zig` | Renamed to `peer_pub` / `peer_key` |
