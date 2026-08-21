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

A small base **Entity** installs typed **Module**s and exposes named **Action**s; interacting
with an action mints a hot-potato **Request** carrying an ordered list of **Requirement**s that
module handlers must satisfy — one at a time — before the request can complete.

## Core concepts

These five are the load-bearing nouns of v1. All live in [`contracts/core/sources/`](contracts/core/sources/).

- **Entity** — the base shared object ([`entity.move`](contracts/core/sources/entity.move)).
  Stays small; stores installed modules and exposed actions as **dynamic fields** rather than
  fixed struct fields, so new behavior never changes the base type. Created/claimed
  deterministically from the `ObjectRegistry`. A single Entity type plays one of two **roles**,
  not a fixed sub-type:
  - **Structure** — a spatial Entity (gate, storage unit, turret, ship). Modules define
    behavior; location is supplied at interact time, not stored on the Entity.
  - **Principal** — an Entity that represents an account-like actor and **owns AccessCaps**
    (a Character or a Tribe). See **Keychain**.
- **Module** — typed state installed on an Entity ([`mod.move`](contracts/core/sources/mod.move)).
  `Module<T>` wraps a user-defined state `T` (e.g. `Module<Inventory>`) under a caller-supplied
  `u64`, so one Entity can host several modules, even of the same type. An optional display
  `name` may be stored on the wrapper; it is not unique and is not used for targeting.
  Well-known singletons (identity, metadata) derive their id as the first 8 bytes (LE) of
  `blake2b256(name)`.
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
  handler may satisfy it, e.g. `inventory::Deposit`), an optional module `u64` id (which installed
  module it targets), and `data` (BCS-encoded config). Handlers prove ownership of the rule type
  via a package-private `internal::Permit<T>`.

### How they interact (the invariant)

> An action completes **only when every requirement has been satisfied.**

1. Owner/admin creates an Entity and installs admin-approved Modules.
2. Owner exposes Actions, each an ordered list of Requirements.
3. A user `interact`s with an action → mints a `Request`.
4. The PTB calls each module handler in order; each `take_next<T>` (aka `satisfy<T>`) pops and
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

## Game modules

Concrete behavior installed on Entities. These are the things being migrated from the legacy
assembly model into the v1 module shape.

- **Character / Identity** — the player-character entity and its identity module
  ([`contracts/character/`](contracts/character/)). The first game module ported to v1.
- *Planned (not yet built):* Inventory/storage, Access control, Fuel, Power, Transport, Weapon.
  Each becomes a Module type with its own Requirement types, handlers, and PTB templates.

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
  fixed API. Superseded by the Entity/Module/Action/Request/Requirement model
  ([ADR-0001](docs/adr/0001-assembly-architecture.md) → [ADR-0002](docs/adr/0002-modular-architecture.md)).
- **handler** — the Move function in a module that satisfies a requirement of a given type.
- **hot potato** — a struct with no abilities that must be consumed in the same transaction; the
  `Request` is one.
- **tenant** — the multi-tenancy partition carried in an `EntityKey`.
- **MVR** — Move Registry; how published packages are referenced by name per environment
  (e.g. `@evefrontier/world-core`). See [`docs/v1/`](docs/v1/) for the publishing plan.
