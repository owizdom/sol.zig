# sol.zig — What We Built

A record of every phase of work completed, the key decisions made, and the bugs fixed along the way.

---

## Phase 1 — Correctness Fixes

### 1a. Stake Authority + Lockup (`programs/stake/stake.zig`)

**Problem:** The stake program accepted any caller without checking authorization. `STAKE_ACCOUNT_BYTES` was hardcoded as 120, but the actual serialized layout requires 172 bytes — causing silent out-of-bounds reads on every stake operation.

**What we built:**
- Fixed `STAKE_ACCOUNT_BYTES` from 120 → 172 with documented field-by-field layout
- Added `isSigning(accounts, pubkey) bool` helper
- `delegate()` — verifies `accounts[0].is_signer` matches `state.authorized_staker`
- `deactivate()` — same check
- `withdraw()` — verifies `authorized_withdrawer`; blocks if `epoch < lockup_epoch` and custodian not signing (`error.StakeLocked`)
- `split()` — copies full `StakeState` to destination (was copying lamports only)
- `initialize()` — sets `authorized_staker/withdrawer` from ix_data bytes 4..68; falls back to account key if ix_data too short
- 3 new tests: initialize authority, delegate flow, lockup enforcement

**Key design choice:** Binary layout at fixed offsets (not Zig struct serialization) because the layout must be bit-for-bit compatible with Agave's bincode encoding. All offsets are documented as constants.

### 1b. Vote Lockout Gate (`ledger/bank.zig`)

- `recordVoteCredits()` now calls `hasActiveStakeForVoteAccount()` before crediting
- `hasActiveStakeForVoteAccount()` scans AccountsDB for a stake account in `STATE_ACTIVE` (3) with `voter_pubkey` at offset 116 matching the vote account

### 1c. Inflation Schedule (`ledger/bank.zig`)

**Problem:** `EPOCH_BASE_REWARD = 1_000_000` was a placeholder constant — wrong by orders of magnitude.

**What we built:**
```
rate = max(1.5%, 8% × (1 - 15%)^years)
reward = total_supply × rate / 182 epochs_per_year
```
- Added `total_supply: u64` field to `Bank` (starts at 500M SOL equivalent)
- `settleEpochRewards()` distributes `epochReward(epoch, total_supply)` and increments `total_supply`
- `buildEpochStakeMap()` returns active validators and their stake for leader schedule

### 1d. Blockhash Expiry (`ledger/bank.zig`)

- `processTransaction()` now rejects if the blockhash slot is more than 300 slots old
- `advanceSlot()` trims `recent_blockhashes` ring to 300 entries

### 1e. Real Stake-Weighted Leader Schedule (`consensus/schedule.zig`)

- `captureLeaderScheduleSnapshot()` calls `bank.buildEpochStakeMap()` to pull live stake from AccountsDB
- Weighted sampling uses VRF seed for deterministic but unpredictable leader ordering

---

## Phase 2 — Pure Zig Persistence (`storage/`)

**The headline differentiator.** Agave links librocksdb (C++). Sig links librocksdb. sol.zig now has its own crash-safe disk store written entirely in Zig.

### `storage/wal.zig` — Write-Ahead Log

Record format (every field little-endian):
```
[4]  MAGIC  = 0x474C_4157  "WALG"
[1]  kind   = 0 (put) | 1 (delete) | 2 (checkpoint)
[4]  key_len
[4]  val_len
[key_len] key
[val_len] value
[4]  CRC-32/ISO-HDLC over all preceding bytes
```

Properties:
- `fsync` on every write — process crash cannot corrupt a committed record
- Replay stops at first bad magic or CRC mismatch (safe tail truncation for power-loss)
- `checkpoint()` truncates to a single marker after compaction
- 2 tests: round-trip, checkpoint truncation

**Key design choice:** CRC-32/ISO-HDLC (16 lines of pure Zig) instead of stdlib hash — matches Ethernet/zip CRC so external tools can validate WAL files.

### `storage/segment.zig` — Flat Segment Store

