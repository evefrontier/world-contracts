---
description: "Testing patterns and standards for Sui Move contracts"
applyTo: "**/tests/*.move"
---

# Sui Move Testing Guidelines

Testing patterns for the modular **Entity / Module / Action / Request / Requirement**
architecture. Live tests are in `contracts/core/tests/` (e.g. `entity_tests.move`,
`object_registry_tests.move`). Tests under `contracts/archive/` belong to the deprecated
`world::` assembly model — do not use them as templates.

## Official Conventions

Follow the [Move Book code-quality checklist](https://move-book.com/guides/code-quality-checklist):

- **Do not prefix test functions with `test_`** — the `_tests` module suffix already says so.
- **Do not add cleanup to `expected_failure` tests** — the test aborts first, so cleanup is
  dead code and noise.

## Test Module Declaration

Test modules live beside the package code under `tests/`, are named `<module>_tests`, and use
the package address (`core::`, not `world::`):

```move
#[test_only]
module core::entity_tests;

use core::{action, entity, object_registry::{Self, ObjectRegistry}};
use std::string;
use sui::test_scenario as ts;
```

## Test Scenario Pattern

Use `sui::test_scenario`. Initialize shared objects with the module's `init_for_testing`, then
drive transactions with `ts::next_tx`. Prefer small local helpers for repeated setup:

```move
const TENANT: vector<u8> = b"test";

fun setup(scenario: &mut ts::Scenario) {
    object_registry::init_for_testing(scenario.ctx());
}

fun take_registry(scenario: &ts::Scenario): ObjectRegistry {
    ts::take_shared<ObjectRegistry>(scenario)
}

#[test]
fun install_adds_module() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let mut e = entity::new(&mut registry, 1, string::utf8(TENANT), vector[]);
    let ctx = scenario.ctx();

    // Lifecycle ops return a Request that must be completed in the same tx.
    let req = e.install(string::utf8(b"counter"), Counter { value: 0 }, 1, internal::permit<Counter>(), ctx);
    e.complete_request(req);

    assert!(e.has_module(string::utf8(b"counter")));

    entity::share(e);
    ts::return_shared(registry);
    scenario.end();
}
```

Note: a `Request` is a hot potato, so every lifecycle call (`install`, `uninstall`,
`enable_action`, `interact`, …) must be paired with `e.complete_request(req)` before the
entity is shared or returned.

## Expected Failure Tests

Use the combined `#[test, expected_failure(...)]` attribute and reference the named error
constant. End the test with `abort` and add **no** cleanup — the test aborts at the failing
call:

```move
#[test, expected_failure(abort_code = entity::EIdEmpty)]
fun new_zero_id_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let _e = entity::new(&mut registry, 0, string::utf8(TENANT), vector[]);

    abort
}
```

## Test Organization

Group tests under `// === Section ===` headers by behavior (mirroring the source), not by
success/failure:

```move
// === Construction ===

#[test]
fun new_sets_initial_fields() { /* ... */ }

#[test, expected_failure(abort_code = entity::EIdEmpty)]
fun new_zero_id_aborts() { /* ... */ }

// === Modules ===

#[test]
fun install_adds_module() { /* ... */ }

#[test, expected_failure(abort_code = entity::EModuleExists)]
fun install_duplicate_module_aborts() { /* ... */ }
```

## Review Checklist

**Coverage:**

- [ ] Are tests present for all public functions?
- [ ] Do tests cover both success and failure paths?
- [ ] Is there an `expected_failure` test for each named error constant?

**Conventions:**

- [ ] Are test functions named descriptively, with **no** `test_` prefix?
- [ ] Do `expected_failure` tests use the combined `#[test, expected_failure(...)]` form and
      reference the named error constant?
- [ ] Are `expected_failure` tests free of cleanup code (ending in `abort`)?
- [ ] Is repeated setup factored into local helpers (or a `test_helpers` module)?

**Cleanup (success tests only):**

- [ ] Are shared objects returned with `ts::return_shared()`?
- [ ] Are owned objects returned with `ts::return_to_sender()`?
- [ ] Are entities/requests resolved (`complete_request`) and the scenario ended with
      `scenario.end()`?

## Issues to Flag

- Missing failure tests for error conditions.
- `test_`-prefixed function names (redundant in `_tests` modules).
- Cleanup code in `expected_failure` tests.
- A lifecycle call whose returned `Request` is never completed.

## Key Files to Reference

- `contracts/core/tests/entity_tests.move` — full lifecycle test example
- `contracts/core/tests/object_registry_tests.move` — registry/shared-object patterns
- `contracts/core/tests/entity_key_tests.move` — pure-function unit tests
