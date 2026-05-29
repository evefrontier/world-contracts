# ADR-001: world_4 Repository & Package Strategy

**Status:** Proposed  
**Date:** 2026-05-29  
**Deciders:** EVE Frontier contracts team  

---

## Context

`world-contracts` today is a single Sui Move package (`contracts/world`) with sibling packages (`assets`, `extension_examples`) and a flat collection of `ts-scripts` run via `tsx`. The design is assembly-first: each structure type owns its object layout and exposes a fixed API.

`world_4` introduces a modular architecture — `Entity`, `Module<T>`, `Action`, `Request`, `Requirement` — where the core is a standalone package and each game module (inventory, transport, fuel, weapons, …) is its own package. This changes the publishing unit: we now need to publish multiple independent Move packages to MVR and expose TypeScript PTB tooling to consumers as proper npm packages.

The team is choosing between three migration paths for the existing repo.

---

## Options Considered

### Option 1 — New repository

Create a fresh `world-contracts-v2` (or `world4-contracts`) repo. Start CI/CD, Docker images, scripts, and package config from scratch.

| Dimension | Assessment |
|-----------|------------|
| Cleanliness | High — no legacy code polluting the tree |
| Git history | Lost — cross-referencing old behavior requires switching repos |
| CI/CD cost | Medium — rebuild pipelines, but gets to do it right |
| Coordination | High friction — PRs, issues, and wiki links split across two repos |
| Team familiarity | Low — re-onboarding overhead |

**Pros:** Zero historical baggage; clean dependency graph from day one; no risk of accidentally running old scripts.  
**Cons:** Loses blame/history; two repos to maintain until the old one is archived; external contributors (and your own docs) reference the old repo; CI secrets and GitHub Pages need re-setup.

---

### Option 2 — New `dev` branch, rewrite everything

Create a long-lived `dev` branch off `main`. Do the full restructure there. Merge back to `main` (or rename it) when the team is ready to ship.

| Dimension | Assessment |
|-----------|------------|
| Cleanliness | High — branch is self-contained |
| Git history | Preserved — full blame is available via branch comparison |
| CI/CD cost | Low — target branch in existing pipelines with a path filter |
| Coordination | Low — single repo, single issue tracker, same clone URL |
| Team familiarity | High — standard Git workflow |

**Pros:** Industry-standard for large rewrites; preserves full history; existing CI secrets and integrations stay; easy to cherry-pick fixes from `main` → `dev`; merge or squash to `main` when ready.  
**Cons:** Long-lived branches diverge; needs discipline to keep `dev` rebased or merged from `main` during the transition period.

---

### Option 3 — `v1` folders on `main`

Keep everything on `main`. Rename existing packages to `world_v1`, `docker_v1`, etc., add new packages alongside, archive old folders later.

| Dimension | Assessment |
|-----------|------------|
| Cleanliness | Low — `main` is cluttered during transition |
| Git history | Preserved |
| CI/CD cost | High — scripts and pipelines must distinguish v1 from v4 |
| Coordination | Medium — no branch switching, but folder names create confusion |
| Team familiarity | Low — non-standard; reviewers must know which folder is "current" |

**Pros:** No branching overhead; single source of truth for both versions simultaneously.  
**Cons:** Cluttered root; CI must be taught to ignore v1 folders; easy to accidentally build or deploy from the wrong folder; naming conventions (`world_v1`, `scripts_v1`) do not follow any established convention and become permanent debt.

---

## Decision

**Use Option 2: a `dev` branch with a full monorepo restructure.**

The branch is eventually merged (or promoted) to `main` once the new architecture is stable. During transition, `main` ships the current production build; `dev` ships the world_4 build to testnet.

This is also how Mysten Labs manages the Sui repo itself: feature work lands on `main` via feature branches; large cross-cutting changes (e.g., new framework modules) live on a long-lived branch until they are ready, then merge via a single PR that is easy to review and revert.

---

## Monorepo Layout (world_4)

The repo root stays `world-contracts`. The internal structure is reorganized as a proper monorepo:

