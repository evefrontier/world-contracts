# ADR: Modular Structures
## Motivation

The current production `world` design is assembly-first. Each structure type, such as a gate or storage unit, owns its object shape and exposes a fixed set of APIs.

That model is simple to integrate, but it does not fit the next modular building direction well:

1. **Upgrades are painful** because behavior is encoded in predefined object layouts. Once a Sui object type is published, changing stored fields usually means introducing a new type and migrating state.
2. **New game behavior often requires core changes** because rules are attached to specific assembly functions instead of a shared programmable action model.
3. **Composition is limited** because programmability is restrictive and not generalized across actions.

The goal of the new architecture is to keep the base structure small, install behavior through modules, and make behavior programmable through on-chain requirements.

### Modular Building

We want to support modular buildings in the game:

1. Create a base structure.
2. Install modules that provide behavior, such as storage, transport, fuel, power, or weapons.
3. Expose programmable actions that compose those module behaviors.
4. Attach rules to those actions so game design can evolve without changing the base structure type.

Example:

A player owns a structure and installs a storage module on it. Later, they configure that structure to offer an exchange: give one ticket and receive one fuel item.

## Decision

Introduce a modular architecture built around five concepts:

- `Entity`: the base shared object representing a structure.
- `Module<T>`: typed module state installed on an entity.
- `Action`: a named programmable behavior exposed by an entity.
- `Request`: a hot-potato value created when an action starts.
- `Requirement`: a typed rule that must be satisfied before the request can complete.

The key design shift is:

| Current model | New model |
| --- | --- |
| A concrete assembly type owns behavior, such as `gate::jump` or `storage_unit::deposit`. | A base `Entity` owns installed modules and exposes named actions. |
| Rules are encoded inside assembly functions. | Rules are represented as `Requirement` values attached to actions. |
| Adding behavior often means changing core assembly code. | Adding behavior usually means installing a module, adding a handler, or exposing a new action. |
| Clients integrate with assembly-specific APIs. | Clients inspect an action, satisfy its requirements, and complete the request. |

## Architecture Overview

```mermaid
flowchart TD
    Structure["Structure<br/>base Entity"]
    Modules["Installed modules<br/>Storage, Transport, Fuel"]
    Configure["Configure actions<br/>exchange, jump, deposit"]
    User["User interacts with<br/>Deposit and Jump action"]
    Request["Request<br/>requirements for this action"]
    Req1["Requirement 1<br/>approved by admin"]
    Req2["Requirement 2<br/>item must be deposited"]
    Req3["Requirement 3<br/>jump must be allowed"]
    Handler1["Admin module<br/>satisfies requirement"]
    Handler2["Inventory module<br/>satisfies requirement"]
    Handler3["Transport module<br/>satisfies requirement"]
    AllSatisfied["All requirements<br/>are satisfied"]
    Complete["Complete action"]

    Structure --> Modules
    Modules --> Configure
    Configure --> User
    User --> Request
    Request --> Req1
    Request --> Req2
    Request --> Req3
    Req1 --> Handler1
    Req2 --> Handler2
    Req3 --> Handler3
    Handler1 --> AllSatisfied
    Handler2 --> AllSatisfied
    Handler3 --> AllSatisfied
    AllSatisfied --> Complete
```

At a high level:

1. Admin or owner creates an `Entity`.
2. Admin-approved modules are installed on the entity.
3. Owner exposes named actions, each with an ordered list of requirements.
4. A user interacts with an action, which creates a `Request`.
5. The PTB satisfies each requirement by calling the right handler.
6. The entity completes the request only when no requirements remain.

## Core Concepts

### Entity

`Entity` is the base structure object. It stays small and stores extension data through dynamic fields.

Conceptually:

```move
public struct Entity has key {
    id: UID,
    version: u64,
    // dynamic field: ActionsKey() => VecMap<String, Action>
    // dynamic field: ModuleKey(String) => Module<T>
}
```

This means adding a new module does not require adding a new field to the base entity type.

### Module

`Module<T>` wraps typed module state installed on an entity.

Examples:

- `Module<Inventory>`
- `Module<Transport>`
- `Module<Fuel>`
- `Module<PowerGen>`

The module is stored under a human-readable name:

```text
ModuleKey("storage unit (01)") => Module<Inventory>
ModuleKey("transport")         => Module<Transport>
```

Requirements can target a module by name, so the same entity can host multiple modules of the same type if needed.

### Action

