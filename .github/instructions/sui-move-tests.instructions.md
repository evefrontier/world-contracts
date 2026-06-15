---
description: "Testing patterns and standards for Sui Move contracts"
applyTo: "**/tests/*.move"
---

# Sui Move Testing Guidelines

**The authoritative conventions (including the Testing section) live in
[`docs/move-conventions.md`](../../docs/move-conventions.md#testing).** Read it before writing
tests. `contracts/core/tests/entity_tests.move` is the reference example.

Non-negotiables (full detail in the doc above):

- Test modules are named `<module>_tests` and use the package address (`core::`, not `world::`).
- **No** `test_` prefix on test function names — the `_tests` suffix already says so.
- Use the combined `#[test, expected_failure(abort_code = entity::EIdEmpty)]` form, reference
  the named error constant, and end the body with `abort` — **no cleanup** in failure tests.
- A `Request` is a hot potato: every lifecycle call must be paired with `e.complete_request(req)`
  before the entity is shared or returned.
- Success tests clean up (`ts::return_shared` / `ts::return_to_sender`) and end with
  `scenario.end()`.
- Tests under `contracts/archive/` belong to the deprecated assembly model — not a template.