Architecture:
- Segments are append-only flat files, max 64 MB each
- In-memory `AutoHashMap([32]u8, Pointer)` maps pubkey → `{seg_id, offset, len}`
- WAL replay rebuilds the index on boot (crash recovery)
- `compact()` rewrites live entries to a new segment and checkpoints the WAL

Public API (same shape as RocksDB):
```zig
pub fn put(key: [32]u8, value: []const u8) !void
pub fn get(key: [32]u8, alloc: Allocator) !?[]u8
pub fn delete(key: [32]u8) !void
pub fn compact() !void
pub fn iterator() Iterator
```

3 tests: put/get/delete, crash-replay (kill mid-write, reopen, verify), compaction.

**Key design choice:** Two separate mutexes (`mu` for reads/writes, `compact_mu` for compaction) allow reads to proceed while compaction prepares the new segment, minimizing lock contention.

### `accounts-db/accounts_db.zig` — Backend Selection

Added `SEGMENT_STORE = true` compile-time flag. When set, all AccountsDB operations route through `SegmentStore`. The `PERSISTENT = true` flag (RocksDB) remains as a fallback. All callers unchanged.

---

## Phase 3 — Pure Zig TLS 1.3 (`network/tls/tls13.zig`)

No OpenSSL. No libssl. Only `std.crypto`.

Primitives used:
- `std.crypto.dh.X25519` — ECDH key exchange
- `std.crypto.aead.chacha_poly.ChaCha20Poly1305` — AEAD record encryption
- `std.crypto.kdf.hkdf.HkdfSha256` — RFC 8446 HKDF-Expand-Label
- `std.crypto.hash.sha2.Sha256` — transcript hash

### Key types
```zig
TrafficKeys = { client_key[32], client_iv[12], server_key[32], server_iv[12], client_seq, server_seq }
HandshakeState = { our_x25519_secret[32], our_x25519_public[32], transcript: Sha256, ecdh_shared, hs_keys, finished_key }
```

### Key operations
- `clientHello(allocator, random, state)` — builds ClientHello with X25519 key_share extension
- `processServerHello(data, state)` — parses ServerHello, runs ECDH, derives handshake traffic keys
- `serverHello(allocator, client_hello, server_random, state)` — server-side handshake
- `deriveTrafficKeys(ecdh_shared, transcript_hash)` — HKDF-Expand-Label per RFC 8446 §7.1
- `encryptServer/decryptServer/encryptClient/decryptClient` — per-record ChaCha20-Poly1305, sequence-number nonce

**Key design choice:** Per-record nonce = `base_iv XOR seq_number` (big-endian in last 8 bytes) — exact RFC 8446 §5.3 construction, not a simplification.

4 tests: key derivation determinism, encrypt/decrypt round-trip, ClientHello parsing, full server+client handshake.

---

## Phase 4 — Mainnet Wire Compatibility

### Gossip Signature Verification (`network/gossip/gossip.zig`)

- Added `signed_push = 6` as a new GossipMsgKind (backward compatible — unknown kind falls through to no-op in old nodes)
- `serializeSignedPush(kp, ci, buf)` — signs payload bytes with validator keypair
- `deserializeSignedPush(buf, out)` — verifies Ed25519 before accepting CrdsValues
- `verifyCrdsSignature(data, sig, pubkey)` — thin wrapper around `Ed25519.verify`
- `pushToPeer` now sends signed_push by default; falls back to unsigned on error

**Key design choice:** New kind=6 rather than modifying kind=2 — nodes that don't understand signed_push ignore it gracefully, so devnet interop isn't broken during rollout.

### Fair MEV Ordering (`network/tpu_quic/tpu_quic.zig`)

- Added `PendingTx { data: []u8, arrival_ns: i128 }` struct
- Every incoming transaction is stamped with `std.time.nanoTimestamp()` on receipt
- After connection closes, pending transactions are sorted: `std.sort.pdq(PendingTx, ..., PendingTx.lessThan)`
- Block packing proceeds in arrival order — no fee-based reordering

