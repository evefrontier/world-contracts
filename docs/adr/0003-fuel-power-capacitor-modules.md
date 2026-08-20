# 3. Fuel, Power, and Capacitor Modules

- **Status:** Proposed

## Context

A structure/ship (Entity) installs modules; some of them need power to run. The
game model has three cooperating module types:

- **Fuel Tank:** stores fuel the entity burns.
- **Power Gen:** burns fuel to produce a steady flow of power (PowerGrid, in MW).
- **Capacitor (Battery):** stores some of that power so burst actions can spend it.

In one line: *fuel keeps the lights on; the generator turns fuel into power; the
battery lets you save power for bursts.*

The game design assumes **continuous background processes**: fuel drains every
1–10 s, generators produce a steady MW flow, batteries trickle-charge from spare
grid. Move has **no background process**; nothing changes unless a transaction
touches the object. This ADR records how we translate a continuous, thread-based
game model into an on-chain, transaction-driven one, and how power composes with
the Entity/Module/Action/Request/Requirement architecture from ADR-0002.

An Entity does not have to generate its own power to run powered modules. It can
install a **Power Link** module that references another Entity's `Module<Power>`
and draw from that Entity's grid/battery instead e.g. a small structure with no
Fuel Tank/Power Gen/Capacitor of its own, wired into a neighboring structure's
power. Because of this, **no action may assume "power source = self."** Every
power-costing action takes the power-owning Entity as an explicit input, and the
handler validates that input (self, or a connected Power Link target) before it
settles anything.

The mechanical split we are modeling (confirmed against the in-game code):

| Cost | What it is | Paid | Keyed by |
| --- | --- | --- | --- |
| **PowerGrid draw (MW)** | continuous reservation while a module is Online | once, at online; released at offline | the **module type_id** (a type property) |
| **Capacitor charge (units)** | per-activation burst cost | fresh, each activation | the **calling function/behavior** (an activation property) |

These are two independent systems and stay independent on-chain.

## Decision 1: Lazy settlement is the source of truth. No cron jobs

Fuel and charge are derived from `(rate, elapsed_since_last_settle)` when a
transaction touches the entity, not live countdowns. No on-chain burn or
trickle-charge thread.

Every power-relevant handler starts with `settle(power, clock)`: advance fuel
and charge for the elapsed window, then stamp `last_settled_ms`.

A public view function calculates the value based on the same settle math
(Decision 7). Callers get a live `fuel_qty`/`charge` via dry-run, no gas, no
write.

Raw object fields staying stale between touches, for indexers that don't call
the view, is expected, not a correctness issue.

**Alternatives considered:**

- **Pure lazy, no keeper, no view.** Rejected: no live read without a write.
- **Keeper is authoritative.** Rejected: correctness would depend on off-chain
  liveness and a gas payer.

## Decision 2: One singleton `Module<Power>` owns the pools and the clock

`Module<Power>` is required **only for an Entity that itself generates or stores
power** i.e. one that has ever installed a Fuel Tank, Power Gen, or Capacitor.
It sits at a fixed name (`"power"`), like `identity` on a Character, and owns the
fuel pool, battery charge, burn clock, and running-total ceilings.

An Entity with none of those three module types has no `Module<Power>` at all.
If it wants to run powered modules, it installs a Power Link (Decision 8)
pointed at another Entity's `Module<Power>` instead of growing its own.

```move
public struct Power has store {
    last_settled_ms: u64,     // burn-clock anchor

    // pooled fuel
    fuel_qty_at_last_settle: u64,  // pooled fuel remaining, as of last_settled_ms
    fuel_type_id: Option<u64>,     // which fuel is loaded; None when empty

    // battery stock
    charge_at_last_settle: u64,   // pooled battery stored energy, as of last_settled_ms

    // running-total ceilings (summed from online contributions)
    total_output_mw: u64,     // sum of online Power Gens
    total_draw_mw: u64,       // sum of online grid reservations
    total_capacity: u64,      // sum of online Capacitors
    total_recharge_mw: u64,   // sum of online Capacitors' rechargeRateRatio * capacity
    total_discharge: u64,     // sum of online Capacitors' discharge limit
}
```

