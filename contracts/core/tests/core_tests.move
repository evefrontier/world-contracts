#[test_only]
module core::core_tests;

use core::{action, assembly, internal, requirement::{Self, Requirement}};
use std::string;
use sui::test_scenario as ts;

public struct Counter has store {
    value: u64,
}

/// Requirement marker satisfied by this test's handler.
public struct Bump has drop {}

fun bump_requirement(module_name: vector<u8>): Requirement {
    requirement::from_config(option::some(string::utf8(module_name)), Bump {})
}

#[test]
fun end_to_end_flow() {
    let mut scenario = ts::begin(@0xA);
    let ctx = scenario.ctx();

    let mut e = assembly::new(ctx);

    // Install a module, then close out the install request.
    let req = e.install(
        string::utf8(b"counter"),
        Counter { value: 0 },
        1,
        internal::permit_for_testing<Counter>(),
        ctx,
    );
    e.complete_request(req);
    assert!(e.has_module(string::utf8(b"counter")));

    // Expose an action carrying one module-scoped requirement.
    let action = action::new(vector[bump_requirement(b"counter")]);
    let req = e.enable_action(string::utf8(b"bump"), action, ctx);
    e.complete_request(req);

    // Interact: borrow the module by requirement, satisfy the requirement, mutate.
    let mut req = e.interact(string::utf8(b"bump"), ctx);
    let counter = e.module_mut<Counter>(&req, internal::permit_for_testing<Counter>()).inner_mut();
    let (_requirement, frame) = req.take_next<Bump>(internal::permit_for_testing<Bump>());
    counter.value = counter.value + 1;
    req.enqueue(frame);
    e.complete_request(req);

    e.share();
    scenario.end();
}

#[test, expected_failure]
fun cannot_complete_with_pending_requirement() {
    let mut scenario = ts::begin(@0xA);
    let ctx = scenario.ctx();

    let mut e = assembly::new(ctx);
    let req = e.install(
        string::utf8(b"counter"),
        Counter { value: 0 },
        1,
        internal::permit_for_testing<Counter>(),
        ctx,
    );
    e.complete_request(req);

    let action = action::new(vector[bump_requirement(b"counter")]);
    let req = e.enable_action(string::utf8(b"bump"), action, ctx);
    e.complete_request(req);

    // Try to complete without satisfying the Bump requirement.
    let req = e.interact(string::utf8(b"bump"), ctx);
    e.complete_request(req);

    e.share();
    scenario.end();
}
