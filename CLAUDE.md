<!-- TODO: NOT FINAL NEEDS UPDATE -->
# world-contracts

Sui Move contracts for EVE Frontier, built on the modular **Entity / Module / Action /
Request / Requirement** architecture.

## Where things live

- **`contracts/core/`** — the live v1 architecture. Start here.
- **`contracts/archive/`** — the deprecated `world::` assembly model. Reference only; do **not**
  copy its patterns (`StorageUnit`, `assemblies/`, `primitives/`, `GovernorCap`/`AdminACL`/`OwnerCap`).
- **`tools/error-decoder/`** — TypeScript tool for decoding Move abort codes.
- **`scripts/`** — bash deploy/test helpers.
- **`docker/`** — containerized deploy and localnet snapshot stack (see [`docker/README.md`](docker/README.md)).

## Read before working

- [`docs/move-conventions.md`](docs/move-conventions.md) — **authoritative** coding conventions.
  Read before writing or reviewing any `.move`.
- [`docs/adr/0002-modular-architecture.md`](docs/adr/0002-modular-architecture.md) — the design
  and its rationale.