Fuel Tank, Power Gen, and Capacitor stay **separate installable modules**; each
holds its own attributes. Online/install `+=` into Power's totals; offline/remove
`-=`. Settle reads a handful of `u64`s **no walk over heterogeneous modules**
(Move cannot do that cleanly).

Matches the game model: tanks pool fuel, gens stack a ceiling, batteries pool one
reservoir.

**Alternatives considered:**

- **Fully independent modules; aggregate on read.** Rejected: Move cannot iterate
  heterogeneous dynamic-field module types to sum MW at settle.
- **One monolithic Power module.** Rejected: breaks "install a module" and
  placement/footprint; the three are distinct fittable things in-game.
- **Per-contribution ledger in Power (`VecMap<name, Contribution>`).**
  Drift-proof and enables ordered shedding. Rejected for v1 (see Decision 8):
  duplicates module-owned data; not needed while shedding is coarse. Migration
  path if ordered shedding lands.

## Decision 3: Contributions are running scalar totals

Power holds only the **sums** (Decision 2). Each `Module<PowerGen>` /
`Module<FuelTank>` / `Module<Capacitor>` owns its attributes and is the source of
truth for the `-=` on offline/remove.

- Online a Power Gen: `total_output_mw += gen.output`.
- Online a consumer: `total_draw_mw += resolved_grid_draw` (see Decision 5).
- Online a Capacitor: `total_capacity += cap`, `total_discharge += limit`,
  `total_recharge_mw += rechargeRateRatio * cap`.
- Offline / remove: the symmetric `-=` for all three above.

**Recharge is summed, per-instance.** Each Capacitor authors its own
`rechargeRateRatio`; its recharge contribution is
`rechargeRateRatio × capacitorCapacity`, computed from the module's own
attributes at online-time, not a `PowerConfig` lookup.
Two identical Capacitors double both `total_capacity` and `total_recharge_mw`
together, so fill time is unchanged; a higher-quality Capacitor has a higher
ratio and fills faster. Different Capacitor types can be Online concurrently;
each contributes independently.

**Alternatives considered:**

- **Contribution list inside Power.** Totals always re-derivable. Rejected for
  v1: extra storage/iteration we don't need while shedding is coarse.

## Decision 4: Fuel is a single-type pooled scalar, not inventory

Assumptions (v1): fuel in the tank is not tradeable, and once deposited it is
burned, not withdrawable.

Deposit consumes a fuel `Item` and adds `quantity` to
`Power.fuel_qty_at_last_settle`, capped by sum of online Fuel Tank capacity. The
tank module contributes **capacity only**.

**One fuel type at a time.** `fuel_type_id` is set on first deposit into an empty
pool; a different type into a non-empty pool aborts (`EFuelTypeMismatch`).

**Quality factor is not stored on `Power`.** It lives in
`PowerConfig.fuel_factor` (Decision 5) and is resolved at burn time. Re-tunes take
effect on the next settle; no stale copy. Quality changes **how long** fuel lasts,
not **how much** power gens produce.

**Alternatives considered:**

- **Fuel Tank as Inventory; burn withdraws items over time.** Rejected: lazy burn
  does not map cleanly onto whole-item counts. Withdraw-unburned is a future
  option, not v1.

## Decision 5: Grid draw is keyed by type_id; charge cost by the calling function

Two cost systems, two homes:

**Grid draw:** property of the **module type**. Shared admin `PowerConfig`:

```
PowerConfig (shared object, admin-managed)
├── grid_draw:   Table<type_id, mw>
└── fuel_factor: Table<fuel_type_id, factor>
```

Resolved **once at online** and stored on the reservation. Settle never re-reads
the table; re-tunes apply on next re-online, not to already-online modules.

