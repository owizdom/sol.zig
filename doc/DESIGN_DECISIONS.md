# sol.zig — Key Design Decisions

Each entry explains *what* was decided, *why*, and *what was rejected*.

---

## 1. Zero C Dependencies

**Decision:** Link no C libraries. Use only Zig stdlib.

**Why:**
- Agave links `librocksdb`, `libssl`, `libsecp256k1`, `libsodium`
- Sig links `librocksdb`
- Each C dependency adds a build complexity, a CVE surface, a portability constraint, and an audit burden
- Zig's `std.crypto` covers Ed25519, X25519, ChaCha20-Poly1305, HKDF-SHA256, SHA256 — every primitive the validator needs
- `storage/wal.zig` + `storage/segment.zig` covers the persistence tier

**Rejected:** Using `libsodium` for crypto (smaller diff from Agave, but breaks the zero-C property).
**Rejected:** `zig-sqlite` for persistence (SQLite is C; segment store is simpler and faster for the access pattern).

---

## 2. WAL + Flat Segments (not LSM)

**Decision:** Disk store is a write-ahead log + fixed-size append-only segment files, with a full in-memory index.

**Why:**
- RocksDB (LSM) is optimized for range scans. AccountsDB access is almost entirely point lookups by pubkey.
- Flat segments + hash map index gives O(1) get, O(1) put, single fsync per write — optimal for the access pattern.
- The full index fits in RAM: 32-byte key + 12-byte Pointer × 100M accounts = ~4.4 GB at Solana mainnet scale. Acceptable on validator hardware (192 GB+ RAM is standard).
- WAL makes crash recovery deterministic — replay the log, rebuild the index.

**Rejected:** B-tree on disk (complex, not needed for point lookups).
**Rejected:** mmap-based store (memory management complexity, OS-specific behavior).
**Rejected:** SQLite (C dependency; B-tree overhead for hash-lookups).

---

## 3. ChaCha20-Poly1305 for TLS (not AES-GCM)

**Decision:** TLS 1.3 record layer uses `TLS_CHACHA20_POLY1305_SHA256`, not `TLS_AES_128_GCM_SHA256`.

**Why:**
- ChaCha20-Poly1305 is constant-time without hardware acceleration — no timing side-channels on CPUs without AES-NI
- All Apple Silicon Macs lack hardware AES acceleration in the same way x86 does; ChaCha20 is faster here
- `std.crypto.aead.chacha_poly.ChaCha20Poly1305` is available in Zig stdlib; AES-GCM is also available but ChaCha20 is simpler
- RFC 8446 mandates `TLS_AES_128_GCM_SHA256` as the mandatory-to-implement cipher but permits ChaCha20; Agave peers accept both

**Rejected:** AES-GCM (hardware-dependent performance, more complex key schedule).

---

## 4. Comptime Protocol Invariants

**Decision:** Protocol constants are checked with `std.debug.assert` inside a `comptime {}` block in `core/invariants.zig`.

**Why:**
- Silent constant drift is a real bug class: changing `SLOTS_PER_EPOCH` in one file but not in downstream consumers produces incorrect behavior that only manifests at runtime after epoch transitions
- `comptime {}` assertions turn this into a compile error — caught before any binary ships
- Zero runtime cost: the block is evaluated once by the compiler

**Implementation:**
```zig
comptime {
    std.debug.assert(SLOTS_PER_EPOCH       == 432_000);
    std.debug.assert(MAX_RECENT_BLOCKHASHES == 300);
    std.debug.assert(FEE_LAMPORTS_PER_SIG   == 5_000);
    std.debug.assert(STAKE_ACCOUNT_BYTES    == 172);
    std.debug.assert(SLOTS_PER_EPOCH % 32   == 0);
}
```

**Rejected:** Runtime validation (too late — the binary is already running).
**Rejected:** Unit tests (only caught when tests are run, not at every build).

---

## 5. Fair MEV Ordering (Time-Priority)

**Decision:** Transactions are sorted by `arrival_ns` (nanosecond timestamp on receipt) before block packing. No fee-based reordering.

