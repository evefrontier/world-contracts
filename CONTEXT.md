# CONTEXT — domain glossary

The canonical vocabulary for the modular architecture, mapped to where each concept lives and
the invariant that makes it safe. Read this before changing `contracts/core/`. For the *why*,
see [`docs/adr/0002-modular-architecture.md`](docs/adr/0002-modular-architecture.md); for *how
to write the code*, see [`docs/move-conventions.md`](docs/move-conventions.md).

> Live code is `contracts/core/`. `contracts/archive/` is the deprecated `world::` assembly
> model — its terms (StorageUnit, assembly, primitive, GovernorCap/AdminACL/OwnerCap) belong to
> [ADR 0001](docs/adr/0001-assembly-architecture.md) and are **not** part of this vocabulary.

## Core types

| Term | What it is | Defined in | Key invariant |
| --- | --- | --- | --- |
| **Entity** | Base shared object — an in-game ship or structure. Stays small; behavior is attached, not baked in. | `sources/entity.move` | Modules and actions live in dynamic fields, so installing behavior never changes the `Entity` type. Asserts `version == VERSION` on entry. |
| **Module&lt;T&gt;** | Typed module state installed on an entity under a human-readable name, plus its own `version`. | `sources/mod.move` | Only `core::entity` can wrap state (`new` is `public(package)`); only `T`'s defining package can `unwrap` it (needs `Permit<T>`). |
| **Action** | A named, ordered list of `Requirement`s exposed by an entity. Executes no logic itself. | `sources/action.move` | Requirements are stored **reversed** so `pop_back` yields declaration order. `to_request` appends pre-requirements that resolve first. |
| **Request** | Transaction-scoped checklist created when an action starts. | `sources/request.move` | **No abilities** (can't be stored/copied/dropped) → the tx that starts it must `complete` it. `complete` aborts unless every requirement is satisfied. |
| **Requirement** | A typed rule instance: `type_name` + optional module `name` + BCS `data`. | `sources/requirement.move` | `type_name` (via `with_original_ids<T>`) decides which handler may satisfy it; `data` is the rule config the handler enforces. |
| **Frame** | Scratch space a handler uses to push **new** requirements mid-resolution. | `sources/request.move` | Abilities-free; must be `enqueue`d back onto the request or `destroy_empty_frame`d. |

## Authorization & identity

| Term | What it is | Defined in | Key invariant |
| --- | --- | --- | --- |
| **Permit&lt;T&gt;** | Package-private capability token proving the caller's package authored `T`. | `std::internal` (used across `core`) | Authorization is **type-driven**: a requirement of type `T` can only be satisfied by code that can mint `Permit<T>`. Never gated on a string/id argument. |
| **`take_next<T>`** | Pops the next requirement, checking its *type* against `T`. | `sources/request.move` | Only checks the requirement **type**. Entity- and module-targeting are enforced separately (below). |
| **`module_mut<T>`** | Borrows the targeted module mid-interaction. | `sources/entity.move` | Reads the target module **name off the next requirement**, not from caller args — so a handler can never mutate the wrong module. Requires the entity be locked. |
| **Handler** | A module/service fn (`deposit`, `verify_owner_cap`) that satisfies one requirement type. | per module | Order: `take_next<T>` → enforce decoded `data` → mutate. |
| **`*_template`** | Companion fn emitting the `ptb::move_call` for a handler, for client PTB discovery. | per module | References packages by **MVR name** (e.g. `mvr:@frontier/inventory`), not raw address. |

## Identity, registry & lifecycle

| Term | What it is | Defined in | Key invariant |
| --- | --- | --- | --- |
| **EntityKey** | In-game identifier (`id` + `tenant`) used to derive an entity's object ID. | `sources/entity_key.move` | `id` is a single global ID space (item ids and type ids assumed never to overlap). |
| **ObjectRegistry** | Shared registry that derives deterministic entity object IDs from an `EntityKey`. | `sources/object_registry.move` | Each in-game ID maps to exactly one on-chain object (`derived_object::claim`); re-claiming the same key aborts. |
| **ModuleKey / ActionsKey / InFlight** | Typed dynamic-field keys: module-by-name, the actions map, and the interaction lock. | `sources/entity.move` | All extension state is keyed by these typed structs, never raw strings. `InFlight` presence = entity locked mid-request. |
| **location_service / proximity** | Injects a proximity requirement on every `interact`. | `sources/services/location_service.move` | v1 = exact match of supplied proof against the entity's stored `location_hash`; real proximity proofs are deferred. |
| **Lifecycle ops** | `install`, `uninstall`, `enable_action`, `disable_action`, `interact`. | `sources/entity.move` | Each **locks** the entity and returns a `Request` the tx must `complete_request` — this is what gates `module_mut` and leaves room for approval requirements. |
| **tenant** | Namespace string scoping in-game IDs. | `sources/entity_key.move` | Must be non-empty; part of the derived object ID. |

## Glossary of supporting terms

- **Hot potato** — a value with no abilities; the type system forces the tx to consume it
  before finishing. `Request` and `Frame` are hot potatoes.
- **BCS config** — a requirement's rule stored as BCS bytes; meaning comes from the
  requirement's `type_name`. Encode with `requirement::from_config`, decode by mirroring the
  field order.
- **MVR name** — Move Registry package alias (`mvr:@frontier/<pkg>`) used in PTB templates so
  clients resolve packages by name, not address.