An `Action` is a named list of requirements.

Examples:

- `deposit to SU-01`
- `withdraw from SU-01`
- `exchange tickets for fuel 1:1`
- `jump through gate`

Conceptually:

```move
public struct Action has drop, store {
    /// Requirements are stored in reverse of declaration order.
    requirements: vector<Requirement>,
    version: u64,
}

public fun new(mut requirements: vector<Requirement>): Action {
    requirements.reverse(); // store reversed so pop_back yields declaration order
    Action { requirements, version: VERSION }
}
```

The action does not execute logic by itself. It creates a request that must be satisfied by module or service calls.

### Request

`Request` is the transaction-scoped checklist for one action.

```move
public struct Request {
    structure_id: Option<ID>,
    requires: vector<Requirement>,
}
```

`Request` intentionally has no abilities. It cannot be stored, copied, or dropped. Once created, the transaction must satisfy it and complete it.

### Requirement

`Requirement` is a typed rule instance.

```move
public struct Requirement has drop, store {
    type_name: TypeName,
    name: Option<String>,
    data: vector<u8>,
}
```

Each requirement contains:

- `type_name`: identifies which handler is allowed to satisfy it, such as `inventory::Deposit`.
- `name`: optionally targets an installed module, such as `some("storage unit (01)")`.
- `data`: BCS-encoded configuration, such as item type and min/max quantity.

Example requirement constructor:

```move
public fun deposit_requirement(module_name: String, rule: ItemRequirement): Requirement {
    requirement::new(
        option::some(module_name),
        Deposit(rule),
    )
}
```

The config is stored as bytes, but the type identity is still `Deposit`. This lets the handler prove it is satisfying the correct rule.

## Request + Requirement Flow

The important invariant is simple:

```text
An action can complete only when every requirement has been satisfied.
```

The request API is:

```move
// Pop the next requirement, proving the caller owns type `T` via a Permit.
// Returns the requirement plus a Frame the handler can push follow-ups into.
public fun take_next<T>(request: &mut Request, _: internal::Permit<T>): (Requirement, Frame) {
    let next = request.requires.pop_back();
    assert!(next.is<T>(), 0);
    (next, Frame { pending: vector[] })
}

// Push any newly-spawned requirements back onto the request.
public fun enqueue(request: &mut Request, frame: Frame) { /* ... */ }

public(package) fun complete(request: Request) {
    let Request { requires, .. } = request;
    assert!(requires.length() == 0);
}
```

Handlers call `take_next<T>` (aliased as `satisfy<T>`) with the type they own. The `Permit<T>` is package-private, so only the module that defines `T` can satisfy a requirement of that type.

The handler does three things:

1. Borrows the targeted module through the active request.
2. Satisfies the next typed requirement.
3. Enforces the requirement data before mutating state.

The returned `Frame` lets a handler push **new** requirements onto the same request before continuing — this is how dynamic, in-transaction follow-ups are modeled (the handler `enqueue`s the frame when done).

#### Module targeting (`name` enforcement)

`take_next<T>` only checks the requirement *type*. Module *identity* is enforced when the handler borrows the module. `module_mut` reads the module name off the **next requirement**, not off the handler's own arguments:

```move
public fun module_mut<T: store>(e: &mut Entity, req: &Request, _: internal::Permit<T>): &mut Module<T> {
    assert!(req.structure_id().is_some_and!(|id| id == e.id.to_inner()));
    // name comes from the requirement, so the handler can't hit the wrong module
    let name = req.next().module_name().destroy_or!(abort);
    assert!(!e.exists(DeprecatedModuleKey(name)));
    &mut e[ModuleKey(name)]
}
```

So a requirement scoped to `some("storage unit (02)")` forces the handler onto module `(02)`; it can never accidentally mutate `(01)`. The `name` field is `Option` only for requirements that don't target a module (e.g. an admin/sponsor approval); module handlers `abort` when it is `None`.

## Use Case: Exchange Tickets For Fuel

Setup:

1. Install an `Inventory` module named `storage unit (01)`.
2. Expose an action named `exchange tickets for fuel 1:1`.
3. The action has two requirements:
   - `Deposit(ItemRequirement { type_id: TICKET, quantity: 1 })`
   - `Withdrawal(ItemRequirement { type_id: FUEL, quantity: 1 })`