**Why:**
- Fee-priority ordering (used by Agave, Sig, every other validator) creates a market for MEV: bots pay higher fees to get their transactions ordered before others
- Time-priority ordering eliminates this: every transaction is served in the order it arrived. A bot cannot buy its way to the front.
- This is a hard guarantee. It cannot be circumvented by paying higher fees.
- Implementation cost: 8 lines of Zig (`PendingTx` struct + `std.sort.pdq` call)

**Rejected:** Fee-priority (MEV extraction harms users).
**Rejected:** Random ordering (punishes early submitters, creates no trust).

**Trade-off:** Time-priority makes validator revenue slightly lower (no fee auctions). This is an intentional stance.

---

## 6. Gossip kind=6 for Signed Push (Backward Compatible)

**Decision:** CrdsValue signature verification uses a new gossip message kind=6 (`signed_push`), not a modification of the existing kind=2 (`push_message`).

**Why:**
- Changing kind=2 to require signatures would break nodes that don't understand the new format
- Adding kind=6 means old nodes see an unknown kind, which they silently drop — no disruption
- New nodes send kind=6 and verify on receive; they also fall back to kind=2 if kind=6 fails

**Rejected:** Modifying kind=2 in-place (breaks backward compat, requires cluster-wide flag day).
**Rejected:** In-band version negotiation (too complex for a gossip-layer change).

---

## 7. Two-Mutex Design for SegmentStore

**Decision:** `SegmentStore` has two separate mutexes: `mu` (read/write operations) and `compact_mu` (compaction).

**Why:**
- Compaction is slow (reads all live entries, writes new segment, syncs WAL). Holding `mu` for the duration would block all reads.
- With two mutexes, compaction snapshots the index under `mu` (fast), then releases `mu` and does the heavy I/O under `compact_mu` only.
- Concurrent reads and writes proceed normally during compaction.

**Trade-off:** A write that arrives during compaction goes to the old segment and WAL. The next compaction picks it up. Slight write amplification, but correctness is maintained.

---

## 8. Stake Account Binary Layout (Fixed Offsets, Not Zig Struct)

**Decision:** `StakeState` is serialized/deserialized by writing to fixed byte offsets, not using `@bitCast` or a packed struct.

**Why:**
- Zig struct layout is not guaranteed to match Agave's bincode encoding
- Agave uses bincode: fixed-size fields at fixed offsets with little-endian integers
- Writing to `data[0..4]`, `data[4..36]`, etc. is explicit, readable, and matches the wire format exactly
- The 172-byte layout is documented field-by-field and enforced by `core/invariants.zig`

**Rejected:** Zig packed struct (padding rules differ from bincode).
**Rejected:** External bincode library (pulls in a dependency; the layout is simple enough to do manually).

---

## 9. ArrayList as Unmanaged (Zig 0.15.2)

**Decision:** In Zig 0.15.2, `std.ArrayList(T)` is now unmanaged — the allocator is not stored in the list. All methods take an explicit `allocator` argument.

**Impact on sol.zig:**
- Replaced `std.ArrayList(Segment).init(allocator)` with `.empty`
- Updated all `append(x)` calls to `append(allocator, x)`
- Updated `deinit()` to `deinit(allocator)`

**Why Zig made this change:** Removing the stored allocator makes `ArrayList` a value type that can be freely copied without aliasing concerns. The allocator is always available at the call site.

---

## 10. OTLP as Non-Fatal Background Export

**Decision:** OTLP HTTP export errors are silently swallowed (`flushInner() catch {}`). The validator never crashes or slows due to a missing observability collector.

**Why:**
- Production validators must be robust. An observability sidecar going down should not affect the critical path.
- Developers running without an OTLP collector (the common case) get no error noise.
- The Prometheus `/metrics` endpoint is always available as a fallback — it serves from the same atomic counters, with no external dependency.

**Rejected:** Panic on export failure (unacceptable in production).
**Rejected:** Buffering and retry (adds complexity; metrics are best-effort by nature).