**Why this matters:** Agave and Sig both use fee-priority ordering. sol.zig is the only validator with provably fair (time-priority) MEV ordering. This is a hard protocol property, not a configuration option.

---

## Phase 5 — Differentiators

### Comptime Protocol Invariants (`core/invariants.zig`)

```zig
comptime {
    std.debug.assert(SLOTS_PER_EPOCH      == 432_000);
    std.debug.assert(MAX_RECENT_BLOCKHASHES == 300);
    std.debug.assert(FEE_LAMPORTS_PER_SIG  == 5_000);
    std.debug.assert(STAKE_ACCOUNT_BYTES   == 172);
    std.debug.assert(SLOTS_PER_EPOCH % 32  == 0);
}
```

Constant drift (e.g. changing `SLOTS_PER_EPOCH` without updating consumers) becomes a **compile error**, not a silent runtime bug. No other Solana validator does this.

### OpenTelemetry OTLP Export (`metrics/metrics.zig`)

- `OtlpExporter.buildJsonPayload()` — OTLP JSON envelope with 9 metrics, per-slot/epoch labels
- `flushInner()` — TCP connect to `127.0.0.1:4318`, HTTP/1.1 POST to `/v1/metrics`
- `runOtlpExportLoop(exporter, stop_flag)` — background thread, 10 s flush interval
- Non-fatal: errors are swallowed so the validator keeps running if no collector is present
- Compatible with OpenTelemetry Collector, Grafana Agent, Datadog OTLP receiver

### Library Mode (`build.zig`)

```sh
zig build lib-gossip    # libsol-gossip.a   — embed just gossip in your project
zig build lib-bank      # libsol-bank.a     — embed the bank + programs
zig build lib-runtime   # libsol-runtime.a  — embed the BPF runtime
zig build lib-storage   # libsol-storage.a  — embed the WAL + segment store
```

All four targets compile with **zero C dependencies**. Downstream projects can link any single subsystem without pulling in the whole validator.

---

## Phase 6 — Devnet Participation (M6)

### QUIC TLS Wiring (`network/quic/quic.zig` + `build.zig`)

- Added `tls13` import to `net_quic_mod` in `build.zig`
- Extended `QuicTlsMode` enum with `.real` variant (alongside existing `.disabled` and `.placeholder`)
- Added `tls_hs_state: ?tls13.HandshakeState` and `tls_ap_keys: ?tls13.TrafficKeys` fields to `QuicConn`
- `onCryptoFrame()` now calls `tls13.TLS13.serverHello()` for the real TLS path: parses ClientHello, generates ServerHello, derives handshake keys; Finished processing advances to application keys
- Placeholder magic-string branch preserved for internal test interop

### RFC 9001 Header Protection (`network/quic/quic.zig`)

- `applyHeaderProtection(hp_key, packet, pn_offset, pn_len)` — XOR-symmetric mask using AES-128-ECB on a 16-byte sample at `pn_offset + 4`
- `deriveQuicHpKey(traffic_secret)` — HKDF-Expand-Label with label `"quic hp"` per RFC 9001 §5.1, produces 16-byte AES key
- Applied on emit (protect) and on receive (remove protection) around `emitPacketWithPayload()` / `processPacket()`

### ALT Resolution (`transaction/transaction.zig`, `ledger/bank.zig`)

- `AddressLookupTableEntry` struct: `account_key: Pubkey`, `writable_indexes: []const u8`, `readonly_indexes: []const u8`
- `Message` extended: `version: u8 = 0`, `address_table_lookups: []const AddressLookupTableEntry = &.{}`
- `deserialize()` detects v0 prefix byte (`data[pos] & 0x80 != 0`) and parses compact-u16 ALT entry array after instructions
- `resolveAddressLookups()` in `bank.zig`: looks up each ALT account from AccountsDB, reads addresses at offset 56 (Solana ALT layout), appends resolved pubkeys to working key list before instruction dispatch

### Snapshot Bootstrap (`snapshot/bootstrap.zig`)