```
world-contracts/
├── packages/
│   ├── core/                  # Move: Entity, Module<T>, Action, Request, Requirement
│   │   ├── sources/
│   │   └── Move.toml
│   ├── inventory/             # Move: Inventory module + deposit/withdraw handlers
│   │   ├── sources/
│   │   └── Move.toml          # depends on core
│   ├── transport/
│   ├── fuel/
│   ├── admin-acl/
│   └── extension-examples/    # Move: reference implementations
│
├── sdk/
│   ├── core-sdk/              # TS: PTB builders + type bindings for core
│   │   ├── src/
│   │   ├── package.json       # name: "@eve-frontier/core-sdk"
│   │   └── tsconfig.json
│   ├── inventory-sdk/         # TS: PTB builders for inventory module
│   └── deploy-cli/            # TS: CLI for publishing packages to MVR
│       ├── src/
│       └── package.json       # name: "@eve-frontier/deploy-cli", bin entry
│
├── scripts/                   # Shell: deploy/configure orchestration
├── docker/
├── deployments/               # Published.toml outputs per environment
├── docs/
├── pnpm-workspace.yaml        # Declares sdk/* as pnpm workspaces
└── package.json               # Root: build/test/fmt orchestration
```

**Why separate `packages/` and `sdk/`?** Move packages and TS packages have different lifecycles and publish to different registries (MVR vs npm). Keeping them in separate top-level directories makes it unambiguous which toolchain applies.

---

## Move Package Publishing to MVR

