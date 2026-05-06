# World Contracts Architecture Decision Record (ADR) — v1

## Context

The v0 [architecture](./architechture.md) hard-codes gameplay rules inside each assembly module. `storage_unit.move`, `gate.move` and `turret.move` each embed network node liveness, energy, location, owner/sponsor check, and extension-witness logic directly. New rules like seasonal jump restrictions, alternate power sources, or stacked turret policies require editing core modules, which on Sui means either an upgrade (constrained) or a new package + state migration (expensive).

v1 reframes the architecture so gameplay rules are **independent, composable services attached to generic structures**, with both the on-chain enforcement and the off-chain call shape made discoverable.

It also aligns with the new Modular architechture for game play. A generic hardware whose behaviour comes from the set of service modules attached to it, different modules, different actions. Those services can be authored by 3rd parties, so scanning, defence, or auto-restock policies become rules an owner adds and removes at runtime without redeploying the structure.

## Motivations

Some of the major motivations behind the v1 design decisions are:

### 1. Modular
Structures are not predefined. Any in-game structure (gate, turret, ship) is built from a generic structure, a small firmware module that defines what it does and a list of rules attached at runtime. New structure kinds can be introduced without touching existing ones.

### 2. Composable
Behaviour emerges from composition rather than predefined rule sets. A single structure can layer multiple independent modules and the owner can add or remove them dynamically. This enables building complex game entities from simple, well-tested rule modules.

### 3. Extensible
Adding a new rule should never require editing core gameplay modules. New rules ship as their own modules and existing structures opt in to them. The shape and lifetime of core code is decoupled from the rate at which game design evolves.

### 4. Secure
Every rule is enforced at the type level: only the module that defines a rule can authorise it being satisfied, and an in-flight action cannot be silently dropped without every rule being checked. This preserves the v0 security guarantee that only authorised entities can mutate on-chain state, while extending it cleanly to authorised entities defined by third parties.

### 5. Moddable
As a core feature of Frontier, builders should be able to change how an owner's structure behaves : jump permissions, turret targeting, scanning logic, defence policies, auto-restock by publishing a custom Move package and letting the owner attach it.

### 6. Privacy Preserving
Inherited from v0: locations are hashed; proximity is verified via signed proofs (ZK proofs later). v1 does not change this, `location_service` carries it forward. Locations can be revealed off-chain on a need-to-know basis with owner authorisation.

## Decision