**Charge cost:** property of the **behavior being activated**. The handler
declares a `Charge` requirement from **its own module config** (retune without a
package upgrade). Power only spends/reserves; it does not know per-function costs.
Handlers may apply a situational multiplier (e.g. d-scan vs scan angle).

**Alternatives considered:**

- **Central `charge_cost` table keyed by action_id.** Rejected: no stable
  on-chain key for "a function"; cost belongs with the behavior that spends it.

## Decision 6: Grid and Charge are two independent Requirements, each with an explicit source

Power composes as **two separate `Requirement` types** (like `Deposit` /
`Proximity` stack independently on an Action) instead of one Requirement with an
internal cost-kind choice:

```move
public struct GridDraw has store { mw: u64 }      // persisted reservation, +/- at online/offline
public struct ChargeDraw has store { units: u64 } // one-shot, spent at activation
```

An action declares zero, one, or both, matching the real game model: a sustained
process consumer and a burst consumer are different costs, and a module can have
both at once (e.g. an Online reservation plus a per-Fire charge). There is no
combined "cost kind" type; each Requirement is checked independently, same as
every other Requirement on the Request.

Neither resolves its target implicitly from `self`; the caller must name
**which Entity's** `Module<Power>` pays:

```move
public fun do_action(entity: &mut Entity, power_entity: &mut Entity, ..., clock: &Clock)
```

`power_entity` is not assumed to be `entity`. Each Requirement's handler
resolves it the same way, regardless of whether power is local or linked:

1. Borrow `Module<Power>` from `power_entity`; abort `EMissingPower` if absent.
2. If `power_entity.id() != entity.id()`, borrow `entity`'s `Module<PowerLink>`
   and require `power_link.source == power_entity.id()`, abort
   `EInvalidPowerSource` otherwise (Decision 8). A caller cannot point an action
   at an arbitrary Entity's power; it must be self or an already-connected link.
