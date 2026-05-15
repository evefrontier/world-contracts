# ADR 0001: Refinery and Recipe Modules

**Status:** Draft
**Author:** community contributor (artokun)
**Date:** 2026-05-15
**Related:** Issue [#74 — \[Feat\] Mining System](https://github.com/evefrontier/world-contracts/issues/74)

## Context

EVE Frontier currently exposes three programmable Smart Assemblies on-chain:
`storage_unit`, `gate`, and `turret`. Refineries exist as in-game structures but
have no corresponding Move module — there is no on-chain surface for builders to
write extensions against refining, and no automation primitive that converts one
item type into others.

Issue #74 lays out a community design for a full mining → hauling → processing
pipeline. This ADR proposes the **on-chain processing slice** of that design as
a self-contained first step:

1. A `world::recipe` primitive — admin-curated registry of conversion rules.
2. A `world::refinery` Smart Assembly — consumes input items per a registered
   recipe and emits outputs after a processing delay.

Out of scope for this ADR (deferred to follow-ups or Issue #74's broader work):
mining (rock scanning, tractor extraction), hauling (volume/mass logistics),
variable-yield outputs, multi-input recipes, throughput modifiers (skills,
ships, fittings), and parallel jobs per refinery.

## Decision

### `world::recipe` (primitive)

- One shared `RecipeRegistry` object published at genesis.
- Each `Recipe` is keyed by `input_type_id` (1 input type per recipe v1).
- A recipe declares `input_quantity` (batch size), `output_type_ids` /
  `output_quantities` (parallel vectors), and `processing_time_ms`.
- Admin-only mutation (`register_recipe`, `update_recipe`, `remove_recipe`)
  gated by `AdminACL::verify_sponsor` — matching the existing pattern in
  `fuel`/`energy`.
- Validation: recipes must specify non-zero input quantity and processing
  time, at least one output, distinct input vs output type ids (no trivial
  loops).
- View functions are non-test-only and free of side effects so extensions can
  inspect recipes in their own logic.

Stored as Sui dynamic fields under `RecipeRegistry.id`, keyed by `RecipeKey {
input_type_id }`.

### `world::refinery` (assembly)

Modeled tightly on `world::storage_unit`. Key parallels:

- `Refinery has key` with the same field shape as `StorageUnit` —
  `key: TenantItemId`, `owner_cap_id`, `type_id`, `status`, `location`,
  `inventory_keys`, `energy_source_id`, `metadata`, `extension`, plus
  `active_job: Option<Job>`.
- `anchor(...)` constructs a Refinery with one inventory keyed by its
  `owner_cap_id`. Same network-node connection + OwnerCap transfer-to-character
  flow as SU.
- `online`/`offline` flip `status` exactly like SU.
- `authorize_extension<Auth>` + `revoke_extension_authorization` +
  `freeze_extension_config` follow the typed-witness pattern.

### Two-mode access

Same shape as SU, by design — extensions and owners both have parity:

| | Extension-gated | Owner-direct |
| - | - | - |
| Deposit input  | `deposit_input<Auth>` | `deposit_input_by_owner<T>` |
| Withdraw input | `withdraw_input<Auth>` | `withdraw_input_by_owner<T>` |
| Start job      | `start_job<Auth>` | `start_job_by_owner<T>` |
| Claim outputs  | `claim_outputs<Auth>` | `claim_outputs_by_owner<T>` |

Extension functions skip the `ctx.sender() == character.character_address`
check — they rely on the registered witness type as proof of authority. Owner
functions require both a matching `OwnerCap` *and* the sender check, mirroring
SU.

### Job model (v1)

**One active job per refinery at a time.** Trade-off:

- ✅ Trivial invariant — `Option<Job>` on the refinery is enough state.
- ✅ Avoids dynamic-field accounting for queued jobs.
- ✅ Matches how players currently think about a single physical refiner.
- ❌ No parallelism across recipe variants on the same refinery; a player who
  wants concurrent processing builds (or anchors) multiple refineries.

`start_job` snapshots the recipe at start time so admins changing a recipe
mid-flight don't change already-running jobs. `claim_outputs` requires
`clock.timestamp_ms() >= job.finishes_at_ms`, then mints outputs into the
inventory via the existing `inventory::mint_items` primitive.

Input is consumed by withdrawing into a transit `Item` and transferring to
`@0x0`. This is a workaround until `world::inventory` exposes an explicit
`destroy_item(item)` helper — see Future Work.

### Shared input/output inventory

The refinery has a single inventory (keyed by `owner_cap_id`). Inputs are
deposited there; outputs are minted there. Recipe validation forbids reusing
the input `type_id` as an output, so there is no ambiguity. This avoids a
second dynamic field per refinery and keeps the SU view-function API shape.

## Alternatives considered

1. **One job slot per recipe (DF keyed by recipe id).** Rejected — adds DF
   bookkeeping, complicates inventory accounting under capacity pressure, and
   isn't justified by current Issue #74 design language.

2. **Output inventory as a separate DF.** Rejected — duplicates code, adds a
   second `inventory_keys` entry per refinery. The recipe-validation rule
   (input ≠ output) gives us the same isolation property at zero structural
   cost.

3. **Per-refinery recipe whitelist.** Rejected for v1 — anyone holding the
   refinery's OwnerCap (or its authorized extension) can start any registered
   recipe. Per-refinery licensing is a useful follow-up (matches the
   gate-permit pattern) but doesn't block the core loop.

4. **No recipe registry; inline rules in extensions.** Rejected — extensions
   would re-implement conversion rules per builder, fragmenting balance/yield
   tuning. A shared registry lets the game team adjust yields without code
   churn in every extension.

## Future work

In rough priority order, none of which block landing this ADR's surface:

- `inventory::destroy_item(item)` so refineries can sink inputs cleanly
  instead of transferring to `@0x0`.
- Variable-yield outputs (RNG bands per recipe).
- Per-character efficiency modifiers (skills, fittings).
- Multi-input recipes.
- Parallel jobs per refinery.
- Per-refinery recipe whitelist / licensing (mirrors gate permits).
- Counter on refinery for stable output `item_id`s (currently placeholder).
- A non-test-only `inventory::item_quantity` so extensions can do
  capacity-aware decisions without devInspect.

## Open questions for maintainers

1. Is refining on the internal roadmap with a different design? If so, this
   should fold into that instead of landing standalone.
2. Should recipes be admin-curated (current proposal) or eventually
   player-discovered (BP loot drops, etc.)?
3. Is `@0x0` an acceptable sink address for consumed inputs, or do we need a
   dedicated burn primitive landed alongside this work?
4. Test coverage: comprehensive job-loop tests for refinery require porting
   the storage_unit test bootstrap. Is a separate testing-infra PR
   preferable, or fold into this one?

## Reference

- Issue [#74 — \[Feat\] Mining System](https://github.com/evefrontier/world-contracts/issues/74)
- `world::storage_unit` (`contracts/world/sources/assemblies/storage_unit.move`) — primary structural model
- `world::gate` permit pattern — model for future per-refinery licensing
- `world::inventory` (`contracts/world/sources/primitives/inventory.move`) — `mint_items` / `deposit_item` / `withdraw_item` primitives this proposal builds on
