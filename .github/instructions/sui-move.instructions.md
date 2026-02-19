---
description: "Guidelines for building Sui Move contracts"
applyTo: "**/*.move"
---

# Sui Move Code Guidelines

This guide covers Move-specific conventions, patterns, and best practices for this repository.

## Official Conventions

Follow the official Move conventions:

- [Sui Move Concepts - Conventions](https://docs.sui.io/concepts/sui-move-concepts/conventions)
- [Move Book - Code Quality Checklist](https://move-book.com/guides/code-quality-checklist)

## Function Organization Order

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

## Naming Conventions

- **Modules**: snake_case (e.g., `storage_unit`, `access_control`)
- **Structs**: PascalCase (e.g., `StorageUnit`, `OwnerCap`)
- **Functions**: snake_case (e.g., `create_character`, `is_authorized`)
- **Constants**: SCREAMING_SNAKE_CASE (e.g., `ENotAuthorized`)
- **Error constants**: Prefix with `E` (e.g., `EAssemblyNotAuthorized`)

## Receiver Syntax

Use receiver syntax for method calls when appropriate:

```move
// Good
assembly.status.online();
storage_unit.location.hash();

// Avoid when receiver syntax is available
status::online(&mut assembly.status);
```

## Index Syntax

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
    - Can add/remove sponsors in AdminACL
    - Can configure server addresses and ACLs

2. **AdminACL**: Shared object with authorized sponsor addresses
    - Authorized sponsors can create/delete OwnerCaps
    - Authorized sponsors can perform admin operations (anchor, unanchor, etc.)

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

- [ ] Are state transitions valid (e.g., OFFLINE -> ONLINE)?
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

**Review Checklist:**

- [ ] Do all modules have doc comments?
- [ ] Do all public functions have doc comments?
- [ ] Are complex patterns explained with comments or documentation links?

## Common Issues to Flag

### Access Control Issues

- Missing capability checks on mutating functions
- Wrong capability type used (e.g., `AdminACL` where `OwnerCap` is needed)
- Missing authorization assertion before state changes

### State Management Issues

- State transitions that bypass status checks
- Dynamic fields not cleaned up on destruction

### Error Handling Issues

- Using raw abort codes instead of named error constants
- Missing error constants for failure conditions
- Non-sequential error codes

### Architecture Issues

- Primitive non-admin state-mutating functions exposed as `public` instead of `public(package)`
- Business logic in primitives instead of assemblies
- Direct field access bypassing accessor functions

## What NOT to Review

Do not flag issues that are handled by automated tools:

- Code formatting (handled by `sui move fmt`)
- Unused imports (handled by Move compiler warnings)
- Unused variables (handled by Move compiler warnings)

Focus on logic, architecture, access control, and security rather than style issues.

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
