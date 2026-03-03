# sol.zig — Roadmap & Progress

## Legend
- [done] Complete
- [in progress] In progress / partial
- [planned] Planned
- [idea] Idea / stretch goal

---

## Milestones

### M1 — Protocol Correctness  [done] Complete

Goal: Every instruction the validator processes must follow the Solana spec.

| Task | Status |
|------|--------|
| Stake authority + lockup enforcement | [done] |
| Correct stake account byte layout (172 bytes) | [done] |
| Vote credit active-stake gate | [done] |
| Real inflation schedule (8% → 1.5% decay) | [done] |
| Blockhash expiry (reject > 300 slots old) | [done] |
| Real stake-weighted leader schedule | [done] |
| Comptime protocol invariants | [done] |
| All pre-existing Zig 0.15.2 API bugs fixed | [done] |

---

### M2 — Zero-C Persistence  [done] Complete

Goal: Replace the C++ RocksDB dependency with a pure Zig disk store.

| Task | Status |
|------|--------|
| Write-ahead log (WAL) with CRC-32 + fsync | [done] |
| Flat segment files (64 MB, append-only) | [done] |
| In-memory index rebuilt from WAL on crash | [done] |
| Segment compaction + WAL checkpoint | [done] |
| AccountsDB backend switch (`SEGMENT_STORE=true`) | [done] |
| 5 passing tests (round-trip, crash-replay, compact) | [done] |

---

### M3 — Zero-C Crypto  [done] Complete

Goal: Replace OpenSSL/libssl with pure Zig TLS 1.3.

| Task | Status |
|------|--------|
| X25519 ECDH key exchange | [done] |
| HKDF-SHA256 per RFC 8446 §7.1 | [done] |
| ChaCha20-Poly1305 AEAD record encryption | [done] |
| ClientHello / ServerHello message builders | [done] |
| Sequence-number nonce construction | [done] |
| 4 passing tests (determinism, round-trip, parsing, handshake) | [done] |

---

### M4 — Wire Compatibility  [in progress] Partial

Goal: Gossip and TPU traffic accepted by Agave peers on devnet.

| Task | Status |
|------|--------|
| Gossip CrdsValue Ed25519 signature (sign + verify) | [done] |
| Signed-push message kind=6 (backward compatible) | [done] |
| Fair MEV ordering (arrival_ns time-priority) | [done] |
| Transaction replay deduplication | [done] |
| Versioned transactions v0 prefix detection | [in progress] |
| Address Lookup Table account resolution | [planned] |
| Shred Merkle proof bit-for-bit Agave layout | [in progress] |
| QUIC packet number protection (RFC 9001 §5.4) | [planned] |
| Devnet gossip interop test | [planned] |

---

### M5 — Observability  [done] Complete

Goal: Production-grade monitoring out of the box.

| Task | Status |
|------|--------|
| Prometheus `/metrics` endpoint | [done] |
| Atomic counters + gauges for all subsystems | [done] |
| OTLP HTTP export (JSON POST to localhost:4318) | [done] |
| Per-slot / per-epoch attributes on OTLP metrics | [done] |
| Background flush thread (10 s interval) | [done] |
| Library mode build targets | [done] |

---

### M6 — Devnet Boot  [planned] Planned

Goal: Validator boots, joins devnet gossip, receives shreds, replays slots.

| Task | Status |
|------|--------|
| End-to-end boot sequence test | [planned] |
| Download genesis from devnet | [planned] |
| Download snapshot from trusted validator | [planned] |
| Join gossip cluster, propagate ContactInfo | [planned] |
| Receive and replay shreds | [planned] |
| Advance slot counter in sync with cluster | [planned] |
| Survive restart with WAL-backed account state | [planned] |

---

### M7 — Full Mainnet Wire Compat  [planned] Planned

Goal: Every message byte-for-byte compatible with Agave.

| Task | Status |
|------|--------|
| v0 transactions with ALT resolution | [planned] |
| Shred Merkle exact byte layout | [planned] |
| QUIC header protection (AES-ECB mask) | [planned] |
| Nonce accounts (durable transaction nonces) | [planned] |
| Secp256k1 and Ed25519 precompile programs | [planned] |
| Gossip pull filters (Bloom) | [planned] |
| Snapshot hash cross-validation via gossip | [planned] |
| Incremental snapshots | [planned] |

---

### M8 — Performance  [idea] Stretch

Goal: Competitive TPS on commodity hardware.

| Task | Status |
|------|--------|
| Parallel transaction execution (non-conflicting accounts) | [idea] |
| Sharded AccountsDB mutex (reduce lock contention) | [idea] |
| SIMD-accelerated Ed25519 batch verification | [idea] |
| Async I/O via `io_uring` (Linux) | [idea] |
| BPF JIT compiler (replace interpreter) | [idea] |
| TPS benchmark: target 50k tx/s on M-series Mac | [idea] |

---

### M9 — Ecosystem  [idea] Stretch

Goal: sol.zig as a platform, not just a binary.

| Task | Status |
|------|--------|
| `libsol-gossip.a` — embed gossip in any Zig/C project | [done] |
| `libsol-bank.a` — embed bank + programs | [done] |
| `libsol-runtime.a` — embed BPF runtime | [done] |
| `libsol-storage.a` — embed WAL + segments | [done] |
| Zig package index (`build.zig.zon` publishable) | [idea] |
| C header for `libsol-gossip` (C FFI) | [idea] |
| Python bindings via ctypes | [idea] |
| Fuzzing harness for BPF interpreter | [idea] |
| Formal property tests for stake lifecycle | [idea] |

---

## Progress Summary

```
M1 Protocol Correctness   ████████████████████  100%  [done]
M2 Zero-C Persistence     ████████████████████  100%  [done]
M3 Zero-C Crypto          ████████████████████  100%  [done]
M4 Wire Compatibility     ████████████░░░░░░░░   60%  [in progress]
M5 Observability          ████████████████████  100%  [done]
M6 Devnet Boot            ░░░░░░░░░░░░░░░░░░░░    0%  [planned]
M7 Full Mainnet Compat    ░░░░░░░░░░░░░░░░░░░░    0%  [planned]
M8 Performance            ░░░░░░░░░░░░░░░░░░░░    0%  [idea]
M9 Ecosystem              ████░░░░░░░░░░░░░░░░   20%  [in progress]
```

**Overall: ~65% of production-ready Solana validator.**

---

## What Remains to be a Full Validator

The shortest path to devnet participation (M6):

1. **Wire QUIC TLS** — connect `tls13.zig` into `quic.zig`'s `onCryptoData()`, apply QUIC header protection per RFC 9001
2. **ALT resolution** — resolve Address Lookup Table accounts for v0 transactions before instruction dispatch
3. **Snapshot bootstrap** — download + verify a trusted snapshot on first boot, check hash via gossip
4. **Integration smoke test** — `zig build run` → join devnet → advance 100 slots without divergence
