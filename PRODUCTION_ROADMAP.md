# Productionization Roadmap (solana-in-Zig)

Goal: reach Agave-level parity where possible, with a **no C/FFI** hard constraint.

## Milestone 0 — Safety Baseline (current)

- [x] Fix deterministic shutdown race in QUIC pump thread (`network/quic/quic.zig`).
  - `recvfrom` was executed after socket close and could panic on `BADF`.
  - Pump thread now joins before socket close and uses nonblocking UDP.
- [x] Fix deterministic shutdown race in RPC acceptor (`rpc/rpc.zig`).
  - RPC listener now uses nonblocking TCP.
  - Stop now signals workers without closing listener immediately.
  - Shutdown path now closes socket from deinit after control paths can drain.
- [ ] Add shutdown stress test that repeatedly starts/stops `replay-harness` and asserts no panic.

## Milestone 1 — Durable state

- Replace in-memory AccountsDB backend with a durable Zig-native store (pure Zig backend first).
- Add checkpoint/compaction equivalents in the pure Zig store design.
- Add fault-injection tests for crash-safe startup and replay.
- Snapshot write/read should survive process restart with version checks and hash validation.
- Persist validator metadata (highest root, slot, blockhash sequence numbers).

## Milestone 2 — Transport and cluster wiring

- Real QUIC implementation in pure Zig for TPU and repair paths.
- Reliable gossip + repair:
  - Shred request/response wire format
  - Missing-shred tracking and retransmit
  - Peer scoring and retransmit budgets
- WebSocket:
  - push loop for account/slot/log subscriptions
  - reconnect-safe subscription lifecycle
- TPU and RPC port allocation that retries on `EADDRINUSE` in test/dev mode.

## Milestone 3 — Consensus/economics correctness

- Epoch stake accounts snapshots and leader schedule from stake weights.
- Vote credit accounting and vote state rollback safety.
- Inflation + rewards + epoch boundary updates.
- Stake activation/deactivation + vote program integration.

## Milestone 4 — Runtime/system program parity

- SPL Token program (complete feature set) in pure Zig.
- BPF syscall expansion (sysvar access, hashing, invocations, CPI checks).
- Versioned transaction decoding + address lookup table support.
- Deterministic feature-gate registry and feature bit parity for execution paths.

## Milestone 5 — Bootstrap and operations

- Snapshot distribution client for downloading and bootstrapping from peer.
- Enhanced observability:
  - panic-safe process metrics, queue depth, latency histograms
  - startup readiness and health probes
- Security hardening:
  - rate limiting, malformed packet budgets, DoS guardrails

## Milestone 6 — Validation

- Deterministic integration matrix:
  1. Unit tests unchanged and expanded.
  2. Replay harness against local fixture clusters.
  3. Golden corpus for RPC + transport protocol behavior.
  4. Fuzz tests for parsers and transaction decoding.
  5. End-to-end smoke on startup/restart/panic recovery cycles.