Adopt the **Request / Requirement (punch-card) pattern** with on-chain self-describing PTB templates and event-based service discovery (proposed by Mysten Labs in [`damirka/ptb-templates-demo`](https://github.com/damirka/ptb-templates-demo)).

Think of an in-game action as a **customs form**. When you initiate an action (`gate::jump`) you receive a paper form with several empty boxes, one per requirement the gate has ("must be online", "must be near the gate", "must hold a ticket"). You walk to each counter (a service module), the officer there inspects what they care about and stamps their box. The form has no "trash" outcome, you can only file it ("complete"), and filing is rejected if any box is unstamped. Different gate, different boxes; new rule tomorrow, just a new counter.

### The three on-chain primitives

```move
public struct Requirement(TypeName, vector<u8>) has copy, drop, store;

public struct ApplicationRequest { /* hot potato */
    action: String,
    requires: vector<Requirement>,
    structure_id: Option<ID>,
    version: u64,
}

// internal::Permit<T> — Move 2024.alpha synthesised package-private witness;
// only the module that declares T can mint it.
```

Every public state-mutating function returns an `ApplicationRequest` carrying a list of `Requirement` checkboxes. Each requirement is tagged with a `TypeName`. Verifiers owned by the module that defines that `TypeName` call `complete_requirement<T>(_: Permit<T>)` to tick their slot. The request has no `drop`; the only way to dispose of it is `complete()`, which aborts on remaining items.

### The two off-chain primitives

- **`ptb_template()`** — each service publishes a Move function that returns a structured PTB describing how to satisfy its requirement. SDKs resolve it via `devInspect`.
- **`discovery::announce_service<T>()`** — services emit a `NewServiceAnnounced` event at publish time so generic clients can find them without hardcoding.

> Question: Should `Requirement` remain `copy`? Useful for folding lists; needs review.


### Layer 1 : Hardware

Generic structures the player owns. A piece of hardware is intentionally minimal: an id, a pointer to its owner cap, a non-removable set of base invariants, and a set of attached firmware modules. Location, metadata, and module state live in **dynamic fields** keyed by the firmware that owns them.

```move
public struct Structure has key {
    id: UID,
    owner_cap_id: Option<ID>,
    base_requirements: vector<Requirement>,   // non-removable: SystemAuthorization, ProximityToLocation
    modules: vector<TypeName>,                // index of attached firmware module TypeNames
    // Per-module slots live as dynamic fields keyed by TypeName<F>.
}

public struct ModuleSlot<phantom F> has store {
    state: ...,                                            // firmware-defined inner state
    requirements: VecMap<String, vector<Requirement>>,     // action_key -> requirements
                                                           // key b"*" applies to every action of F
}
```

A Structure does **not** hard-bind to a single firmware. Anyone can `structure::new(ctx)` to mint a bare hull, then attach modules at runtime to give it behaviour:

```move
let (mut s, owner_cap, req) = structure::new(ctx);
location_service::set_location(&mut s, &admin_acl, loc);
req.complete();

gate::attach(&mut s, &owner_cap, ctx);          // ship-as-gate? attach gate firmware
thruster::attach(&mut s, &owner_cap, ctx);      // plus a thruster
comm::attach(&mut s, &owner_cap, ctx);          // plus a comm module
```

`attach<F>` requires `internal::permit<F>()`, so only the package that defines firmware `F` can authorise that firmware being added. Detach is symmetric and gated by `OwnerCap`.

Trade-off: "every structure has a location" is no longer a type-level guarantee. It's enforced by a non-removable **base requirement** seeded at anchor time, so unlocated structures abort at check-time.

> Open: should modules be hot-swappable while the structure is online (i.e. holds an energy reservation), or only while offline? Affects fuel/energy services that need to release reservations on detach.

### Layer 2 : Firmware

Firmware is a kit-bashable module that defines a set of action sites for a Structure. Multiple firmwares can co-exist on one Structure; each attaches its own slot, owns its own requirements, and exposes its own actions.

```move
module world::gate;

public struct Gate has drop {}    // marker; only this module mints Permit<Gate>

public fun attach(s: &mut Structure, cap: &OwnerCap, ctx: &mut TxContext) {
    structure::attach_module<Gate>(s, cap, internal::permit<Gate>(), GateState { /* ... */ }, ctx);
}

public fun jump(s: &mut Structure): ApplicationRequest {
    structure::interact_module<Gate>(
        s,
        b"gate:jump".to_string(),
        internal::permit<Gate>(),
    )
}

public fun add_requirement(
    s: &mut Structure, cap: &OwnerCap, action: vector<u8>, r: Requirement,
) {
    structure::add_module_requirement<Gate>(s, cap, internal::permit<Gate>(), action.to_string(), r);
}
```

`structure::interact_module<F>(s, action, _)`:

1. asserts `F` is in `s.modules` (only the package owning `F` can mint the permit, so attachment is type-safe);
2. opens a fresh `ApplicationRequest` tagged with `action` and `s.id`;
3. folds in `s.base_requirements`;
4. folds in `module_slot<F>.requirements[action]` plus the wildcard `module_slot<F>.requirements["*"]`;
5. returns the hot-potato request.

The firmware action then **appends action-intrinsic requirements inline** before returning. Three requirement sources collapse into the single returned request:

| Source | Who supplies it | Example on `storage_unit::deposit` |
|---|---|---|
| Base | game core (anchor time, non-removable) | `SystemAuthorization`, `ProximityToLocation` |
| Module-attached, per-action | owner via `add_requirement(action, r)` | `NodeIsOnline` on `*`, `RequiresTicket` on `withdraw` only |
| Action-intrinsic | firmware code itself | `HasItem(type_id, qty)` declared inside `deposit(...)` |

This is what lets a single firmware expose actions with very different shapes:

```move
module world::storage_unit;

public fun deposit(s: &mut Structure, item: Item): ApplicationRequest {
    let mut req = structure::interact_module<StorageUnit>(
        s, b"storage_unit:deposit".to_string(), internal::permit<StorageUnit>(),
    );
    // intrinsic: deposit always needs the item to actually exist & match qty
    req.add_intrinsic(inventory_service::has_item_requirement(item.type_id(), item.quantity()));
    // ... move item into the slot's bag ...
    req
}

public fun withdraw(
    s: &mut Structure, type_id: u64, qty: u32, ctx: &mut TxContext,
): (Item, ApplicationRequest) {
    let item = /* split from slot bag */;
    let req = structure::interact_module<StorageUnit>(
        s, b"storage_unit:withdraw".to_string(), internal::permit<StorageUnit>(),
    );
    (item, req) // no HasItem requirement; withdraw doesn't need one
}
```

Owners stack policies per action without touching firmware code:

```move
// "Every interaction with my storage unit requires the NWN online"
storage_unit::add_requirement(&mut s, &cap, b"*", liveness_service::requirement());
// "Withdrawals additionally require a paid ticket"
storage_unit::add_requirement(&mut s, &cap, b"storage_unit:withdraw", ticketing::ticket_service::requirement());
```

Firmware modules (kit): `gate` (jump, link), `storage_unit` (deposit, withdraw), `refinery` (refine), `turret` (fire), `thruster` (burn), `scanner` (scan), `comm` (broadcast), `power` (reserve, release). A "ship" is a Structure with `[hull, thruster, comm, scanner]` attached; a "network node" is a Structure with `[inventory, power]` attached. The Structure object is identical in both cases.

### Layer 3 : Software

3rd-party packages, user-facing applications built on top of firmware, and/or new requirements that owners can attach to their hardware. Indistinguishable in shape from first-party code. Two flavours:

- **Application software** — extends a firmware with custom logic. Reference: [`ticketing::ticketing`](https://github.com/damirka/ptb-templates-demo/blob/main/packages/ticketing/sources/ticketing.move) — a Ticket Kiosk built on top of `storage_unit`, exposing `buy_ticket`, `collect_proceeds`, `update_payment_type`.
- **Custom requirements** — defines a new rule any owner can attach. Reference: [`ticketing::ticket_service`](https://github.com/damirka/ptb-templates-demo/blob/main/packages/ticketing/sources/ticket_service.move) — defines `RequiresTicket`, verifier, `ptb_template`, and announces.

This is what makes "default vs extension" a non-distinction: the default rules and a builder's rules are both just services. Switching turret targeting policies = `remove_requirement` + `add_requirement`.

---

## Services

Hardware, Firmware, and Software are the visible scaffold; **Services are where the rules actually live**. Every check that gates an action "is the node online?", "is the player close enough?", "do they hold a ticket?" is a service.

In v0 these rules were the bulky middle of `gate.move`, `storage_unit.move`, `turret.move`. v1 pulls each one into its own small module, leaving the assemblies as thin shells. That's what makes rules independently shippable and shape-identical between first-party and 3rd-party authors.

### Requirements

The requirements system is the design pattern that all hardware, firmware, and software share. A requirement is a `(TypeName, bytes)` pair on a hardware's `requirements` vector. There are two kinds:

- **Standard system requirements** — game-team-authored rules: `SystemAuthorization`, `ProximityToLocation`, `NodeIsOnline`, `HasFuel`, `HasEnergyReservation`
- **Custom Third-party requirements** — builder-authored rules: `NeedJumpPermit`, `DepositEVE`, `AggressionTargeting`, …

The two are *shape-identical*. Nothing in the runtime distinguishes them; that uniformity is the point. Every service module looks like this:

| Element | Purpose |
|---|---|
| `public struct Ship has drop {}` | Marker type, only this module can mint `Permit<Ship>` |
| `public fun requirement(...)` | Constructor, returns `Requirement` |
| `public fun verify(req, ...)` | Performs the check, calls `complete_requirement<Foo>` |
| `fun ptb_template(...)` | Describes the satisfying PTB read via `devInspect` |
| `fun init(ctx)` | Calls `discovery::announce_service` |

Example: 

```move
module world::liveness_service;

public struct NodeIsOnline has drop {}

public fun requirement(): Requirement {
    requirement::new<NodeIsOnline>(vector[])
}

public fun verify_liveness(request: &mut ApplicationRequest, node: &NetworkNode) {
    assert!(node.is_online());
    assert!(request.structure_id().is_some_and!(|id| node.connected_structures().contains(id)));
    request.complete_requirement<NodeIsOnline>(internal::permit());
}

fun ptb_template(structure: &Structure, mut ptb: ptb::Transaction): ptb::Transaction {
    ptb.command(ptb::move_call(
        type_name::defining_id<NodeIsOnline>().to_string(),
        "liveness_service", "verify_liveness",
        vector[
            ptb::ext_input<Tag>("request"),
            ptb::ext_input<Tag>("network_node"),
        ],
        vector[],
    ));
    ptb
}

fun init(ctx: &mut TxContext) {
    discovery::announce_service(
        internal::permit<NodeIsOnline>(),
        "Node Liveness",
        "Structure has to be online and connected to a network node",
        "ptb_template",
        ctx,
    )
}
```

### Discovery

Discovery is how generic clients find services and learn how to call them without hardcoding package IDs or function names.

- **`discovery::announce_service<T>()`** — emits a `NewServiceAnnounced` event and creates a `ServiceAnnouncement<T>` object stored at the service's package address (so the announcement is guaranteed to come from the package that defines `T`, via `internal::Permit<T>`).
- **`ptb_template()`** — each service publishes a Move function returning a structured PTB. Clients call it via `devInspect`, BCS-decode the result, and substitute placeholders (`request`, `structure`, owned objects, proofs) to produce the real transaction.

System services (liveness, location, inventory, etc.) are well-known and can be hardcoded by clients if desired. Custom requirements introduced by software always require a `dryRun` / `devInspect` round-trip to resolve their template before the PTB can be built.

### Access control

Authorization primitives shared by every layer:

- `admin_acl.move` — `AdminACL` and sponsor verification helpers, used by `system_service` to verify game-issued transactions.
- `owner_cap.move` — generic `OwnerCap` definition + `cap_matches` helpers, used by hardware to gate owner-only actions like `add_requirement`, `remove_requirement`, `online`, `link`.
- `character_cap.move` — soulbound (no `store`) capability for the in-game Character.
- `internal::Permit<T>` — package-private witness; only the module declaring `T` can mint it. Forging a stamp on a requirement is a build error, not an exploit, so no central allowlist is needed.

These have no game logic of their own they only define cap types and verification helpers other layers compose with.

---

## Folder Structure

The design-pattern primitives live in `core/` (request, requirement, discovery) and have no game logic of their own. Everything else is layered on top:


```text
world-contracts/
├── world/
│   ├── sources/
│   │   ├── core/                # request, requirement, discovery (foundations)
│   │   ├── access/              # admin_acl, owner_cap, character_cap
│   │   ├── hardware/            # structure, character
│   │   ├── services/            # liveness, location, inventory, system, ...
│   │   ├── firmware/            # gate, storage_unit, refinery, turret
│   │   └── base/                # item
│   └── tests/
│
├── software/                    # 3rd-party packages — applications & custom requirements
│   ├── ticketing/              
│   ├── tribe_permit/
│   └── turret_policies/
```

---

## End-to-end example: gate jump

The full flow, from structure setup to a player's transaction. Combines on-chain calls and off-chain SDK calls.

### A. Owner sets up the gate (sponsored transactions)

```move
// 1. Anchor a bare Structure (admin sponsored) and seed base requirements.
let (mut gate, owner_cap, mut req) = structure::new(ctx);
location_service::set_location(&mut gate, &admin_acl, loc_a);
system_service::confirm_sponsor_is_system(&sa, &mut req, ctx);
req.complete();

// 2. Attach the gate firmware. Only the world::gate package can mint Permit<Gate>.
gate::attach(&mut gate, &owner_cap, ctx);

// 3. Connect to a NetworkNode
let mut req = network_node::connect(&mut nwn, &nwn_cap, &mut gate, &owner_cap);
req.complete();

// 4. Online the gate (reserves energy on NWN)
let mut req = gate::online(&mut gate, &owner_cap);
liveness_service::verify_liveness(&mut req, &nwn);
fuel_service::verify_has_fuel(&mut req, &nwn);
energy_service::reserve(&mut req, &mut nwn, GATE_ENERGY);
req.complete();

// 5. Owner attaches a custom 3rd-party rule, only on the `jump` action.
gate::add_requirement(&mut gate, &owner_cap, b"gate:jump", ticketing::ticket_service::requirement());
```

### B. Client SDK builds the player's jump PTB

It uses discovery + templates.

```ts
// 1. Read the structure's base + module requirements for the action being invoked.
//    base_requirements + ModuleSlot<Gate>.requirements["*"] + ModuleSlot<Gate>.requirements["gate:jump"]
const gate = await client.getObject({ id: gateId, options: { showContent: true } });
const requirements = collectRequirementsFor(gate, "Gate", "gate:jump");
// e.g. [SystemAuthorization, ProximityToLocation, NodeIsOnline, RequiresTicket]

// 2. Look up each requirement in the registry built from
//    `NewServiceAnnounced` events at startup.
const templates = await Promise.all(requirements.map(async (r) => {
    const svc = registry.lookup(r.typeName);                  // {pkg, module, fn}
    return resolveTemplateViaDevInspect(client, {
        servicePackageId: svc.pkg,
        moduleName:       svc.module,
        templateFun:      svc.fn,
        structureId:      gateId,
    });
}));

// 3. Build the transaction.
const tx = new Transaction();
const req = tx.moveCall({
    target: `${WORLD_PKG}::gate::jump`,
    arguments: [tx.object(gateId)],
});
buildRequirementCalls(tx, req, {
    requirements,
    resolvedTemplates: templates,
    resolveItem:            (typeId, qty) => tx.object(findOwnedItem(typeId, qty)),
    resolveProximityProof:  ()           => tx.pure(bcs.serialize(proof)),
});
tx.moveCall({ target: `${WORLD_PKG}::request::complete`, arguments: [req] });

// 4. Player signs and submits.
await client.signAndExecuteTransaction({ transaction: tx });
```

The same code handles a gate with `[NodeIsOnline, ProximityToLocation]`, a gate with the extra `RequiresTicket`, or a future gate with a brand-new 3rd-party rule the SDK has never seen because every requirement's call shape is read from chain via `ptb_template`.

### C. On-chain execution

The transaction calls each verifier in order. `gate::jump` produces the request, every service ticks its slot, `request::complete` succeeds. If the NetworkNode is offline, `verify_liveness` aborts and the entire tx reverts — no per-gate state to update.

---

## Consequences

### What becomes easier

- **Adding a rule** — publish a service module; existing structures opt in via `add_requirement`. No core change.
- **Stacking rules** — `requirements: vector<Requirement>` replaces a single `Option<TypeName>` slot.
- **Clients** — our services drops per-structure-type code. One generic loop reads `structure.requirements`, looks each up via discovery, runs `ptb_template` via `devInspect`, applies steps.
- **3rd-party onboarding** — builders write a service the same way the core team does.
- **Indexer / SDK discovery** — one event type (`NewServiceAnnounced`) is the entire service catalogue.

### What becomes harder

- **Per-call cost grows** — one extra Move call per rule. Bundle hot paths if profiling demands.
- **PTB construction** — clients must dry-run `ptb_template` and resolve placeholders. To mitigate we could ship them as `ptb-sdk`.
- **Extra fetch for reads** — location and metadata are dynamic fields, so indexers fetch the structure plus its children.

---

## Alternatives Considered

### Alternative 1: Keep typed-witness extensions (v0)
Per-asset `extension: Option<TypeName>` with `authorize_extension<Auth>`.
**Rejected:** Off-chain dispatchers must hardcode per-assembly behaviour; default and extension are a binary switch.

### Alternative 2: Kiosk / TransferPolicy "rules" pattern
Sui framework's `TransferPolicy` lets a creator attach multiple typed `Rule<RuleKey>` to a shared policy.
**Rejected:** rules are tied to a shared policy object, not the asset; mutation always goes through the creator. Doesn't fit "owner-programmable structures".

### Alternative 3: `Typed Assembly<T>` + `OwnerCap<T>`
Phantom-typed assembly + cap (e.g. `Assembly<Gate>`) for compile-time per-kind safety.
**Rejected:** every `T` becomes a separate object type, so indexers and "list my structures" UIs can't enumerate them with a single query.
---

## Common Questions

1. **What pattern do builders use to mod in-game functionality?**
   They publish a Move package containing: a marker `struct Foo has drop {}`, a `requirement()` constructor, a `verify()` function gated by `internal::permit<Foo>()`, a `ptb_template()`, and an `init()` that calls `discovery::announce_service`. Owners attach the requirement to their structure via `add_requirement`.

2. **How does this enable upgradeability without breaking immutability?**
   Struct layouts and public APIs of core modules don't change when rules are added. The rules live in *new* packages with their own `TypeName`. Sui's package immutability is a feature here, not a problem: each service is independently versioned and discovered. Per-instance config travels in BCS-encoded `Requirement` bytes, so adding fields to a service's config is a service-local upgrade.

3. **What does the Frontier go-services dispatcher look like in v1?**
   Today (v0), `eve-frontier-go-services/service/assembly/internal/web3/` has one Go file per action per assembly type — `gate_jump.go`, `gate_jump_with_permit.go`, `turret_get_target_priority_list.go`, `storage_unit_inventory_deposit.go`, etc. — each hardcoding the Move target and arguments.

   In v1 they could collapse into one generic builder: (possibility*)

   ```go
   func (c *Client) BuildAction(
       ctx context.Context,
       action string,           // e.g. "gate::jump"
       structureID string,
       userArgs map[string]any,
   ) (string, error) {
       structure, _ := c.GetStructure(ctx, structureID)

       tx := sui.NewProgrammableTransaction(...)
       req := tx.MoveCall(
           fmt.Sprintf("%s::%s", c.WorldContractsPackageID, action),
           []string{},
           tx.SharedMutableObject(structureID),
       )

       for _, r := range structure.Requirements {
           svc      := c.Registry.Lookup(r.TypeName)              // built from announce events
           template := c.DevInspectTemplate(svc, structureID)     // resolves ptb_template
           c.ApplySteps(tx, req, template, userArgs)              // generic placeholder resolution
       }

       tx.MoveCall(
           fmt.Sprintf("%s::request::complete", c.WorldContractsPackageID),
           []string{},
           req,
       )

       return tx.SimulateAndGetTransactionBytes(ctx)
   }
   ```
    No per-structure-type branches, no hardcoded function names.

4. **Why not just hardcode services in the SDK?**
   For an open ecosystem where 3rd parties define rules the core team didn't anticipate, on-chain discovery is the only way new services reach already-deployed clients without a redeploy.

---

*Prototype reference: [request-requirement-prototype](https://github.com/damirka/fronteer-world-contracts/tree/main/contracts/world_2) and [ptb-templates-and-discovery-prototype](https://github.com/damirka/ptb-templates-demo).*
