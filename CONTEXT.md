<!-- NOT FINAL SHOULD WE  UPDATED AS WE PROGRESS -->
# Domain Model — world-contracts

The shared vocabulary for this repo. When code, docs, plans, or conversations use a term
below, this file is what it means. Terminology here **wins** — if a design uses a different
word for one of these concepts, rename it to match.

- **Decisions & rationale** live in [`docs/adr/`](docs/adr/).
- **The v1 modular design** is fixed in [ADR-0002](docs/adr/0002-modular-architecture.md).
- **Coding conventions** are in [`docs/move-conventions.md`](docs/move-conventions.md).

---

## The architecture in one sentence

A small base **Entity** installs typed **Component**s and exposes named **Action**s; interacting
with an action mints a hot-potato **Request** carrying an ordered list of **Requirement**s that
component handlers must satisfy one at a time before the request can complete.

One `Entity` type. Character, ship, gate, and storage unit differ only by installed
components. Those bags are **siblings**, Inventory is not nested inside Creation.

```
Entity
  Component<Identity>        who this is (not a game fitting)
  Component<Creation>        kind of thing (ship / gate / …) 
  Component<Inventory>       game module (player-facing fitting)
  Component<PowerNetwork>    game module
  Component<KillMail>        optional record bag (not a fitting)
```

```
Character entity = Entity + Identity   (+ Inventory, KillMail, … later)
Creation entity  = Entity + Creation   + Inventory + PowerNetwork + …
Tribe entity     = Entity + …          (Principal / AccessCaps)
```

Do **not** write `Component<Character>`. Character **is** the entity; put
`Component<Identity>` on it.

## Core concepts

These five are the load-bearing nouns of v1. All live in [`contracts/core/sources/`](contracts/core/sources/).

- **Entity** — the base shared object ([`entity.move`](contracts/core/sources/entity.move)).
  Stays small; stores installed components and exposed actions as **dynamic fields** rather than
  fixed struct fields, so new behavior never changes the base type. Created/claimed
  deterministically from the `ObjectRegistry`. A single Entity type plays one of two **roles**,
  not a fixed sub-type:
  - **Structure** (Creation) — a spatial Entity (gate, storage unit, turret, ship). Components
    define behavior; location is supplied at interact time, not stored on the Entity.
  - **Principal** — an Entity that represents an account-like actor and **owns AccessCaps**
    (a Character or a Tribe). See **Keychain**.
- **Component** — typed state installed on an Entity
  ([`component.move`](contracts/core/sources/component.move)). `Component<T>` wraps a
  user-defined state `T` (e.g. `Component<Inventory>`, `Component<Identity>`) under a
  caller-supplied `u64`, so one Entity can host several components, even of the same type.
  An optional display `name` may be stored on the wrapper; it is not unique and is not used
  for targeting. Well-known singletons (identity, metadata) derive their id as the first 8
  bytes (LE) of `blake2b256(name)`.
  A **game module** is a player-facing component (Inventory, Power). Not every component is
  a game module — Identity is a component and is not a fitting.
  `Component<T>` is ECS-like data only. Behavior is Action / Request / Requirement /
  handler, not an ECS System. Several instances of the same `T` can share one entity
  (storage 01 and 02), keyed by `component_id`.
- **Action** — a named, ordered list of Requirements an Entity exposes
  ([`action.move`](contracts/core/sources/action.move)). It carries no logic of its own; it
  only describes what must be satisfied. (Stored reversed internally so `pop_back` yields
  declaration order.)
- **Request** — the transaction-scoped checklist for one action invocation
  ([`request.move`](contracts/core/sources/request.move)). A **hot potato**: no `copy`/`drop`/
  `store`, so once `interact` mints it the transaction *must* satisfy every requirement and
  `complete` it. A **Frame** is the helper that lets a handler `enqueue` *new* requirements
  mid-transaction (dynamic follow-ups).
