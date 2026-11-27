# Copilot Instructions — world-contracts

Sui Move contracts for EVE Frontier, built on the modular **Entity / Component / Action /
Request / Requirement** architecture.

Path-scoped Move guidance is applied automatically and carries the rule details — this file is
just the repo overview:

- `.github/instructions/sui-move.instructions.md` → `**/*.move`
- `.github/instructions/sui-move-tests.instructions.md` → `**/tests/*.move`

Read the single source of truth before working:

- [`docs/move-conventions.md`](../docs/move-conventions.md) — **authoritative** coding & testing
  conventions, including the review checklist.
- [`CONTEXT.md`](../CONTEXT.md) — domain glossary (concept → file → invariant).
- [`docs/adr/0002-modular-architecture.md`](../docs/adr/0002-modular-architecture.md) — design
  and rationale.

## Where things live

- **`contracts/core/`** — the live v1 architecture. Start here.

When reviewing, work from the checklist in `docs/move-conventions.md` rather than re-deriving
rules here. Don't flag what `sui move fmt` and the compiler already handle.
