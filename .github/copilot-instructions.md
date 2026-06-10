# Copilot Instructions — world-contracts

Sui Move contracts for EVE Frontier, built on the modular **Entity / Module / Action /
Request / Requirement** architecture.

Path-scoped Move guidance is applied automatically:

- `.github/instructions/sui-move.instructions.md` → `**/*.move`
- `.github/instructions/sui-move-tests.instructions.md` → `**/tests/*.move`

Both point at the single source of truth, which you should read before working:

- [`docs/move-conventions.md`](../docs/move-conventions.md) — **authoritative** coding & testing
  conventions.
- [`CONTEXT.md`](../CONTEXT.md) — domain glossary (concept → file → invariant).
- [`docs/adr/0002-modular-architecture.md`](../docs/adr/0002-modular-architecture.md) — design
  and rationale.

## Where things live

- **`contracts/core/`** — the live v1 architecture. Start here.
- **`contracts/archive/`** — deprecated `world::` assembly model
  ([ADR 0001](../docs/adr/0001-assembly-architecture.md)). Reference only; do not copy its
  patterns.

## Review process

1. Read the change and what it accomplishes.
2. Check it against `docs/move-conventions.md` (layout, errors, getters, versioning).
3. Verify authorization is type-driven (`Permit<T>`), not argument-driven.
4. Confirm tests cover success and failure paths.
5. Check object model and BCS encode/decode symmetry.

Do not flag what tooling handles (`sui move fmt`, compiler warnings) — focus on logic,
architecture, authorization, and the documented invariants.