- **Requirement** — a single typed rule instance on an Action
  ([`requirement.move`](contracts/core/sources/requirement.move)). Carries `type_name` (which
  handler may satisfy it, e.g. `inventory::Deposit`), an optional component `u64` id (which
  installed component it targets), and `data` (BCS-encoded config). Handlers prove ownership of the rule type
  via a package-private `internal::Permit<T>`.

### How they interact (the invariant)

> An action completes **only when every requirement has been satisfied.**

1. Owner/admin creates an Entity and installs admin-approved Components.
2. Owner exposes Actions, each an ordered list of Requirements.
3. A user `interact`s with an action → mints a `Request`.
4. The PTB calls each component handler in order; each `take_next<T>` (aka `satisfy<T>`) pops and
   discharges its requirement.
5. `complete_request` succeeds only when zero requirements remain.

## Supporting infrastructure (core)

- **EntityKey** — deterministic identifier `(id: u64, tenant: String)` used to derive an
  Entity's on-chain object ID ([`entity_key.move`](contracts/core/sources/entity_key.move)).
  Maps an in-game ID to exactly one on-chain object.
- **ObjectRegistry** — shared object that derives and tracks Entity object IDs, guaranteeing one
  on-chain object per `EntityKey` ([`object_registry.move`](contracts/core/sources/object_registry.move)).
- **Location service / Proximity** — `interact` injects a `Proximity` requirement carrying the
  target location hash. The caller satisfies it with `verify_proximity` by supplying their
  caller location hash (player, or the ship/structure they are boarded on). v1 is an exact match
  ([`services/location_service.move`](contracts/core/sources/services/location_service.move)).

## Installed components

Concrete `T` values installed on Entities. Migrated from the legacy assembly model.

- **Character / Identity** — the player-character entity and its identity component
  ([`contracts/character/`](contracts/character/)). Not a game module; it is who the entity is.
- **Inventory / storage** — a game-module component
  ([`contracts/inventory/`](contracts/inventory/)).
- **Generic module** — opaque in-game module (thruster, turret, …) with no handler yet.
  Stored as `Component<GenericModule>`
  ([`generic_module.move`](contracts/core/sources/generic_module.move)).
- *Planned:* Access control, Fuel, Power, Transport, Weapon, Creation tag, KillMail.
  Each is a component type with its own Requirement types, handlers, and PTB templates.
  Player-facing fittings are game modules; the rest are still just components.

## Client integration

- **PTB template** — a per-handler function (mirroring each Move handler, e.g.
  `inventory::deposit_template`) that emits the move-call needed to satisfy one requirement.
  Clients inspect an action's requirements, map each to its template, and assemble a PTB in
  order, ending with `complete_request`. This keeps the Move contracts authoritative while SDKs
  automate transaction construction. (See ADR-0002 §"Client And PTB Discovery".)

## Terms to keep straight

- **core / v1** — the live modular architecture under [`contracts/core/`](contracts/core/). Start here.
- **archive** — the deprecated, assembly-first `world::` model under
  [`contracts/archive/`](contracts/archive/). Reference only; **do not copy** its patterns
  (`StorageUnit`, `assemblies/`, `primitives/`, `GovernorCap`/`AdminACL`/`OwnerCap`).
- **assembly model** — the old design where each structure type owned its object shape and a
  fixed API. Superseded by the Entity/Component/Action/Request/Requirement model
  ([ADR-0001](docs/adr/0001-assembly-architecture.md) → [ADR-0002](docs/adr/0002-modular-architecture.md)).
- **handler** — the Move function that satisfies a requirement of a given type.
- **game module** — in-game fitting (storage, power, weapon). On-chain it is a Component.
  Do not confuse with a Move `module` (`module core::entity`) or with `Component<Identity>`.
- **Character / Creation** — roles (which bags you expect), not parent object types.
  Same as **Principal** vs **Structure** above.
- **hot potato** — a struct with no abilities that must be consumed in the same transaction; the
  `Request` is one.
- **tenant** — the multi-tenancy partition carried in an `EntityKey`.
- **MVR** — Move Registry; how published packages are referenced by name per environment
  (e.g. `@evefrontier/world-core`). See [`docs/v1/`](docs/v1/) for the publishing plan.
