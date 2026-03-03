# sol.zig Documentation

| Document | Contents |
|----------|----------|
| [SYSTEM_DESIGN.md](SYSTEM_DESIGN.md) | Module map, data flow diagrams, key structs, crypto stack, concurrency model, build targets |
| [WHAT_WE_BUILT.md](WHAT_WE_BUILT.md) | Phase-by-phase record of every feature built, bugs fixed, and tests added |
| [GAP_ANALYSIS.md](GAP_ANALYSIS.md) | Status of every subsystem vs. mainnet requirements ([done] complete · [partial] partial · [missing] missing) |
| [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) | Key architectural decisions: what was chosen, why, and what was rejected |
| [ROADMAP.md](ROADMAP.md) | Milestones M1–M9, progress bars, next steps to devnet boot |

---

## One-Line Summary

sol.zig is a complete Solana validator in ~19k lines of pure Zig with zero C dependencies — the only production validator where every byte from crypto (X25519, ChaCha20-Poly1305, Ed25519) to persistence (WAL + segment store) is written in Zig.
