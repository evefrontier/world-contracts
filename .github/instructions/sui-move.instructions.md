---
description: "Guidelines for building Sui Move contracts (modular Entity/Module/Action/Request/Requirement architecture)"
applyTo: "**/*.move"
---

# Sui Move Code Guidelines

Conventions for the modular **Entity / Module / Action / Request / Requirement**
architecture. These mirror `CLAUDE.md` and `.cursor/rules/move-conventions.mdc` — keep all
three in sync. Follow the official
[Sui Move Conventions](https://docs.sui.io/concepts/sui-move-concepts/conventions) and the
[Move Book code-quality checklist](https://move-book.com/guides/code-quality-checklist).

> **Scope:** Live code is in `contracts/core/sources/` (modules `core::entity`, `core::mod`,
> `core::action`, `core::request`, `core::requirement`, …). Everything under
> `contracts/archive/` (the legacy `world::` assembly model — `StorageUnit`, `assemblies/`,
> `primitives/`, `GovernorCap`/`AdminACL`/`OwnerCap`) is **deprecated**. Do not copy its
> patterns into new code.

## Architecture in one minute

- `Entity` — base shared object (a ship or structure). Stays small; modules and actions are
  stored as **dynamic fields** keyed by typed key structs, so installing behavior never
  changes the `Entity` type.
- `Module<T>` — typed module state installed on an entity under a human-readable name.
- `Action` — a named, ordered list of `Requirement`s exposed by an entity.
- `Request` — a transaction-scoped, **abilities-free hot potato** created when an action
  starts; must be completed in the same tx.
- `Requirement` — a typed rule instance; the `TypeName` identifies the handler, an optional
  `name` targets a module, and `data` is BCS-encoded config.

See [`docs/architechture-v1.md`](../../docs/architechture-v1.md) for the full design.

## Function Organization Order

Every module **must** use `// === Section ===` headers and lay out declarations in this exact
order (omit empty sections):

```move
// === Errors ===            // E + PascalCase
// === Constants ===         // SCREAMING_SNAKE (VERSION, ...)
// === Structs ===           // key/positional-key structs, then main type
// === Events ===            // past-tense names (UserRegistered)
// === Public Functions ===  // constructors + mutating entry points
// === View Functions ===    // getters: name() / name_mut(), no get_ prefix
// === Admin Functions ===   // cap/ACL-gated mutations
// === Package Functions === // public(package)
// === Private Functions ===
// === Init ===              // fun init, if any
// === Test Functions ===    // #[test_only], at the bottom
```

Within a signature, **objects first, capabilities second**, then plain args, with `&Clock` /
`&mut TxContext` last:

```move
public fun call(app: &mut App, cap: &AdminCap, value: u64, ctx: &mut TxContext)
```

**Review Checklist:**

- [ ] Are declarations grouped under `// === Section ===` headers in the order above?
- [ ] Do signatures put objects first, capabilities second, `ctx`/`&Clock` last?
- [ ] Are `#[test_only]` functions at the bottom?

## Naming Conventions

- **Modules**: `snake_case` (e.g. `entity`, `location_service`, `owner_service`).
- **Structs**: `PascalCase` (e.g. `Entity`, `Module`, `Requirement`, `OwnerCap`).
- **Functions / variables**: `snake_case`.
- **Constants**: `SCREAMING_SNAKE_CASE` (e.g. `VERSION`).
- **Error constants**: `E` + PascalCase (e.g. `EWrongVersion`, `EModuleMissing`). Pick this
  one style — do **not** use `E_SCREAMING_SNAKE`.

## Error Handling

Define plain `u64` error constants in the `// === Errors ===` section, numbered from 0, and
assert with a named constant — never a bare `abort` or unnamed `assert!`:

```move
// === Errors ===

const EWrongVersion: u64 = 0;
const ENotLocked: u64 = 1;
const EModuleMissing: u64 = 6;
```

```move
// Good
assert!(entity.version == VERSION, EWrongVersion);
assert!(df::exists_with_type<_, Module<T>>(&entity.id, ModuleKey(name)), EModuleMissing);

// Avoid — no named error
assert!(entity.version == VERSION);
```

**Review Checklist:**

- [ ] Are error constants `E` + PascalCase, typed `u64`, and defined in `// === Errors ===`?
- [ ] Are codes unique within the module?
- [ ] Do all `assert!` calls use a named error constant (no bare `abort`)?

## Versioning

Every persisted type carries a `const VERSION` plus a `version: u64` field, asserted on entry.
Modules pass their **own** `VERSION` at install time so they can upgrade independently of
`core`.

```move
const VERSION: u64 = 1;
assert!(entity.version == VERSION, EWrongVersion);
```

**Review Checklist:**

- [ ] Does every persisted struct carry a `version` field and a module `VERSION` constant?
- [ ] Do mutating entry points assert `version == VERSION` first?

## Field Getters

Every struct field **must** have a getter in `// === View Functions ===`. Name it after the
field (no `get_` prefix); return a copy for primitives and a `&` reference otherwise. Add a
`_mut` variant only when callers legitimately mutate. Keep getters even if unused — they are
the module's read API and keep fields private.

```move
public fun version<T: store>(m: &Module<T>): u64 { m.version }   // primitive: by value
public fun name<T: store>(m: &Module<T>): String { m.name }
public fun inner<T: store>(m: &Module<T>): &T { &m.inner }       // non-primitive: by ref
public fun inner_mut<T: store>(m: &mut Module<T>): &mut T { &mut m.inner }
```

Exempt: the `id: UID` field (callers use `object::id`), positional key/witness structs, and
transient hot-potato internals (e.g. `Request`/`Frame` fields that must stay opaque).

**Review Checklist:**

- [ ] Does every non-exempt field have a getter named after the field (no `get_`)?
- [ ] Are primitives returned by value and non-primitives by `&`?
- [ ] Are `_mut` getters added only where mutation is legitimate?

## Entity & Dynamic Fields

Keep `Entity` small; store modules/actions as dynamic fields keyed by **typed key structs**,
so adding a module never changes the `Entity` type.

```move
public struct ModuleKey(String) has copy, drop, store;
public struct ActionsKey() has copy, drop, store;
// df: ModuleKey(name) => Module<T>,  ActionsKey() => VecMap<String, Action>
```

**Review Checklist:**

- [ ] Are extension data and modules stored as dynamic fields, not new `Entity` fields?
- [ ] Are dynamic-field keys typed key structs (not raw strings/ids)?
- [ ] Is `df::exists_`/`exists_with_type` checked before borrowing optional fields?

## Hot-potato Request / Frame

`Request` and `Frame` have **no abilities** — they cannot be stored, copied, or dropped, so a
tx that starts an action must finish it. Constructors are `public(package)`; only `core::entity`
mints/consumes a `Request`. A `Request` completes only when **every** requirement is satisfied.
Requirements are stored reversed so `pop_back` yields declaration order.

```move
public(package) fun complete(request: Request) {
    let Request { requires, .. } = request;
    assert!(requires.length() == 0, ERequestNotComplete);
}
```

**Review Checklist:**

- [ ] Do `Request`/`Frame` declare no abilities?
- [ ] Are their constructors `public(package)`?
- [ ] Does every entry point that creates a `Request` force the caller to complete it?

## Witness + `internal::Permit<T>` Authorization

Authorization is **type-driven, not argument-driven**. A requirement of type `T` can only be
satisfied by the module that defines `T`, proven with the package-private `internal::Permit<T>`.
Module *identity* is enforced via the next requirement's `name`, read inside
`entity::module_mut` — **never** trust a name passed as a handler argument.

```move
public struct Owner(ID) has drop;            // witness owned by this module

public fun verify_owner_cap(request: &mut Request) {
    let (requirement, frame) = request.take_next(internal::permit<Owner>());
    // enforce requirement.data() before mutating, then:
    frame.destroy_empty_frame(); // or request.enqueue(frame) to add follow-ups
}
```

```move
// module_mut reads the target module name off the request, not the caller's args
let name = req.next().module_name().destroy_or!(abort ERequirementNotModuleScoped);
df::borrow_mut(&mut entity.id, ModuleKey(name))
```

**Review Checklist:**

- [ ] Is authorization proven by type (`Permit<T>` / witness), not by a string/id argument?
- [ ] Does the handler enforce `requirement.data()` before mutating state?
- [ ] Is the target module name read from the requirement, never from handler arguments?

## Requirements as BCS Config

Requirement config is BCS bytes; the **type identity carries the meaning**. Build with
`requirement::from_config` and decode with a symmetric `peel_*` parser mirroring field order.
Type identity uses `type_name::with_original_ids<T>()` for stability across upgrades.

```move
public struct Deposit(ItemRequirement) has drop;
requirement::from_config(option::some(module_name), Deposit(rule)); // encode
let req = parse_bcs_requirement(requirement.data());                // decode (mirror field order)
```

**Review Checklist:**

- [ ] Is config encoded via `requirement::from_config` and decoded with a matching parser?
- [ ] Does the decode mirror the encode field order exactly?
- [ ] Is type identity established with `type_name::with_original_ids<T>()`?

## Handlers & PTB Templates

Behavior lives in module/service handlers (`deposit`, `verify_owner_cap`) that `take_next<T>`,
enforce the decoded config, then mutate. Pair each with a `*_template` that emits the
`ptb::move_call` for client discovery (referencing the package by MVR name, e.g.
`mvr:@frontier/inventory`).

**Review Checklist:**

- [ ] Does each handler `take_next<T>`, enforce config, then mutate — in that order?
- [ ] Is there a matching `*_template` for client PTB discovery?

## Prefer Move Macros

Use stdlib macros over manual loops/branches when one fits — clearer and less error-prone.
Common ones: `map_ref!`, `map!`, `do!`, `destroy!`, `destroy_or!`, `is_some_and!`,
`peel_option!`.

```move
// Good — declarative
request::new(entity_id, action.requirements.map_ref!(|r| r.clone()));
req.entity_id().do!(|id| assert!(id == e.id.to_inner(), EWrongEntity));
```

## Receiver & Index Syntax

```move
// Receiver syntax for method calls
entity.complete_request(req);
e.has_module(name);

// Index syntax for collections
let value = &vec_map[&key];   // not vec_map::get(&vec_map, &key)
```

## Documentation Requirements

Follow the Sui/Move docgen convention so `sui move build --doc` produces clean docs.

- **`///` = published docs**, `//` = internal notes.
- **Module-level**: every module starts with a `///` block explaining what it is and its key
  concepts (see `contracts/core/sources/entity.move` lines 1-11).
- **Function-level**: a short `///` line on public functions stating intent, not mechanics.
- **Explain the non-obvious**: a brief `//` for a tricky macro or invariant (the *why*).
- **Keep docgen happy**: balance all backticks in `///` comments — an unmatched backtick makes
  `sui move build --doc` panic.

**Review Checklist:**

- [ ] Does every module start with a `///` doc block?
- [ ] Do public functions/structs/fields have `///` comments?
- [ ] Are backticks balanced in all `///` comments?

## Imports

Group all `use` declarations at the top of the module — no inline imports.

## What NOT to Review

Do not flag issues handled by automated tooling:

- Code formatting (handled by `sui move fmt`)
- Unused imports / unused variables (handled by Move compiler warnings)

Focus on logic, architecture, authorization, and the invariants above rather than style.

## Adding New Behavior

Adding behavior should usually mean **installing a module, adding a handler, or exposing a new
action** — not changing the base `Entity` type.

1. **New module behavior** → add a `Module<T>` type and an `install`-time `Permit<T>`; store it
   under a name via dynamic fields.
2. **New rule** → add a `Requirement` type + its BCS config, a handler that `take_next<T>` and
   enforces it, and a `*_template`.
3. **New action** → expose it with `entity::enable_action`, composing existing requirements.
4. **Layout/interface change** → introduce a V2 module type, install it, migrate state,
   deprecate the old module name (see the upgrade strategy in
   [`docs/architechture-v1.md`](../../docs/architechture-v1.md)).

## Key Files to Reference

- `contracts/core/sources/entity.move` — `Entity`, install/uninstall, actions, `module_mut`
- `contracts/core/sources/request.move` — hot-potato `Request` / `Frame`
- `contracts/core/sources/requirement.move` — typed BCS requirements
- `contracts/core/sources/mod.move` — `Module<T>` wrapper
- `contracts/core/sources/action.move` — `Action`
- `docs/architechture-v1.md` — full architecture and rationale
