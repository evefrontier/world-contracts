#[test_only]
module core::core_tests;

use core::{
    action,
    admin_service::{Self, AdminACL},
    entity,
    location_service,
    object_registry::{Self, ObjectRegistry},
    request,
    requirement::{Self, Requirement}
};
use std::string;
use sui::test_scenario as ts;

public struct Counter has store {
    value: u64,
}

/// Requirement marker satisfied by this test's handler.
public struct Bump has drop {}

const TENANT: vector<u8> = b"test";

fun increment_requirement(module_name: vector<u8>): Requirement {
    requirement::from_config(option::some(string::utf8(module_name)), Bump {})
}

fun setup_registry(scenario: &mut ts::Scenario) {
    object_registry::init_for_testing(scenario.ctx());
    admin_service::init_for_testing(scenario.ctx());
}

fun claim_test_entity(scenario: &mut ts::Scenario, acl: &AdminACL): entity::Entity {
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let (mut e, mut req) = entity::new(&mut registry, 1, string::utf8(TENANT), vector[]);
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(registry);
    e
}

#[test]
fun end_to_end_flow() {
    let mut scenario = ts::begin(@0xA);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let mut e = claim_test_entity(&mut scenario, &acl);
    let ctx = scenario.ctx();

    // Install a module (admin-gated), then close out the install request.
    let mut req = e.install(
        string::utf8(b"counter"),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);
    assert!(e.has_module(string::utf8(b"counter")));

    // Expose an action carrying one module-scoped requirement.
    let action = action::new(vector[increment_requirement(b"counter")]);
    let req = e.enable_action(string::utf8(b"increment"), action, ctx);
    e.complete_request(req);

    // Interact: satisfy the injected proximity requirement first, then borrow the
    // module by requirement, satisfy it, and mutate.
    let mut req = e.interact(string::utf8(b"increment"), ctx);
    location_service::verify_proximity(&mut req, vector[]);
    let counter = e.module_mut<Counter>(&req, internal::permit<Counter>()).inner_mut();
    let (_requirement, frame) = req.take_next<Bump>(internal::permit<Bump>());
    counter.value = counter.value + 1;
    req.enqueue(frame);
    e.complete_request(req);

    e.share();
    ts::return_shared(acl);
    scenario.end();
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun cannot_complete_with_pending_requirement() {
    let mut scenario = ts::begin(@0xA);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let mut e = claim_test_entity(&mut scenario, &acl);
    let ctx = scenario.ctx();

    let mut req = e.install(
        string::utf8(b"counter"),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    let action = action::new(vector[increment_requirement(b"counter")]);
    let req = e.enable_action(string::utf8(b"increment"), action, ctx);
    e.complete_request(req);

    // Try to complete without satisfying the requirement.
    let req = e.interact(string::utf8(b"increment"), ctx);
    e.complete_request(req);

    abort
}
