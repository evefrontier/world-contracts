# World Contracts Architecture Decision Record (ADR) — v1

## Context

The v0 [architecture](./architechture.md) hard-codes gameplay rules inside each assembly module. `storage_unit.move`, `gate.move` and `turret.move` each embed network node liveness, energy, location, owner/sponsor check, and extension-witness logic directly. New rules like seasonal jump restrictions, alternate power sources, or stacked turret policies require editing core modules, which on Sui means either an upgrade (constrained) or a new package + state migration (expensive).

v1 reframes the architecture so gameplay rules are **independent, composable services attached to generic structures**, with both the on-chain enforcement and the off-chain call shape made discoverable.

It also aligns with the new Modular architechture for game play. A generic hardware whose behaviour comes from the set of service modules attached to it, different modules, different actions. Those services can be authored by 3rd parties, so scanning, defence, or auto-restock policies become rules an owner adds and removes at runtime without redeploying the structure.

## Motivations

### 1. Modular
Structures are not predefined. A "Gate", "Turret", or "Ship" is a generic structure plus a small firmware module that defines what it does. Behaviours live in services that any structure can attach.

### 2. Composable
Rules stack. A structure can require liveness *and* location *and* a custom permit *and* a tribe membership at the same time, instead of a predefined rule set. A structure can be composed with any combination of modules and rules; rules can be added or removed dynamically by the owner.

### 3. Extensible
A new rule = a new service module. No edits to `gate.move`, `turret.move`, or any core module. Existing structures opt in via `add_requirement`.

### 4. Secure
Each rule is enforced by `internal::Permit<T>`: only the module that declares a `Requirement` type can tick its slot or mint authorisation for it. The hot-potato `ApplicationRequest` makes "forgot to check" a compile-time error.

### 5. Moddable
3rd-party services follow the same shape as first-party services. They self-announce via `discovery::announce_service`, and clients (frontends, indexers, the Frontier dispatcher) discover them generically without per-package code.

### 6. Privacy Preserving
Inherited from v0: locations are hashed; proximity is verified via signed proofs (ZK proofs later). v1 does not change this, `location_service` carries it forward. Locations can be revealed off-chain on a need-to-know basis with owner authorisation.

## Decision

