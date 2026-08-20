#[test_only]
module core::core_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity,
    location_service,
    request,
    requirement::{Self, Requirement},
    test_helpers::{setup, take_registry, take_acl, claim}
};
use std::string;
use sui::test_scenario as ts;

public struct Counter has store {
    value: u64,
}

/// Requirement marker satisfied by this test's handler.
public struct Bump has drop {}

fun increment_requirement(module_id: u64): Requirement {
    requirement::from_config(option::some(module_id), Bump {})
}

fun counter_id(): u64 {
    0xC0
}

fun claim_test_entity(scenario: &mut ts::Scenario, acl: &AdminACL): entity::Entity {
    let mut registry = take_registry(scenario);
    let e = claim(&mut registry, acl, 1, scenario.ctx());
    ts::return_shared(registry);
    e
}

#[test]
fun end_to_end_flow() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let acl = take_acl(&scenario);
    let mut e = claim_test_entity(&mut scenario, &acl);

    let counter_id = counter_id();

    // Install a module (admin-gated), then close out the install request.
    let mut req = e.install(
        counter_id,
        option::some(string::utf8(b"counter")),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(e.has_module(counter_id));

    // Mint the owner cap so the owner can configure actions.
    let mut req = e.mint_access(@0xA, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);

    // Owner exposes an action carrying one module-scoped requirement, then runs it.
    ts::next_tx(&mut scenario, @0xA);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let action = action::new(vector[increment_requirement(counter_id())]);
    let mut req = e.enable_action(string::utf8(b"increment"), action, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    // Interact: target location is baked into proximity; caller must match, then
    // borrow the module by requirement, satisfy it, and mutate.
    let mut req = e.interact(string::utf8(b"increment"), b"loc", scenario.ctx());
    location_service::verify_proximity(&mut req, b"loc");
    let counter = e.module_mut<Counter>(&req, internal::permit<Counter>()).inner_mut();
    let (_requirement, frame) = req.take_next<Bump>(internal::permit<Bump>());
    counter.value = counter.value + 1;
    req.enqueue(frame);
    e.complete_request(req);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun cannot_complete_with_pending_requirement() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let acl = take_acl(&scenario);
    let mut e = claim_test_entity(&mut scenario, &acl);

    let counter_id = counter_id();

    let mut req = e.install(
        counter_id,
        option::some(string::utf8(b"counter")),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    let mut req = e.mint_access(@0xA, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);

    ts::next_tx(&mut scenario, @0xA);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let action = action::new(vector[increment_requirement(counter_id())]);
    let mut req = e.enable_action(string::utf8(b"increment"), action, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    // Try to complete without satisfying the requirement.
    let req = e.interact(string::utf8(b"increment"), b"loc", scenario.ctx());
    e.complete_request(req);

    abort
}

#[test, expected_failure(abort_code = location_service::EProximityMismatch)]
fun interact_proximity_caller_mismatch_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let acl = take_acl(&scenario);
    let mut e = claim_test_entity(&mut scenario, &acl);
    let mut req = e.mint_access(@0xA, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);

    ts::next_tx(&mut scenario, @0xA);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.enable_action(
        string::utf8(b"noop"),
        action::new(vector[]),
        scenario.ctx(),
    );
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    let mut req = e.interact(string::utf8(b"noop"), b"dest", scenario.ctx());
    location_service::verify_proximity(&mut req, b"src");

    abort
}
