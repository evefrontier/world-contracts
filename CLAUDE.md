# world-contracts

Sui Move contracts for EVE Frontier, built on the modular **Entity / Module / Action /
Request / Requirement** architecture.

## Where things live

- **`contracts/core/`** — the live v1 architecture. Start here.
- **`contracts/character/`** — scaffolded package, not yet implemented (empty module stub).
- **`contracts/archive/`** — the deprecated `world::` assembly model. Reference only; do **not**
  copy its patterns (`StorageUnit`, `assemblies/`, `primitives/`, `GovernorCap`/`AdminACL`/`OwnerCap`).
- **`tools/error-decoder/`** — TypeScript tool for decoding Move abort codes.
- **`scripts/`** — bash deploy/test helpers.
- **`docker/`** — containerized deploy and localnet snapshot stack (see [`docker/README.md`](docker/README.md)).

## Read before working

- [`CONTEXT.md`](CONTEXT.md) — domain glossary: every concept → its file → its key invariant.
- [`docs/move-conventions.md`](docs/move-conventions.md) — **authoritative** coding conventions.
  Read before writing or reviewing any `.move`.
- [`docs/adr/0002-modular-architecture.md`](docs/adr/0002-modular-architecture.md) — the design
  and its rationale.

## Build, test, lint

Run from the repo root (deps are pinned per environment, so `--build-env` is required):

```bash
npm run build   # sui move build --build-env testnet, per package (excludes archive)
npm run test    # sui move test  --build-env testnet
npm run lint    # build with --lint
npm run fmt     # prettier + @mysten/prettier-plugin-move
```

To build one package directly: `sui move build --build-env testnet --path contracts/core`.

## External references

For library/API specifics, fetch current docs (e.g. Context7) rather than relying on memory.

- Sui docs: https://docs.sui.io · Sui Move concepts: https://docs.sui.io/concepts/sui-move-concepts
- Sui framework reference: https://docs.sui.io/references/framework
- The Move Book: https://move-book.com · reference: https://move-book.com/reference
- Sui TypeScript SDK: https://sdk.mystenlabs.com/typescript · dApp Kit: https://sdk.mystenlabs.com/dapp-kit
