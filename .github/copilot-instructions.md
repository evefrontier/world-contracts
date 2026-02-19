# Code Review Guide for World Contracts

This guide provides instructions for reviewing code changes in this repository.

**Note:** Move-specific guidelines are in separate instruction files that apply automatically based on file type:

- `.github/instructions/sui-move.instructions.md` - Applied to `**/*.move` files
- `.github/instructions/sui-move-tests.instructions.md` - Applied to `**/tests/*.move` files

## Project Structure

```
contracts/
  world/
    sources/
      access/              # Access control and capabilities
        access_control.move
      assemblies/          # Game-defined assemblies (Layer 2)
        assembly.move
        storage_unit.move
      character/           # Character management
        character.move
      crypto/              # Cryptographic utilities
        sig_verify.move
      metadata/            # Metadata management
        metadata.move
      network/             # Network node functionality
        network_node.move
      primitives/          # Composable primitives (Layer 1)
        fuel.move
        in_game_id.move
        inventory.move
        location.move
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

## Three-Layer Architecture

This project uses a three-layer architecture pattern (see `docs/architechture.md`):

**Layer 1: Composable Primitives**

- Small, focused modules implementing low-level functionality
- Examples: `status.move`, `inventory.move`, `location.move`, `fuel.move`
- **Visibility rules:**
    - `public(package)` for state-mutating functions (e.g., `create`, `delete`, `online`, `offline`)
    - `public` for view/read-only functions (e.g., `hash`, `is_online`, `contains_item`)
    - `public` for utility functions that don't mutate primitive state
    - `public` for admin functions that require ACL checks (e.g., `location::update` requires `AdminACL` + `verify_sponsor`)
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
- [ ] Are primitive state-mutating functions using `public(package)` visibility or `public` visibility with a capability?
- [ ] Are primitive view/utility functions appropriately `public`?
- [ ] Are assemblies using composition (not inheritance)?
- [ ] Do extensions use the typed witness pattern for authorization?

## Module Composition Pattern

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

## Review Process

1. **Understand the Change**: Read the PR description and understand what the change accomplishes
2. **Check Architecture**: Verify the change follows the three-layer architecture
3. **Review Access Control**: Ensure capabilities are properly checked
4. **Verify Tests**: Check that appropriate tests exist and cover the change
5. **Check Object Model**: Verify shared/owned object usage is correct
6. **Security Review**: Look for access control and state integrity issues
7. **Documentation**: Verify documentation is updated if needed

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
