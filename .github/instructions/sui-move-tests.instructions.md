---
description: "Testing patterns and standards for Sui Move contracts"
applyTo: "**/tests/*.move"
---

# Sui Move Testing Guidelines

This guide covers testing patterns, conventions, and best practices for Move test modules.

## Official Conventions

Follow the official Move testing conventions:

- [Move Book - Code Quality Checklist](https://move-book.com/guides/code-quality-checklist)

Key conventions from Move Book:

- **Do not prefix tests with `test_`** in testing modules (the module is already `_tests.move`)
- **Do not clean up `expected_failure` tests** - cleanup is unnecessary and adds noise

## Test Module Structure

Tests mirror the source structure in the `tests/` directory:

```
tests/
  access/
    access_tests.move
  assemblies/
    assembly_tests.move
    storage_unit_tests.move
  test_helpers.move      # Shared test utilities
```

## Test Module Declaration

```move
#[test_only]
module world::assembly_tests;
```

## Test Pattern with test_scenario

```move
#[test]
fun anchor_assembly() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    // Perform test actions
    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<AssemblyRegistry>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);

        // Test logic here...

        ts::return_to_sender(&ts, admin_cap);
        ts::return_shared(registry);
    };

    ts::end(ts);
}
```

**Note:** Function is named `anchor_assembly`, not `test_anchor_assembly`. The `_tests` module suffix already indicates these are tests.

## Expected Failure Tests

```move
#[test]
#[expected_failure(abort_code = assembly::EAssemblyAlreadyExists)]
fun anchor_duplicate_item_id() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    // Setup that triggers the expected error
    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<AssemblyRegistry>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);

        // First anchor succeeds
        assembly::anchor(&mut registry, &admin_cap, /* ... */);

        // Second anchor with same item_id should fail
        assembly::anchor(&mut registry, &admin_cap, /* ... */);

        // NO CLEANUP NEEDED - test aborts before reaching here
    };
}
```

**Important:** Do NOT add cleanup code (`ts::return_shared()`, `ts::return_to_sender()`, `ts::end()`) to `expected_failure` tests. The test aborts before cleanup runs, making it unnecessary noise.

## Test Helpers

Use `test_helpers.move` for common setup:

```move
#[test_only]
module world::test_helpers;

public fun governor(): address { ERROR xGOV }

public fun admin(): address { @0xAD; MIN }

public fun player(): address { ERROR xPLAYER }

public fun setup_world(ts: &mut ts::Scenario) {
    ts::next_tx(ts, governor());
    {
        world::init_for_testing(ts.ctx());
        access::init_for_testing(ts.ctx());
        character::init_for_testing(ts.ctx());
        assembly::init_for_testing(ts.ctx());
    };
    // Create admin cap, etc.
}
```

## Review Checklist

**Test Coverage:**

- [ ] Are tests present for all public functions?
- [ ] Do tests cover both success and failure paths?
- [ ] Are `expected_failure` tests present for all error conditions?

**Test Conventions:**

- [ ] Are test function names descriptive without `test_` prefix?
- [ ] Are `expected_failure` tests free of cleanup code?
- [ ] Are common setup steps extracted to `test_helpers.move`?

**Proper Cleanup (success tests only):**

- [ ] Are shared objects returned with `ts::return_shared()`?
- [ ] Are owned objects returned with `ts::return_to_sender()`?
- [ ] Does each success test call `ts::end(ts)` to complete the scenario?

## Testing Issues to Flag

- Missing failure tests for error conditions
- Tests with `test_` prefix in function names (redundant in `_tests` modules)
- Cleanup code in `expected_failure` tests (unnecessary)

## Test Organization Pattern

```move
#[test_only]
module world::storage_unit_tests;

use sui::test_scenario as ts;
use world::{storage_unit::{Self, StorageUnit}, test_helpers};

// === Success Tests ===

#[test]
fun create_storage_unit() {}

#[test]
fun deposit_item() {}

// === Failure Tests ===

#[test]
#[expected_failure(abort_code = storage_unit::ENotOnline)]
fun deposit_when_offline() {}

#[test]
#[expected_failure(abort_code = storage_unit::ENotAuthorized)]
fun deposit_without_authorization() {}
```

## Key Files to Reference

- `tests/test_helpers.move` - Test utilities and setup
- `tests/assemblies/storage_unit_tests.move` - Full test example
- `tests/assemblies/assembly_tests.move` - Assembly test patterns