Adopt the **Request / Requirement (punch-card) pattern** with on-chain self-describing PTB templates and event-based service discovery (proposed by Mysten Labs in [`damirka/ptb-templates-demo`](https://github.com/damirka/ptb-templates-demo)).

Think of an in-game action as a **customs form**. When you initiate `gate::jump` you receive a paper form with several empty boxes, one per requirement the gate has ("must be online", "must be near the gate", "must hold a ticket"). You walk to each counter (a service module), the officer there inspects what they care about and stamps their box. The form has no "trash" outcome, you can only file it ("complete"), and filing is rejected if any box is unstamped. Different gate, different boxes; new rule tomorrow, just a new counter.

### The three on-chain primitives

```move
public struct Requirement(TypeName, vector<u8>) has copy, drop, store;

public struct ApplicationRequest { /* hot potato */
    action: String,
    requires: vector<Requirement>,
    assembly_id: Option<ID>,
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

### Layer 1 — Core

The design pattern itself, no game logic.

- `request.move` — `ApplicationRequest`, builder, `complete_requirement<T>`, `complete`.
- `requirement.move` — `Requirement(TypeName, bytes)` constructors and accessors.
- `discovery.move` — `announce_service`, `ServiceAnnouncement<T>`, `NewServiceAnnounced` event.

### Layer 2 — Hardware

Generic structures the player owns.

```move
public struct Assembly has key {
    id: UID,
    category: String,           // "Gate", "Turret", "StorageUnit" (informational)
    inner_type: TypeName,       // identifies which firmware owns inner state
    location: Location,
    owner_cap_id: Option<ID>,
    requirements: vector<Requirement>,
}
```

A future `Ship` would live alongside:

```move
public struct Ship has key {
    id: UID,
    inner_type: TypeName,       // which firmware owns the ship's inner state
    location: Location,
    owner_cap_id: Option<ID>,
    requirements: vector<Requirement>,
    // ship-specific fields (crew, hull, …)
}
```

Both share the same `requirements` mechanism, so the same Layer 3 services (liveness, inventory, location, ticketing, …) attach to either. New hardware categories don't require new services.

Inner state is held as a dynamic field, accessed via `internal::Permit<T>` so only the firmware that declares `T` can read/write it. Other hardware modules: `network_node`, `character`.

> Question: Can we add a non-removable `base_requirements` vector for invariants like `SystemAuthorization` and `ProximityToLocation`, in addition to `requirements`?

### Layer 3 — Services

Game-defined digital physics and rules. One module per rule :

| Element | Purpose |
|---|---|
| `public struct Foo has drop {}` | Marker type — only this module can mint `Permit<Foo>` |
| `public fun requirement(...)` | Constructor, returns `Requirement` |
| `public fun verify(req, ...)` | Performs the check, calls `complete_requirement<Foo>` |
| `fun ptb_template(...)` | Describes the satisfying PTB — read via `devInspect` |
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
    assert!(request.assembly_id().is_some_and!(|id| node.connected_assemblies().contains(id)));
    request.complete_requirement<NodeIsOnline>(internal::permit());
}

fun ptb_template(assembly: &Assembly, mut ptb: ptb::Transaction): ptb::Transaction {
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
        "Assembly has to be online and connected to a network node",
        "ptb_template",
        ctx,
    )
}
```

The same pattern can be used by `location_service`, `inventory_service`, `system_service`, `consumption_service`, etc.

### Layer 4 — Firmware

Game actions: what a piece of hardware does. Firmware is a thin shell over Layer 2 hardware that exposes action sites and folds the structure's requirements into a request.

```move
module world::gate;

public struct Gate has store {}

public fun new(
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): (Assembly, OwnerCap, ApplicationRequest) {
    assembly::new(
        Gate {},
        location_hash,
        b"Gate".to_string(),
        vector[location_service::requirement(location_hash)],   // seed requirements
        ctx,
    )
}

public fun jump(gate: &mut Assembly): ApplicationRequest {
    gate.interact(b"gate:jump".to_string(), internal::permit<Gate>())
}
```

`assembly::interact<T>` checks that the assembly's `inner_type` is `T` (only `gate.move` can call `jump` because only it can mint `Permit<Gate>`), then folds `assembly.requirements` into a fresh `ApplicationRequest`.

Firmware modules: `gate`, `storage_unit`, `refinery`, `turret`.

### Layer 5 — Extensions (3rd-party)

External packages defining their own Layer 3 services or Layer 4 firmware. Indistinguishable in shape from first-party modules. 

Reference: [`ticketing::ticket_service`](https://github.com/damirka/ptb-templates-demo/blob/main/packages/ticketing/sources/ticket_service.move) (a Layer 3 service) and [`ticketing::ticketing`](https://github.com/damirka/ptb-templates-demo/blob/main/packages/ticketing/sources/ticketing.move) (a Layer 4 firmware that builds on top of `storage_unit`).

This is what makes "default vs extension" a non-distinction: the default rules and a builder's rules are both just services. Switching turret targeting policies = `remove_requirement` + `add_requirement`.

### Access control

Access control is a common module used by every layer above Core.

- `admin_acl.move` — `AdminACL` and sponsor verification helpers, used by `system_service` to verify game-issued transactions.
- `owner_cap.move` — generic `OwnerCap` definition + `cap_matches` helpers, used by hardware to gate owner-only actions like `add_requirement`, `remove_requirement`, `online`, `link`.
- `character_cap.move` — soulbound (no `store`) capability for the in-game Character.

These live under `access/` and are imported by hardware, services, and firmware as needed. They are deliberately *not* a separate layer because they have no game logic of their own, they only define the cap types and verification helpers other layers compose with.

### Folder Structure

```text
world-contracts/
├── world/
│   ├── sources/
│   │   ├── core/                # request, requirement, discovery
│   │   ├── access/              # admin_acl, owner_cap, character_cap
│   │   ├── hardware/            # assembly, ship (future), network_node, character
│   │   ├── services/            # liveness, location, inventory, system, ...
│   │   ├── firmware/            # gate, storage_unit, refinery, turret
│   │   └── base/                # item
│   └── tests/
│
├── extensions/                  # 3rd-party services
│   ├── tribe_permit/
│   └── turret_policies/
```

---

## End-to-end example: gate jump

The full flow, from structure setup to a player's transaction. Combines on-chain calls and off-chain SDK calls.

### A. Owner sets up the gate (sponsored transactions)

```move
// 1. Anchor the gate (admin sponsored)
let (mut gate, owner_cap, mut req) = gate::new(loc_a, ctx);
system_service::confirm_sponsor_is_system(&sa, &mut req, ctx);
req.complete();

// 2. Connect to a NetworkNode
let mut req = network_node::connect(&mut nwn, &nwn_cap, &mut gate, &owner_cap);
req.complete();

// 3. Online the gate (reserves energy on NWN)
let mut req = gate::online(&mut gate, &owner_cap);
liveness_service::verify_liveness(&mut req, &nwn);
fuel_service::verify_has_fuel(&mut req, &nwn);
energy_service::reserve(&mut req, &mut nwn, GATE_ENERGY);
req.complete();

// 4. Owner attaches a custom 3rd-party rule
gate.add_requirement(&owner_cap, ticketing::ticket_service::requirement());
```

### B. Client SDK builds the player's jump PTB

It uses discovery + templates.

```ts
// 1. Read the gate's requirements (on-chain field).
const gate = await client.getObject({ id: gateId, options: { showContent: true } });
const requirements = gate.content.fields.requirements;
// e.g. [NodeIsOnline, ProximityToLocation, RequiresTicket]

// 2. Look up each requirement in the registry built from
//    `NewServiceAnnounced` events at startup.
const templates = await Promise.all(requirements.map(async (r) => {
    const svc = registry.lookup(r.typeName);                  // {pkg, module, fn}
    return resolveTemplateViaDevInspect(client, {
        servicePackageId: svc.pkg,
        moduleName:       svc.module,
        templateFun:      svc.fn,
        assemblyId:       gateId,
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
- **Clients** — our services drops per-assembly-type code. One generic loop reads `assembly.requirements`, looks each up via discovery, runs `ptb_template` via `devInspect`, applies steps.
- **3rd-party onboarding** — builders write a service the same way the core team does. Reference: `ticketing::ticket_service`.
- **Indexer / SDK discovery** — one event type (`NewServiceAnnounced`) is the entire service catalogue.

### What becomes harder

- **Per-call cost grows** — one extra Move call per rule. Bundle hot paths if profiling demands.
- **PTB construction** — clients must dry-run `ptb_template` and resolve placeholders. Shipped as `ptb-sdk`.

---

## Alternatives Considered

### Alternative 1: Keep typed-witness extensions (v0)
Per-asset `extension: Option<TypeName>` with `authorize_extension<Auth>`.
**Rejected:** Off-chain dispatchers must hardcode per-assembly behaviour; default and extension are a binary switch.

### Alternative 2: Kiosk / TransferPolicy "rules" pattern
Sui framework's `TransferPolicy` lets a creator attach multiple typed `Rule<RuleKey>` to a shared policy.
**Rejected:** rules are tied to a shared policy object, not the asset; mutation always goes through the creator. Doesn't fit "owner-programmable structures".

### Alternative 3: Typed `Assembly<T>` + `OwnerCap<T>`
Phantom-typed assembly + cap (e.g. `Assembly<Gate>`) for compile-time per-kind safety.

**Rejected:** every `T` becomes a separate object type, so indexers and "list my structures" UIs can't enumerate them with a single query, and foreign types like `TicketKiosk` fragment the surface. The isolation it provides is already given by `internal::Permit<T>` on inner-state access — the phantom param just duplicates it at the cost of complexity.

---

## Common Questions

1. **What pattern do builders use to mod in-game functionality?**
   They publish a Move package containing: a marker `struct Foo has drop {}`, a `requirement()` constructor, a `verify()` function gated by `internal::permit<Foo>()`, a `ptb_template()`, and an `init()` that calls `discovery::announce_service`. Owners attach the requirement to their structure via `add_requirement`.

2. **How does this enable upgradeability without breaking immutability?**
   Struct layouts and public APIs of core modules don't change when rules are added — the rules live in *new* packages with their own `TypeName`. Sui's package immutability is a feature here, not a problem: each service is independently versioned and discovered. Per-instance config travels in BCS-encoded `Requirement` bytes, so adding fields to a service's config is a service-local upgrade.

3. **What does the Frontier go-services dispatcher look like in v1?**
   Today (v0), `eve-frontier-go-services/service/assembly/internal/web3/` has one Go file per action per assembly type — `gate_jump.go`, `gate_jump_with_permit.go`, `turret_get_target_priority_list.go`, `storage_unit_inventory_deposit.go`, etc. — each hardcoding the Move target and arguments.

   In v1 they could collapse into one generic builder: (possibility*)

   ```go
   func (c *Client) BuildAction(
       ctx context.Context,
       action string,           // e.g. "gate::jump"
       assemblyID string,
       userArgs map[string]any,
   ) (string, error) {
       assembly, _ := c.GetAssembly(ctx, assemblyID)

       tx := sui.NewProgrammableTransaction(...)
       req := tx.MoveCall(
           fmt.Sprintf("%s::%s", c.WorldContractsPackageID, action),
           []string{},
           tx.SharedMutableObject(assemblyID),
       )

       for _, r := range assembly.Requirements {
           svc      := c.Registry.Lookup(r.TypeName)              // built from announce events
           template := c.DevInspectTemplate(svc, assemblyID)      // resolves ptb_template
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
    No per-assembly-type branches, no hardcoded function names.

4. **Why not just hardcode services in the SDK?**
   For an open ecosystem where 3rd parties define rules the core team didn't anticipate, on-chain discovery is the only way new services reach already-deployed clients without a redeploy.

---

*Prototype reference: `ptb-templates-demo/packages/world/` (on-chain) and `ptb-templates-demo/libraries/ptb-sdk/` (client).*