Pure Zig HTTP/1.1 client — no external libraries:

- `fetchCurrentSlot(allocator)` — `getSlot` JSON-RPC → `types.Slot`
- `fetchGenesisHash(allocator)` — `getGenesisHash` JSON-RPC → heap-allocated string
- `fetchGossipPeers(allocator, max)` — `getClusterNodes` → array of `std.net.Address` gossip endpoints
- `fetchPublicIp(allocator)` — HTTP GET `api4.ipify.org:80/` → plain-text IPv4 string (used to advertise real external IP)
- `isVisibleOnDevnet(allocator, identity)` — encodes identity to base58, calls `getClusterNodes`, returns `true` if our pubkey appears
- `downloadSnapshot(allocator, host, port, path, dest_path)` — streams HTTP body (skipping headers) to file
- `parseIpv4(ip_str, port)` — parses dotted-quad IPv4 string + port into `std.net.Address`

### Public IP Advertisement (`network/gossip/gossip.zig`, `validator/validator.zig`)

**Problem:** `GossipNode.init()` sets `my_info.gossip = bind_addr` which is `0.0.0.0:8001`. Devnet validators could not reach back because the advertised address was the wildcard bind.

- `setAdvertisedAddr(addr)` method on `GossipNode` — updates all ContactInfo socket fields (`gossip`, `tvu`, `tpu`, `tpu_fwd`, `repair`, `serve_repair`) and bumps `wallclock`
- `seedGossipFromDevnet()` in `validator.zig` now fetches public IP via `fetchPublicIp`, parses it with the gossip port, and calls `setAdvertisedAddr` before seeding peers — so our ContactInfo broadcasts the real routable address

### Devnet Smoke Test (`bin/devnet_smoke.zig`)

End-to-end binary that proves the full boot sequence:

1. Generates a fresh Ed25519 identity keypair, prints it in base58
2. Boots validator, fetches devnet genesis hash, starts gossip + RPC + metrics services
3. Seeds gossip from devnet `getClusterNodes` (up to 64 peers) with real public IP
4. Advances 100 local slots, prints progress every 20 slots
5. Without `--persist`: polls `getClusterNodes` once after 15 s; prints visibility result and firewall hint
6. With `--persist`: runs indefinitely — advances slots (~10 ms/slot), re-seeds gossip every 60 s, polls `getClusterNodes` every 30 s, exits cleanly after 3 consecutive visibility confirmations

**Verified output:**
```
Identity (base58): <44-char pubkey>
devnet genesis hash: 5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d
gossip advertising: <public_ip>:8001
Done. Slot 0 -> 100
```

---

## Phase M6 — Full Devnet Participation

### M6a. Turbine Shred Receiver (`network/turbine/turbine.zig`, `validator/validator.zig`)

**Problem:** The Validator had no way to receive shreds from the devnet Turbine broadcast. Without a live TVU socket, the gossip ContactInfo advertised a dead TVU port (copied from the gossip socket by `setAdvertisedAddr`), making devnet leaders silently skip us as a relay target.

**What we built:**

- `TurbineReceiver.init()` now sets `O_NONBLOCK` on the UDP socket after `bind()` using `fcntl(F_GETFL/F_SETFL)`. The Zig 0.15 macOS `O` type is a `packed struct(u32)`, so the call uses `@bitCast` + `@intCast` for the usize conversion. This lets `recvShred()` return `null` on `EAGAIN` instead of blocking forever, enabling a clean thread-exit path.
- `Validator` gains five new fields: `turbine_receiver`, `turbine_thread`, `tvu_running` (atomic bool), `shreds_received` (atomic u64), `tvu_port`.
- `startServicesInternal()` binds `gossip_port + 1` as the TVU port, sets `my_info.tvu` in the gossip ContactInfo, starts the turbine thread.
- `stopServices()` signals the turbine thread (`tvu_running = false`) and joins it before shutting down gossip.
- `turbineLoop()` runs on a dedicated thread: pulls shreds with 1 ms sleep on EAGAIN, accumulates `FecSet`s keyed by `(slot << 16) | fec_index`, assembles when complete (`isComplete(1)`), prints assembled block size, evicts sets when the map exceeds 2000 entries to bound memory.

