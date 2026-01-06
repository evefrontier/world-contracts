# Code Review Guide for World Contracts

This guide provides instructions for agents reviewing code changes in this repository. Focus on architectural patterns, access control, testing, and code quality rather than formatting issues (which are handled by the Move formatter).

## Table of Contents

- [Architecture Patterns](#architecture-patterns)
- [Move Conventions](#move-conventions)
- [Access Control](#access-control)
- [Error Handling](#error-handling)
- [Testing Requirements](#testing-requirements)
- [Events](#events)
- [Object Model](#object-model)
- [Security Considerations](#security-considerations)
- [Documentation Requirements](#documentation-requirements)
- [Common Issues to Flag](#common-issues-to-flag)
- [What NOT to Review](#what-not-to-review)

## Architecture Patterns

### Project Structure

```
contracts/
  world/
    sources/
      access/              # Access control and capabilities
        access_control.move
      assemblies/          # Game-defined assemblies (Layer 2)
        assembly.move
        storage_unit.move
        metadata.move
      character/           # Character management
        character.move
      crypto/              # Cryptographic utilities
        sig_verify.move
      primitives/          # Composable primitives (Layer 1)
        fuel.move
        in_game_id.move
        inventory.move
        location.move
        network_node.move
        status.move
      tokens/              # Token-related modules
      world.move           # Main world module with GovernorCap
    tests/                 # Test modules (mirror source structure)
      access/
      assemblies/
      character/
      crypto/
      primitives/
      test_helpers.move
docs/
  architechture.md         # Architecture Decision Record
examples/                  # TypeScript examples for client integration
```

### Three-Layer Architecture

This project uses a three-layer architecture pattern (see `docs/architechture.md`):

**Layer 1: Composable Primitives**

- Small, focused modules implementing low-level functionality
- Examples: `status.move`, `inventory.move`, `location.move`, `fuel.move`
- **Visibility rules:**
    - `public(package)` for state-mutating functions (e.g., `create`, `delete`, `online`, `offline`)
    - `public` for view/read-only functions (e.g., `hash`, `is_online`, `contains_item`)
    - `public` for utility functions that don't mutate primitive state
    - `public` for admin functions that require capability checks (e.g., `location::update` requires `AdminCap`)
- Enforce the "digital physics" of the game world

**Layer 2: Game-Defined Assemblies**

- In-game structures composed from primitives
- Examples: `storage_unit.move`, `assembly.move`
- Implemented as shared objects for concurrent access
- Expose `public` entry functions for player/admin interactions

**Layer 3: Player Extensions (Moddability)**

- Third-party contracts extending assembly behavior
- Use typed witness pattern for authorization
- Registered dynamically via `authorize_extension<Auth>()`

**Review Checklist:**

- [ ] Does the code maintain proper layer separation?
- [ ] Are primitive state-mutating functions using `public(package)` visibility?
- [ ] Are primitive view/utility functions appropriately `public`?
- [ ] Are assemblies using composition (not inheritance)?
- [ ] Do extensions use the typed witness pattern for authorization?

### Module Composition Pattern

Assemblies are composed from primitives, not inherited:

```move
public struct StorageUnit has key {
    id: UID,
    status: AssemblyStatus,      // from status.move
    location: Location,           // from location.move
    inventory_keys: vector<ID>,   // manages Inventory from inventory.move
    // ...
}
```

**Review Checklist:**

- [ ] Are primitives embedded as struct fields (composition)?
- [ ] Are primitive functions called via receiver syntax (e.g., `self.status.online()`)?
- [ ] Is each primitive module focused on a single domain?

## Move Conventions

### Official Conventions

Follow the official Move conventions:

- [Sui Move Concepts - Conventions](https://docs.sui.io/concepts/sui-move-concepts/conventions)
- [Move Book - Code Quality Checklist](https://move-book.com/guides/code-quality-checklist)

### Function Organization Order

Organize functions in this order within each module:

```move
// === Errors ===
// === Structs ===
// === Events ===

fun init(ctx: &mut TxContext) { }

// === Public Functions ===
// === View Functions ===
// === Admin Functions ===
// === Package Functions ===
// === Private Functions ===
// === Test Functions ===
```

**Review Checklist:**

- [ ] Are functions organized in the correct order?
- [ ] Is the `init` function placed after structs/events and before other functions?
- [ ] Are test-only functions at the bottom with `#[test_only]` attribute?

### Naming Conventions

- **Modules**: snake_case (e.g., `storage_unit`, `access_control`)
- **Structs**: PascalCase (e.g., `StorageUnit`, `OwnerCap`)
- **Functions**: snake_case (e.g., `create_character`, `is_authorized`)
- **Constants**: SCREAMING_SNAKE_CASE (e.g., `ENotAuthorized`)
- **Error constants**: Prefix with `E` (e.g., `EAssemblyNotAuthorized`)

### Receiver Syntax

Use receiver syntax for method calls when appropriate:

```move
// Good
assembly.status.online();
storage_unit.location.hash();

// Avoid when receiver syntax is available
status::online(&mut assembly.status);
```

### Index Syntax

Use index syntax for collections:

```move
// Good
let value = &vec_map[&key];

// Avoid
let value = vec_map::get(&vec_map, &key);
```

## Access Control

### Capability Hierarchy

This project uses a three-tier capability system:

1. **GovernorCap**: Top-level, held by deployer
    - Can create/delete AdminCaps
    - Can configure server addresses and ACLs

2. **AdminCap**: Mid-level, held by game operators
    - Can create/delete OwnerCaps
    - Can perform admin operations (anchor, unanchor, etc.)

3. **OwnerCap<T>**: Object-level, held by players
    - Grants access to specific objects
    - Phantom type `T` ensures type safety

**Review Checklist:**

- [ ] Is the appropriate capability required for each operation?
- [ ] Are capability checks performed before state mutations?
- [ ] Is `OwnerCap<T>` properly typed for the target object?

### Authorization Patterns

**Direct Authorization Check:**

```move
public fun online(storage_unit: &mut StorageUnit, owner_cap: &OwnerCap<StorageUnit>) {
    assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);
    storage_unit.status.online();
}
```

**Typed Witness Pattern (for extensions):**

```move
public fun deposit_item<Auth: drop>(
    storage_unit: &mut StorageUnit,
    item: Item,
    _: Auth,  // Witness - only the defining module can create this
) {
    assert!(
        storage_unit.extension.contains(&type_name::with_defining_ids<Auth>()),
        EExtensionNotAuthorized,
    );
    // ... operation
}
```

**ACL-based Authorization (for sponsored transactions):**

```move
let sponsor_opt = tx_context::sponsor(ctx);
assert!(option::is_some(&sponsor_opt), ETransactionNotSponsored);
let sponsor = *option::borrow(&sponsor_opt);
assert!(admin_acl.is_authorized_sponsor(sponsor), EUnauthorizedSponsor);
```

**Review Checklist:**

- [ ] Are all state-mutating functions protected by capability checks?
- [ ] Is the authorization check the first thing in the function?
- [ ] Are witness types used correctly (with `drop` ability, passed by value)?

## Error Handling

### Error Definition Pattern

Define errors at the top of the module with codes and descriptive messages:

```move
// === Errors ===
#[error(code = 0)]
const EStorageUnitTypeIdEmpty: vector<u8> = b"StorageUnit TypeId is empty";
#[error(code = 1)]
const EStorageUnitItemIdEmpty: vector<u8> = b"StorageUnit ItemId is empty";
#[error(code = 2)]
const EStorageUnitAlreadyExists: vector<u8> = b"StorageUnit with the same Item Id already exists";
```

**Review Checklist:**

- [ ] Are error codes unique within the module?
- [ ] Are error codes sequential starting from 0?
- [ ] Do error messages clearly describe the failure condition?
- [ ] Are errors defined in the `=== Errors ===` section at the top?

### Assertion Pattern

Use `assert!` with meaningful error constants:

```move
// Good
assert!(type_id != 0, EStorageUnitTypeIdEmpty);
assert!(item_id != 0, EStorageUnitItemIdEmpty);
assert!(storage_unit.status.is_online(), ENotOnline);

// Avoid - no error context
assert!(type_id != 0);
```

**Review Checklist:**

- [ ] Do all assertions use named error constants?
- [ ] Are preconditions checked before performing operations?
- [ ] Are error messages user-friendly and actionable?

## Testing Requirements

### Test Module Structure

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

### Test Module Declaration

```move
#[test_only]
module world::assembly_tests;
```

### Test Pattern with test_scenario

```move
#[test]
fun test_anchor_assembly() {
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

### Expected Failure Tests

```move
#[test]
#[expected_failure(abort_code = assembly::EAssemblyAlreadyExists)]
fun test_anchor_duplicate_item_id() {
    // Test that triggers the expected error
}
```

**Review Checklist:**

- [ ] Are tests present for all public functions?
- [ ] Do tests cover both success and failure paths?
- [ ] Are `expected_failure` tests present for all error conditions?
- [ ] Are shared objects properly returned with `ts::return_shared()`?
- [ ] Are owned objects properly returned with `ts::return_to_sender()`?
- [ ] Does each test call `ts::end(ts)` to complete the scenario?

### Test Helpers

Use `test_helpers.move` for common setup:

```move
public fun setup_world(ts: &mut ts::Scenario) {
    ts::next_tx(ts, governor());
    {
        world::init_for_testing(ts.ctx());
        access::init_for_testing(ts.ctx());
        character::init_for_testing(ts::ctx(ts));
        assembly::init_for_testing(ts.ctx());
    };
    // Create admin cap, etc.
}
```

**Review Checklist:**

- [ ] Are common setup steps extracted to `test_helpers.move`?
- [ ] Do modules expose `init_for_testing` functions when needed?
- [ ] Are test-only helper functions marked with `#[test_only]`?

## Events

### Event Definition

Define events in the `=== Events ===` section:

```move
public struct AssemblyCreatedEvent has copy, drop {
    assembly_id: ID,
    key: TenantItemId,
    type_id: u64,
    volume: u64,
}
```

### Event Emission

Emit events for all significant state changes:

```move
event::emit(AssemblyCreatedEvent {
    assembly_id,
    key: assembly_key,
    type_id,
    volume,
});
```

**Review Checklist:**

- [ ] Are events defined for all significant state changes?
- [ ] Do events have `copy` and `drop` abilities?
- [ ] Do events include all relevant data for indexers?
- [ ] Are events emitted after successful state changes (not before)?

## Object Model

### Shared vs Owned Objects

**Shared Objects** (most assemblies):

```move
transfer::share_object(assembly);
```

- Use for objects that need concurrent access
- Require explicit `share_object` call

**Owned Objects** (capabilities):

```move
transfer::transfer(owner_cap, owner);
```

- Use for capabilities and personal assets
- Can only be accessed by the owner

### Derived Objects

Use `derived_object` for deterministic ID generation:

```move
let assembly_key = in_game_id::create_key(item_id, tenant);
let assembly_uid = derived_object::claim(&mut registry.id, assembly_key);
```

**Review Checklist:**

- [ ] Are assemblies created as shared objects?
- [ ] Are capabilities created as owned objects?
- [ ] Is `derived_object` used for deterministic ID generation?
- [ ] Are UIDs properly deleted when objects are destroyed?

### Dynamic Fields

Use dynamic fields for variable-sized collections:

```move
// Add
df::add(&mut storage_unit.id, owner_cap_id, inventory);

// Borrow
let inventory = df::borrow<ID, Inventory>(&storage_unit.id, owner_cap_id);

// Borrow mut
let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, owner_cap_id);

// Remove
df::remove<ID, Inventory>(&mut id, key);
```

**Review Checklist:**

- [ ] Are dynamic fields used for unbounded collections?
- [ ] Are dynamic fields properly cleaned up on object destruction?
- [ ] Is `df::exists_` checked before accessing optional fields?

## Security Considerations

### Input Validation

- [ ] Are all input parameters validated before use?
- [ ] Are zero values rejected where appropriate (e.g., `type_id != 0`)?
- [ ] Are duplicate checks performed (e.g., `!assembly_exists()`)?

### Access Control

- [ ] Are all mutating functions protected by capability checks?
- [ ] Is the typed witness pattern used correctly for extensions?
- [ ] Are server addresses validated against the registry?

### State Integrity

- [ ] Are state transitions valid (e.g., OFFLINE → ONLINE)?
- [ ] Are objects properly cleaned up on destruction?
- [ ] Are dynamic fields removed before deleting parent objects?

### Location Privacy

- [ ] Are locations stored as hashes, not cleartext?
- [ ] Are proximity proofs verified before location-sensitive operations?
- [ ] Are server signatures validated for location attestations?

### Tenant Isolation

- [ ] Are tenant checks performed for cross-object operations?
- [ ] Is `ETenantMismatch` error used for cross-tenant violations?

## Documentation Requirements

### Module Documentation

Every module should have a doc comment explaining its purpose:

```move
/// This module handles the functionality of the in-game Storage Unit Assembly
///
/// The Storage Unit is a programmable, on-chain storage structure.
/// It can allow players to store, withdraw, and manage items under rules they design themselves.
module world::storage_unit;
```

### Function Documentation

Public functions should have doc comments:

```move
/// Bridges items from chain to game inventory
public fun chain_item_to_game_inventory<T: key>(
    storage_unit: &mut StorageUnit,
    // ...
) { }
```

### Architecture Documentation

- Reference `docs/architechture.md` for design decisions
- Include links to relevant documentation in complex patterns

**Review Checklist:**

- [ ] Do all modules have doc comments?
- [ ] Do all public functions have doc comments?
- [ ] Are complex patterns explained with comments or documentation links?

## Common Issues to Flag

### Access Control Issues

- Missing capability checks on mutating functions
- Wrong capability type used (e.g., `AdminCap` where `OwnerCap` is needed)
- Missing authorization assertion before state changes

### State Management Issues

- State transitions that bypass status checks
- Dynamic fields not cleaned up on destruction
- Shared objects not returned in tests

### Error Handling Issues

- Using raw abort codes instead of named error constants
- Missing error constants for failure conditions
- Non-sequential error codes

### Architecture Issues

- Primitive state-mutating functions exposed as `public` instead of `public(package)`
- Business logic in primitives instead of assemblies
- Direct field access bypassing accessor functions

### Testing Issues

- Missing failure tests for error conditions
- Shared objects not returned with `ts::return_shared()`
- Tests not calling `ts::end(ts)`
- Missing `init_for_testing` calls in test setup

## What NOT to Review

Do not flag issues that are handled by automated tools:

- Code formatting (handled by `sui move fmt`)
- Unused imports (handled by Move compiler warnings)
- Unused variables (handled by Move compiler warnings)

Focus on logic, architecture, access control, testing, and security rather than style issues.

## Review Process

1. **Understand the Change**: Read the PR description and understand what the change accomplishes
2. **Check Architecture**: Verify the change follows the three-layer architecture
3. **Review Access Control**: Ensure capabilities are properly checked
4. **Verify Tests**: Check that appropriate tests exist and cover the change
5. **Check Object Model**: Verify shared/owned object usage is correct
6. **Security Review**: Look for access control and state integrity issues
7. **Documentation**: Verify documentation is updated if needed

## Example Review Comments

**Good Review Comment:**

> "This function mutates `storage_unit` but doesn't check the `OwnerCap` authorization first. Add an assertion like `assert!(access::is_authorized(owner_cap, object::id(storage_unit)), EAssemblyNotAuthorized);` at the beginning."

**Bad Review Comment:**

> "Please run the Move formatter." (This is handled by tools)

**Good Review Comment:**

> "This test doesn't verify the expected failure case. Consider adding a test with `#[expected_failure(abort_code = storage_unit::ENotOnline)]` to cover the offline scenario."

**Bad Review Comment:**

> "The indentation looks wrong." (This is handled by the formatter)

## Adding New Features

1. **Determine the layer:**
    - Primitive (Layer 1): New digital physics concept
    - Assembly (Layer 2): New in-game structure
    - Extension (Layer 3): New player-customizable behavior

2. **For primitives:**

    ```
    sources/primitives/{feature}.move
    tests/primitives/{feature}_tests.move
    ```

    - Use `public(package)` for state-mutating functions
    - Use `public` for view/read-only and utility functions
    - Focus on single responsibility

3. **For assemblies:**

    ```
    sources/assemblies/{assembly}.move
    tests/assemblies/{assembly}_tests.move
    ```

    - Compose from existing primitives
    - Implement as shared objects
    - Add capability-protected mutations

4. **Update test helpers** if new setup functions are needed

5. **Update architecture docs** if new patterns are introduced

## Key Files to Reference

- `docs/architechture.md` - Architecture Decision Record
- `sources/access/access_control.move` - Capability system
- `sources/assemblies/assembly.move` - Base assembly patterns
- `sources/assemblies/storage_unit.move` - Full assembly example
- `tests/test_helpers.move` - Test utilities and setup

## Questions?

When in doubt:

1. Look at existing similar modules (storage_unit, assembly, character)
2. Follow established patterns from the architecture ADR
3. Check tests for usage examples
4. Review the capability hierarchy for access control decisions