3. `settle(power, clock, config)`: idempotent, safe to call once per Requirement
   on the same `power_entity` within one Request, then apply:
   - `GridDraw(mw)`: admit iff `mw ≤ headroom`, then `total_draw_mw += mw` on
     `power_entity` (released at offline).
   - `ChargeDraw(units)`: one-shot: require `charge ≥ units` and
     `units ≤ total_discharge` (the battery's burst-rate ceiling), then
     `charge -= units`. No reservation; no direct fuel burn (fuel burns via
     later recharge).

There is no implicit "self" fallback in either handler; a purely local module
just happens to call this with `power_entity = entity`. Same code path, no
special case.

**Online/offline are Actions**, not plain entries: they mint a Request so access
control and proximity compose like everything else. That is where `GridDraw`'s
reservation is `+=` / `-=`, and it always lands on `power_entity`, whether that is
`entity` itself or an Entity it's linked to.

**Alternatives considered:**

- **Online/offline as plain owner-gated entries.** Rejected: hardcodes access
  control and breaks "every behavior is an exposed action."
- **Resolve source implicitly (`self`, falling back to a linked Entity if `self`
  has no `Module<Power>`).** Rejected: hides which object a transaction actually
  mutates, which the PTB has to name anyway (shared-object input); an explicit
  parameter matches what the transaction already must declare, and keeps local
  and linked power on one code path instead of two.
- **One combined `PowerCost { grid, charge }` struct instead of two
  Requirements.** Considered as the direct fix. Rejected in favor of two plain
  Requirements.

## Decision 7: Settlement is two-phase (pre-dry / post-dry)

Recharge burns fuel. Fuel can run out mid-interval, so `settle` splits the window
at dry-out; otherwise a late poke mis-charges the battery.

All of the following are **locals** computed in `settle`. Burn factor
comes from config (Decision 4), so `settle` takes `PowerConfig`:

```
factor            = PowerConfig.fuel_factor[fuel_type_id]
elapsed           = now − last_settled_ms
headroom          = max(0, total_output_mw − total_draw_mw)
admitted_recharge = min(total_recharge_mw, headroom) // spare grid only
served_load       = min(total_draw_mw + admitted_recharge, total_output_mw)
fuel_needed       = served_load * elapsed / factor
```

- **Fuel lasts** (`fuel_needed ≤ fuel_qty`): burn it; charge
  `+= admitted_recharge * elapsed` (capped at `total_capacity`).
- **Fuel dies mid-window** (`served_load > 0`):
  `t_dry = fuel_qty * factor / served_load`.
  - `[0, t_dry]`: gens run, recharge admitted, fuel burns to 0.
  - `[t_dry, elapsed]`: grid dead; battery covers `total_draw_mw`
    (`charge −= total_draw_mw * (elapsed − t_dry)`, floored at 0).
    If `served_load = 0`, skip the mid-window split: no burn and no `t_dry`.

Empty pool (`fuel_type_id = None`): no burn; battery alone covers draw until
`charge = 0`.

`total_draw_mw` / `total_output_mw` stay constant inside an interval: every
install/online/offline settles first.

**Alternatives considered:**

- **Single-phase settle** (ignore mid-interval fuel-out). Simpler. Rejected: a
  late poke would credit recharge that never happened.

## Decision 8: A Power Link module lets one Entity draw from another Entity's Power

An Entity with no Fuel Tank/Power Gen/Capacitor of its own (Decision 2) can still
run powered modules by installing a **Power Link**, a one-hop pointer at another
Entity's `Module<Power>`:

```move
public struct PowerLink has store {
    source: ID, // the Entity whose Module<Power> this Entity draws from
}
```

**Connect / Disconnect are Actions** so they create a Request and compose with
Proximity and an access/consent Requirement on the source Entity's owner. A
structure's owner must approve being wired into, the same way install already
requires admin approval.

- **Connect(source: &mut Entity):** aborts unless `source` has a `Module<Power>`
  (Decision 2: a link target must generate/store power itself; **no chaining**
  an Entity that is itself powered only via a Power Link cannot be a Connect
  target). On success: reserves the Power Link's own Grid draw against
  `source.total_draw_mw` (its `type_id` in `PowerConfig.grid_draw`), and sets
  `source = source.id()`.
- **Disconnect():** aborts if any other module on this Entity still holds a
  Grid reservation sourced from `source` (Decision 6 step 2/3: those actions
  must offline first, same "never sheds, abort instead" rule as Decision 6).

Once connected, every other module on this Entity pays its `GridDraw` /
`ChargeDraw` against `source` exactly as if it were local. The `PowerLink` only
gates *which* external Entity is a legal `power_entity` argument; it does not
pool or relay power itself. `source.total_draw_mw` and `source.charge` see those
draws exactly as if the module were installed on `source` directly.

Because a linked action's PTB must carry both Entities (`entity` and
`power_entity` are separate shared-object inputs), a popular power source
becomes a contention point for every Entity linked to it in the same checkpoint an accepted tradeoff, not solved here.

**Alternatives considered:**

- **Multi-hop relay (A powers B powers C).** Rejected for v1: needs cycle
  detection and makes headroom/settle math recursive across an unbounded chain
  of Entities. One hop covers "small structure wired into a neighbor" without it.
- **Power pooled/copied onto the linked Entity at connect-time.** Rejected:
  reintroduces a second source of truth Decision 1 already ruled out the
  pool must stay on exactly one `Module<Power>`.
- **No dedicated Power Link module; pass any Entity's Power object as
  `power_entity` with no prior Connect.** Rejected: no consent gate, no
  Proximity check, and no way to abort Disconnect while something still draws
  same reasons Decision 6 rejected owner-gated plain entries for Online/Offline.

## Decision 9: Fuel-out shutdown is coarse in v1; ordered shedding deferred

