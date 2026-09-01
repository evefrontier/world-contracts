# Move Conventions

**Authoritative** conventions for the modular **Entity / Module / Action / Request /
Requirement** architecture. This is the single source of truth — `CLAUDE.md`,
`.cursor/rules/`, and `.github/instructions/` all point here, so edit conventions **here** and
nowhere else.

Follows the official [Sui Move Conventions](https://docs.sui.io/concepts/sui-move-concepts/conventions)
and the [Move Book code-quality checklist](https://move-book.com/guides/code-quality-checklist).

> **Scope.** Live code is in `contracts/core/sources/`. Everything under `contracts/archive/`
> is the deprecated `world::` assembly model (`StorageUnit`, `assemblies/`, `primitives/`,
> `GovernorCap`/`AdminACL`/`OwnerCap`) — do not copy its patterns into new code. See
> [`docs/adr/0002-modular-architecture.md`](adr/0002-modular-architecture.md) for the design.

## Production guardrails (non-negotiable)

- No bare `abort` in production code. Every `assert!` takes a named error constant:
  `assert!(e.version == VERSION, EWrongVersion);` (the one exception is the `abort` that ends an
  `expected_failure` test — see [Testing](#testing).)
- Error constants are `E` + PascalCase with an `#[error(code = N)]` attribute and a `vector<u8>`
  message — never `E_SCREAMING_SNAKE`. See [Error handling](#error-handling).
- Keep modules small and single-purpose — compose behavior, don't grow god-modules.
- Adding behavior should mean **installing a module, adding a handler, or exposing an action** —
  not changing the base `Entity` type.

## Naming

- Modules: `snake_case` (`entity`, `location_service`, `owner_service`).
- Structs: `PascalCase` (`Entity`, `Module`, `Requirement`, `OwnerCap`).
- Functions / variables: `snake_case`. Constants: `SCREAMING_SNAKE_CASE` (`VERSION`).
- Error constants: `E` + PascalCase (`EWrongVersion`, `EModuleMissing`).

## Module layout & function order

Every module **must** use `// === Section ===` header comments and lay out declarations in
this exact order (omit a section if empty):

```move
// === Errors ===            // E + PascalCase
// === Constants ===         // SCREAMING_SNAKE (VERSION, ...)
// === Structs ===           // key/positional-key structs, then main type
// === Events ===            // past-tense names (UserRegistered)
// === Init ===              // fun init — the FIRST function, if present
// === Public Functions ===  // constructors + mutating entry points
// === View Functions ===    // getters: name() / name_mut(), no get_ prefix
// === Admin Functions ===   // cap/ACL-gated mutations
// === Package Functions === // public(package)
// === Private Functions ===
// === Test Functions ===    // #[test_only], at the bottom
```

Per [Sui's Move best practices](https://docs.sui.io/concepts/sui-move-concepts/conventions),
`init` is the **first function** in the module when present — placed right after `Structs` /
`Events`, before `Public Functions` (see `contracts/core/sources/object_registry.move`). Not at
the bottom.

Within a function signature, **objects go first, capabilities second**, then plain args, with
`&Clock` / `&mut TxContext` last:

```move
public fun call(app: &mut App, cap: &AdminCap, value: u64, ctx: &mut TxContext)
```

## Error handling

Define error constants in `// === Errors ===` using the `#[error]` attribute with a sequential,
unique `code`, a `vector<u8>` message, and assert with the named constant:

```move
// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Entity version does not match the package version";
#[error(code = 1)]
const ENotLocked: vector<u8> = b"Entity is not locked";
#[error(code = 2)]
const EWrongEntity: vector<u8> = b"Module does not belong to this entity";
```

```move
// Good
assert!(entity.version == VERSION, EWrongVersion);

// Avoid — no named error
assert!(entity.version == VERSION, 1);
```

The message is surfaced on abort and parsed by the error-decoder tool; the numeric `code` stays
unique within the module.

## Field getters

Every struct field **must** have a **read-only** getter in `// === View Functions ===`:

- **Read-only return.** Getters never expose mutable access — return copyable types (scalars,
  and small copy types like `String` / `ID`) by value, everything else by **immutable `&`
  reference**. No `_mut` getters. Mutable access, when genuinely needed (e.g. `mod::inner_mut`
  for handlers), is a deliberate, separately-justified accessor — not a default getter, and not
  part of this rule.
- **Naming.** Match the field name, no `get_` prefix.
- Keep getters even if currently unused — they are the module's read API and keep fields private.

Exempt: the `id: UID` field (callers use `object::id`), positional key/witness structs, and
transient hot-potato internals (e.g. `Request`/`Frame` fields that must stay opaque).

```move
public struct Module<T: store> has store { version: u64, inner: T, name: String }

public fun version<T: store>(m: &Module<T>): u64 { m.version }   // copyable scalar: by value
public fun name<T: store>(m: &Module<T>): String { m.name }      // copyable String: by value
public fun inner<T: store>(m: &Module<T>): &T { &m.inner }       // everything else: immutable &
```

## Hot-potato Request / Frame

`Request` and `Frame` have **no abilities** — they cannot be stored, copied, or dropped, so a
tx that starts an action must finish it. Constructors are `public(package)`; only `core::entity`
mints/consumes a `Request`.

```move
public struct Request { entity_id: Option<ID>, requires: vector<Requirement> }
public(package) fun new(...): Request { ... }
public(package) fun complete(request: Request) {
    let Request { requires, .. } = request;
    assert!(requires.length() == 0, ERequestNotComplete);
}
```

A `Request` completes only when **every** requirement is satisfied. Requirements are stored
reversed so `pop_back` yields declaration order.

## Witness + `internal::Permit<T>` authorization

Authorization is type-driven, not argument-driven. A requirement of type `T` can only be
satisfied by the module that defines `T`, proven with the package-private `internal::Permit<T>`.
Approvals are phantom witnesses (`AdminApproval<phantom T>`).

```move
public struct Owner(ID) has drop;            // witness owned by this module

public fun verify_owner_cap(request: &mut Request) {
    let (requirement, frame) = request.take_next(internal::permit<Owner>());
    // enforce requirement.data() before mutating, then:
    frame.destroy_empty_frame(); // or request.enqueue(frame) to add follow-ups
}
```

Module *identity* is enforced via the next requirement's `module_id`, read inside `entity::module_mut` —

```move
let module_id = req.next().module_id().destroy_or!(abort ERequirementNotModuleScoped);
df::borrow_mut(&mut entity.id, ModuleKey(module_id))
```

## Versioning

Every persisted type carries `const VERSION` + a `version: u64` field, asserted on entry.
Modules pass their own `VERSION` at install time so they can upgrade independently of `core`.

```move
const VERSION: u64 = 1;
assert!(e.version == VERSION, EWrongVersion);
e.install(
    module_id,
    type_id,
    option::none(),
    option::some(b"grid".to_string()),
    Grid { .. },
    VERSION,
    internal::permit(),
    ctx,
);
```

## Entity & dynamic fields

Keep `Entity` small; store modules/actions as dynamic fields keyed by **typed key structs**, so
adding a module never changes the `Entity` type.

```move
public struct ModuleKey(u64) has copy, drop, store;
public struct ActionsKey() has copy, drop, store;
// df: ModuleKey(module_id) => Module<T>,  ActionsKey() => VecMap<String, Action>
// well-known slots: id = first 8 bytes (LE) of blake2b256(name) via mod::id_from_name
```

## Requirements as BCS config

Requirement config is BCS bytes; the type identity carries the meaning. Build with
`requirement::from_config` and decode with a symmetric `peel_*` parser mirroring field order.
Use `type_name::with_original_ids<T>()` for stable type identity.

```move
public struct Deposit(ItemRequirement) has drop;
requirement::from_config(option::some(module_id), Deposit(rule)); // encode
let req = parse_bcs_requirement(requirement.data());                // decode (mirror field order)
```

## Handlers & PTB templates

Behavior lives in module/service handlers (`deposit`, `verify_owner_cap`) that `take_next<T>`,
enforce the decoded config, then mutate. Pair each with a `*_template` that emits the
`ptb::move_call` for client discovery (referencing the package by MVR name, e.g.
`mvr:@frontier/inventory`).

## Prefer Move macros

Use stdlib macros over manual loops/branches when one fits — they're clearer and less
error-prone. Common ones: `map_ref!`, `map!`, `do!`, `destroy!`, `destroy_or!`, `is_some_and!`,
`peel_option!`.

```move
// Good — declarative
request::new(entity_id, action.requirements.map_ref!(|r| r.clone()));
pending.destroy!(|r| request.requires.push_back(r));
req.entity_id().do!(|id| assert!(id == e.id.to_inner(), EWrongEntity));

// Avoid — manual index loop when a macro expresses the intent
```

## Receiver & index syntax

```move
entity.complete_request(req);   // receiver syntax for method calls
let value = &vec_map[&key];      // index syntax, not vec_map::get(&vec_map, &key)
```

## Comments

Follow the Sui/Move docgen convention so `sui move build --doc` produces clean, publishable
docs.

- **`///` = published docs**, `//` = internal notes.
- **Module-level**: every module starts with a `///` block explaining what it is and its key
  concepts (see `contracts/core/sources/entity.move` lines 1-11).
- **Function-level**: a short `///` line on public functions stating intent, not mechanics.
- **Explain the non-obvious**: a brief `//` for a tricky macro or invariant (the *why*).
- **Keep docgen happy**: balance all backticks in `///` comments — an unmatched backtick makes
  `sui move build --doc` panic.

## Imports

Group all `use` declarations at the top of the module — no inline imports.

## Testing

Live tests are in `contracts/core/tests/` (e.g. `entity_tests.move`). Follow the
[Move Book code-quality checklist](https://move-book.com/guides/code-quality-checklist):

- Test modules are named `<module>_tests` and use the package address (`core::`, not `world::`).
- **Do not** prefix test functions with `test_` — the `_tests` suffix already says so.
- Use the combined `#[test, expected_failure(abort_code = entity::EIdEmpty)]` form, reference
  the named error constant, and end the body with `abort` — **no cleanup** (the test aborts
  first).
- A `Request` is a hot potato: every lifecycle call (`install`, `enable_action`, `interact`, …)
  must be paired with `e.complete_request(req)` before the entity is shared or returned.
- Factor repeated setup into local helpers; initialize shared objects with `init_for_testing`.
- Success tests clean up: `ts::return_shared` / `ts::return_to_sender`, then `scenario.end()`.

```move
#[test, expected_failure(abort_code = entity::EIdEmpty)]
fun new_zero_id_aborts() {
    let mut scenario = ts::begin(@0xA);
    object_registry::init_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let _e = entity::new(&mut registry, 0, string::utf8(b"test"), vector[]);

    abort
}
```

## Review checklist

**Layout & naming**

- [ ] Declarations grouped under `// === Section ===` headers in the canonical order?
- [ ] Signatures put objects first, capabilities second, `ctx`/`&Clock` last?
- [ ] Error constants `E` + PascalCase, `u64`, defined in `// === Errors ===`, codes unique?
- [ ] Every non-exempt field has a getter named after it (no `get_`)?

**Architecture & safety**

- [ ] Authorization proven by type (`Permit<T>` / witness), not a string/id argument?
- [ ] Target module name read from the requirement, never from handler arguments?
- [ ] Handlers `take_next<T>` → enforce `requirement.data()` → mutate, in that order?
- [ ] Every persisted struct asserts `version == VERSION` on entry?
- [ ] Extension data stored as dynamic fields with typed keys, not new `Entity` fields?
- [ ] `Request`/`Frame` declare no abilities; constructors `public(package)`?
- [ ] BCS decode mirrors encode field order exactly?

**Docs & tests**

- [ ] Every module and public function/struct has `///` docs; backticks balanced?
- [ ] Success and failure paths tested; an `expected_failure` per named error?
- [ ] `expected_failure` tests free of cleanup; no `test_` prefixes?

## What NOT to review

Do not flag issues handled by tooling: code formatting (`sui move fmt`), unused imports/
variables (Move compiler warnings). Focus on logic, architecture, authorization, and the
invariants above.

## Key files

- `contracts/core/sources/entity.move` — `Entity`, install/uninstall, actions, `module_mut`
- `contracts/core/sources/request.move` — hot-potato `Request` / `Frame`
- `contracts/core/sources/requirement.move` — typed BCS requirements
- `contracts/core/sources/mod.move` — `Module<T>` wrapper
- `contracts/core/sources/action.move` — `Action`
- `contracts/core/tests/entity_tests.move` — full lifecycle test example
- [`docs/adr/0002-modular-architecture.md`](adr/0002-modular-architecture.md) — design & rationale
- [`CONTEXT.md`](../CONTEXT.md) — domain glossary (term → file → invariant)