```mermaid
sequenceDiagram
    participant User as User / PTB
    participant Entity
    participant Request
    participant Inventory as Inventory module

    User->>Entity: interact("exchange tickets for fuel 1:1")
    Entity-->>User: Request { Deposit<TICKET>, Withdrawal<FUEL> }
    User->>Inventory: deposit(entity, request, ticket)
    Inventory->>Request: satisfy<Deposit>
    Inventory->>Inventory: store ticket
    User->>Inventory: withdraw(entity, request, FUEL, 1)
    Inventory->>Request: satisfy<Withdrawal>
    Inventory-->>User: fuel item
    User->>Entity: complete_request(request)
    Entity->>Request: assert no requirements remain
```

```move
// 1. Install inventory behavior.
let mut request = entity.install("storage unit (01)", inventory::new(ctx), ctx);
admin_acl::approve_install<inventory::Inventory>(&admin, &mut request, ctx);
entity.complete_request(request);

// 2. Expose a programmable action.
let request = entity.expose(
    "exchange tickets for fuel 1:1",
    action::new(vector[
        inventory::deposit_requirement(
            "storage unit (01)",
            option::some(TICKET_TYPE_ID),
            option::some(1),
            option::some(1),
        ),
        inventory::withdraw_requirement(
            "storage unit (01)",
            option::some(FUEL_TYPE_ID),
            option::some(1),
            option::some(1),
        ),
    ]),
    ctx,
);
entity.complete_request(request);

// 3. Execute the action.
let mut request = entity.interact("exchange tickets for fuel 1:1", ctx);
inventory::deposit(&mut entity, &mut request, item::new(TICKET_TYPE_ID, 1, ctx));
let fuel = inventory::withdraw(&mut entity, &mut request, FUEL_TYPE_ID, 1, ctx);
entity.complete_request(request);
```

## Client And PTB Discovery

The trade-off of programmable actions is that the client must know how to satisfy requirements.

The intended pattern is:

1. Client calls or inspects an action and sees its requirements.
2. Each requirement type maps to a PTB template or handler.
3. The client builds a PTB that calls the handlers in order.
4. The final call completes the request.

Example mapping:

```text
inventory::Deposit      -> inventory::deposit_template / inventory::deposit
inventory::Withdrawal   -> inventory::withdraw_template / inventory::withdraw
```

Example PTB template for client discovery:

```move
public fun deposit_template(
    req: &Requirement,
    ptb: &mut ptb::Transaction,
    mut args: vector<ptb::Argument>,
): vector<ptb::Argument> {
    ptb.command(
        ptb::move_call(
            "mvr:@frontier/inventory",
            "inventory",
            "deposit",
            vector[tx::entity(), tx::request(), item],
            vector[],
        ),
    );

    vector[]
}
```

This keeps Move contracts authoritative while letting SDKs automate transaction construction.

## Upgrade And Lifecycle Strategy

The new design does not rely on one upgrade mechanism. It gives us several options depending on the change.

For additive changes:

- Add a new requirement type or handler.
- Expose new actions that include the requirement.
- Existing entity and module layouts can stay unchanged.

For bug fixes:

- Upgrade the package if the function body can change safely.
- Add version checks when old behavior must be blocked.
- Disable or remove stale actions if they should no longer be used.

For stored layout/interface changes:

- Introduce `InventoryV2` or another new module type.
- Install the V2 module.
- Migrate known state from V1 to V2.
- Deprecate the old module name.
- Remove stale actions that point at V1 requirements.

Lifecycle APIs support this:

```move
entity::disable_action(&mut entity, &admin_acl, action_name, ctx); // reversible soft block
entity::remove_action(&mut entity, &admin_acl, action_name, ctx);  // hard delete stale action data
entity::deprecate_module(&mut entity, &admin_acl, module_name, ctx);
```

## Consequences

What becomes easier:

- **Upgrades**: core entity logic and module behavior are decoupled, so new modules, new rules, and V2 module migrations do not always require changing the base structure.
- **Reusability**: independent checks such as admin approval, sponsor approval, item deposit, fuel burn, and proximity proof can be combined across actions.
- **New module support**: new behavior can be added as a module instead of creating a new assembly type.
- **Programmability**: all programmable actions use the same request and requirement flow.

What becomes harder:

- PTB construction must understand requirement order and handler discovery.
- Requirement data must be carefully designed because it is stored as BCS bytes.
- Module names become part of action configuration, so naming and owner/admin controls matter.

The main trade-off is intentional: complexity moves out of predefined assembly modules and into explicit action configuration, request construction, and requirement satisfaction.