Reference: [Mysten Labs Sui repo](https://github.com/mystenlabs/sui/) publishes individual framework packages (`sui-framework`, `move-stdlib`, `deepbook`, etc.) as independent MVR entries. Each has its own `Move.toml` with a stable address and its own publish script.

### Move.toml convention

```toml
# packages/core/Move.toml
[package]
name = "world_core"
edition = "2024"
version = "0.4.0"

[dependencies]
Sui = { git = "...", rev = "..." }

[addresses]
world_core = "0x0"            # replaced by MVR after first publish

[environments]
testnet = "4c78adac"
mainnet = "35834a8a"
```

Downstream packages reference `core` by its MVR name after it is published:

```toml
# packages/inventory/Move.toml
[dependencies]
world_core = { r.mvr = "@frontier/world-core" }
```

During local development, use `local =` overrides in a root-level `Move-dev.toml` (or `[patch]` entries) so engineers do not need a live MVR lookup for every build.

### Publish script (`sdk/deploy-cli`)

The deploy CLI wraps `sui client publish` and `mvr publish` behind typed commands:

```
pnpm deploy:move --package packages/core --env testnet
pnpm deploy:move --package packages/inventory --env testnet
pnpm mvr:register --package packages/core --name "@frontier/world-core"
```

Internally it:
1. Reads `Move.toml` for the package name and environment.
2. Calls `sui client publish` and captures the resulting package ID.
3. Writes the ID to `deployments/<env>/<package>.json`.
4. Optionally calls `mvr publish` to register the new version.

This replaces the current ad-hoc shell scripts with a single, typed, testable CLI entry point.

---

## TypeScript PTB SDK — Structure and npm Publishing

Each `sdk/*` package is a standard TypeScript ESM package published to npm under the `@eve-frontier` scope.

### Package structure (`sdk/core-sdk`)

```
sdk/core-sdk/
├── src/
│   ├── index.ts              # re-exports public API
│   ├── ptb/
│   │   ├── interact.ts       # build a PTB for entity.interact()
│   │   ├── complete.ts
│   │   └── install.ts
│   ├── types.ts              # generated or hand-authored BCS types
│   └── client.ts             # thin wrapper around @mysten/sui SuiClient
├── package.json
└── tsconfig.json
```

`package.json`:

```json
{
  "name": "@eve-frontier/core-sdk",
  "version": "0.4.0",
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.js",
      "types": "./dist/index.d.ts"
    }
  },
  "scripts": {
    "build": "tsc",
    "test": "vitest run"
  },
  "peerDependencies": {
    "@mysten/sui": ">=2.0.0"
  }
}
```

### PTB builder pattern

Each handler exposes a typed builder function that a consumer composes into a `Transaction`:

```ts
// sdk/inventory-sdk/src/ptb/deposit.ts
import { Transaction } from "@mysten/sui/transactions";
import type { Requirement } from "@eve-frontier/core-sdk";

export function addDepositCommand(
  tx: Transaction,
  args: {
    entity: string;       // object ID
    request: TransactionArgument;
    item: TransactionArgument;
    packageId: string;    // resolved from deployments/<env>/inventory.json
  }
): TransactionArgument {
  return tx.moveCall({
    target: `${args.packageId}::inventory::deposit`,
    arguments: [
      tx.object(args.entity),
      args.request,
      args.item,
    ],
  });
}
```

This is exactly the `deposit_template` pattern described in `architecture-v1.md`, implemented in TypeScript. Consumers build full PTBs by composing these functions — no raw string targets, full type-checking.

### npm publish workflow

```yaml
# .github/workflows/publish-sdk.yml
on:
  push:
    tags: ["sdk-v*"]
    paths: ["sdk/**"]
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: pnpm/action-setup@v4
      - run: pnpm install --frozen-lockfile
      - run: pnpm -r --filter "./sdk/**" build
      - run: pnpm -r --filter "./sdk/**" publish --access public
        env:
          NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}
```

Versioning: each SDK package versions independently. `core-sdk` follows the `core` Move package version. Module SDKs are versioned against their Move counterparts.

---

## CI/CD Strategy

| Trigger | Job |
|---------|-----|
| PR to `dev` | `sui move build` + `sui move test` for changed packages only (path filter) |
| PR to `dev` | TS typecheck + lint across `sdk/**` |
| Push to `dev` | Deploy changed Move packages to testnet (internal) |
| Push to `dev` | Deploy changed Move packages to testnet (utopia/stillness) |
| Tag `sdk-v*` on `dev` or `main` | Publish changed SDK packages to npm |
| Push to `main` | Full build + test; deploy to mainnet (manual approval gate) |

Use pnpm's `--filter` with `--since` to build only packages that changed in a given commit range — the same technique Mysten Labs uses in their Turborepo-adjacent CI setup.

---

## Trade-off Analysis

The core trade-off in Option 2 vs Option 1 is **history vs. cleanliness**. For a contract repo where understanding *why* a design decision was made is critical (especially for audits and incident response), history wins. The `dev` branch gives you both: a clean tree going forward and a reachable history going back.

The core trade-off in the package layout is **granularity vs. publish overhead**. Publishing 6 Move packages instead of 1 means 6 MVR entries, 6 package IDs to track per environment, and 6 upgrade-cap objects to manage. The deploy CLI absorbs most of this overhead. The benefit — each module can be upgraded independently without touching core or other modules — is worth it for a protocol that is designed to evolve continuously.

---

## Consequences

**Easier:**
- Upgrading `inventory` without touching `core` or `transport`.
- External teams writing extensions that depend only on `core` via MVR, without copying source.
- Clients consuming `@eve-frontier/inventory-sdk` as a typed library instead of copying PTB snippets from internal docs.
- CI catching per-package breakage rather than treating the repo as one unit.

**Harder:**
- Managing 6+ package IDs per environment (mitigated by `deployments/<env>/*.json` and the deploy CLI).
- Local development requires either live MVR resolution or `[patch]` overrides in `Move.toml`.
- npm publish needs a scoped org and token setup.
- Long-lived `dev` branch needs a merge discipline (rebase from `main` on a schedule, or use merge commits with a clear policy).

**To revisit:**
- Whether `extension-examples` lives in this repo or in a separate consumer-facing repo.
- Governance model for MVR package ownership as more teams write extensions.
- Whether to use Turborepo or Nx for incremental TS builds once `sdk/` grows beyond 3-4 packages.

---

## Action Items

1. [ ] Create `dev` branch from current `main`
2. [ ] Scaffold `packages/` directory with `core/` and `inventory/` Move packages extracted from existing `contracts/world/sources/`
3. [ ] Write `Move.toml` for each package with correct `[environments]` entries
4. [ ] Create `pnpm-workspace.yaml` declaring `sdk/*` as workspaces
5. [ ] Scaffold `sdk/core-sdk` and `sdk/deploy-cli` with `package.json` and tsconfig
6. [ ] Port existing `ts-scripts` into `sdk/core-sdk/src/ptb/` as typed PTB builder functions
7. [ ] Write `sdk/deploy-cli/src/` wrapping `sui client publish` + MVR registration
8. [ ] Update CI: add `dev`-branch jobs for Move test, TS typecheck, and testnet deploy
9. [ ] Add `publish-sdk.yml` workflow with `NODE_AUTH_TOKEN` secret
10. [ ] Update `docs/` with the new directory layout and local dev setup instructions
11. [ ] Archive old `ts-scripts/` with a deprecation notice pointing to `sdk/`
