---
description: "Guidelines for building Sui Move contracts (modular Entity/Module/Action/Request/Requirement architecture)"
applyTo: "**/*.move"
---

# Sui Move Code Guidelines

**The authoritative conventions live in [`docs/move-conventions.md`](../../docs/move-conventions.md).**
Read it before writing or reviewing `.move` code. For the domain vocabulary see
[`CONTEXT.md`](../../CONTEXT.md); for the design rationale see
[`docs/adr/0002-modular-architecture.md`](../../docs/adr/0002-modular-architecture.md).

Non-negotiables (full detail in the doc above):

- Live code is `contracts/core/`; `contracts/archive/` is the deprecated `world::` assembly
  model (`StorageUnit`, `assemblies/`, `primitives/`, `GovernorCap`/`AdminACL`/`OwnerCap`) — do
  not copy its patterns.
- Every `assert!` uses a named `E` + PascalCase `u64` error constant; no bare `abort`.
- `// === Section ===` headers in the canonical order; objects-first, capabilities-second,
  `ctx`/`&Clock` last in signatures.
- Every non-exempt struct field has a getter named after it (no `get_` prefix).
- Authorization is type-driven via `internal::Permit<T>` — never gated on a string/id argument;
  the target module name is read off the requirement, never from handler arguments.
- Every persisted struct carries `version` and asserts `version == VERSION` on entry.
- `Request`/`Frame` are abilities-free hot potatoes minted/consumed only by `core::entity`.
- BCS requirement decode mirrors the encode field order exactly.

Do **not** flag what tooling handles (`sui move fmt`, compiler warnings); focus on logic,
architecture, authorization, and invariants.