When fuel and battery charge are both exhausted, there is no thread to flip
modules Offline. Shutdown is **lazy and coarse**: after fuel-out, gens contribute
0 and the battery pays the **full** online `total_draw_mw` until `charge = 0`
(same load the gens were serving, not a concurrent remainder beyond gen output).
After that **every power-requiring action fails** (`EInsufficientPower`) until
refuel. No per-module shed writes, no ordering. Recovery is a refuel followed by
re-online.

There is no proactive shutdown signal. The crossing to `charge = 0` is only
visible when something next touches the entity: a real tx (which settles, then
fails with `EInsufficientPower`) or a call to the view function (Decision 1)
after the fact. Nothing predicts or announces the exact moment it happens.

Temporary shape. Left open (not decided here):

- **Deterministic smallest-draw-first shedding:** game-design rule; needs the
  contribution ledger (Decision 2 rejected alt).
- **Ordered shedding across Power-Link consumers:** when a source Entity runs
  dry, every Entity linked to it (Decision 8) fails alongside its own onboard
  modules; there is no priority between "local" and "linked" draw. Same
  contribution-ledger dependency as above.

**Alternatives considered:**

- **Ordered shedding in v1.** Best UX. Rejected: needs the ledger and shed-order
  writes at settle time.
- **Hard shed on the burn path with scalar totals only.** Rejected: scalars
  cannot pick a victim by draw, so it degenerates to coarse; no benefit over
  fail-on-check.

## Consequences

- **New shared object `PowerConfig`** (`grid_draw` by type_id, `fuel_factor` by
  fuel type_id), admin-managed.
- `Module<Power>` is a required singleton only for an Entity that generates or
  stores power itself (Decision 2); it must exist before Fuel Tank / Power Gen /
  Capacitor can register contributions.
- **Every power-costing action takes the power-owning Entity as an explicit
  argument** (Decision 6); there is no implicit "self"; local and Power-Link
  consumption are the same code path.
- **New `Module<PowerLink>`** (Decision 8): one-hop pointer from a consuming
  Entity to a power-generating Entity, gated by Connect/Disconnect Actions.
- **Grid draw is fixed at online-time:** re-tuning `PowerConfig.grid_draw`
  affects a live module only after it re-onlines.
- **Charge cost lives with each calling module,** so adding a new powered
  behavior does not touch Power or a central table.
- **A linked action's PTB must carry both Entities** as shared-object inputs,
  so a heavily-linked power source is a shared-object contention point.

## Out of Scope

- Multi-hop power relay (an Entity powered via a Power Link cannot itself be a
  Connect target), ordered shedding (local or across Power-Link consumers),
  withdraw-unburned-fuel.

## Future considerations (not decided; for later reference)

- **Fuel as a direct action input.** Some future action spends pooled fuel
  directly, not just via Power Gen burn. Shape: a new `FuelDraw` Requirement,
  same pattern as `ChargeDraw`, checked against `fuel_qty_at_last_settle`. No
  `Power` field changes needed.
- **Live factors on grid output.** Factors that scale `total_output_mw`
  mid-interval, not via install/online/offline. Event-driven versions (a module
  contributing +/- to the total) already work today (Decision 3). A *live*
  multiplier inside `settle()` (Decision 7) would need a new shared config
  object `PowerConfig`.
- **Live factors on recharge rate.** Same shape as the output case, applied to
  `total_recharge_mw` instead of `total_output_mw`.
- **Multiple concurrent Power Links.** Decision 8's `PowerLink` holds one
  `source: ID`. Drawing from more than one external source at once needs a set
  of sources instead. Should we add it now as an extra field or later?
- **Multiple named power grids on one Entity.** Likely already possible with
  no Decision 6 change: `core::entity::install` / `module_mut` already key
  modules by name resolved off the Request (not a caller-supplied argument),
  so a second `Module<Power>` under a different name should already be
  independently addressable. Revisit once `core::entity`'s `ModuleKey` (see the
  TODO in `entity.move`: string vs. module id) is settled.