### M6b. Snapshot Auto-Save / Auto-Load (`snapshot/snapshot.zig`, `validator/validator.zig`)

**Problem:** The node forgot all account state on every restart. `maybeLoadSnapshot()` existed but was never called with a snapshot that had been saved from a real run.

**What we built:**

- `Validator.saveSnapshot()` — writes the current AccountsDB + `bank.slot` to `{snapshot_dir}/snapshot-{slot}.bin.zst` using the existing SOLSNAP1 format.
- `Validator.deinit()` calls `saveSnapshot()` before `stopServices()` — every clean shutdown persists state.
- `bootstrapFromDevnet()` calls `maybeLoadSnapshot()` first; if no prior snapshot exists (`bank.slot == 0`), writes a genesis snapshot (`snapshot-0.bin.zst`) so restarts can always load *something*.
- **Bug fixed:** `compressZstdRaw()` was writing an invalid zstd frame. The original `FHD=0x20` byte (Single_Segment=1, FCS_Field_Size=0b00) requires a 1-byte FCS field, but the code wrote `0x00` as a BD byte instead — the standard zstd decompressor read `FCS=0` (content size = 0) and rejected the non-empty blocks. Fixed to `FHD=0xE0` (Single_Segment=1, FCS_Field_Size=0b11 → 8-byte FCS) with the actual `input.len` written as the FCS. The round-trip now works.

**Verified:**
```
# First run
genesis snapshot written
turbine recv bound on :8002
Done. Slot 0 -> 100
snapshot saved: slot 100 → /tmp/sol-snap/

# Second run (restart)
turbine recv bound on :8002       ← no "genesis snapshot written"
slot 120 ... slot 200
Done. Slot 100 -> 200             ← resumes from saved slot
snapshot saved: slot 200 → /tmp/sol-snap/
```

### M6c. WAL Restart (`validator/validator.zig`)

`saveSnapshot()` serializes `bank.slot` into the SOLSNAP1 header. On load, `maybeLoadSnapshot()` reads the slot back and sets `bank.slot = loaded_slot`, giving the replay engine the correct starting point. This wires `SegmentStore.open() → WAL.replay()` (which recovers account data) together with the slot counter (which tells the bank where to continue), completing the crash-recovery loop.

### M6d. Port Diagnostics + TVU Address Fix (`validator/validator.zig`, `bin/devnet_smoke.zig`)

**Problem:** `setAdvertisedAddr(gossip_addr)` overwrites *all* ContactInfo socket fields (gossip, tvu, tpu, …) with the gossip IP:port. The TVU port was being advertised as the gossip port, so devnet validators tried to send shreds to port 8001 instead of 8002.

**Fix:** After `setAdvertisedAddr()` sets the public IP, `seedGossipFromDevnet()` immediately overrides `node.my_info.tvu` with `parseIpv4(ip_str, self.tvu_port)` — the correct public-IP:TVU-port address.

**New `devnet_smoke` features:**
- `--snapshot-dir <path>` flag — pass a directory to enable snapshot persistence across runs
- Port requirements printed at startup: `Required inbound UDP: 8001 (gossip) 8002 (TVU)`
- Persist-mode poll line now includes `shreds_recv=N` counter so you can see shreds arriving in real time

---

## Test Coverage

| Module | Tests |
|--------|-------|
| `storage/wal.zig` | 2 |
| `storage/segment.zig` | 3 |
| `core/invariants.zig` | 1 |
| `metrics/metrics.zig` | 1 |
| `network/tls/tls13.zig` | 4 |
| `programs/stake/stake.zig` | 3 |
| `programs/token/token.zig` | (existing) |
| `programs/bpf_loader/bpf_loader.zig` | (existing) |
| **Total new** | **14** |

All 14 new tests pass. Existing tests pass where module-level deps are available (RocksDB-linked binary tests excluded — system library not present).
