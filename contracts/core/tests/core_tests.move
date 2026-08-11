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
    test_helpers::{setup, take_registry, take_acl, claim, claim_character, location_hash, tenant}
};
use std::string;
use sui::test_scenario as ts;

public struct Counter has store {
    value: u64,
}

/// Requirement marker satisfied by this test's handler.
public struct Bump has drop {}

fun increment_requirement(module_name: vector<u8>): Requirement {
    requirement::from_config(option::some(string::utf8(module_name)), Bump {})
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

    // Install a module (admin-gated), then close out the install request.
    let mut req = e.install(
        string::utf8(b"counter"),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(e.has_module(string::utf8(b"counter")));

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
    let action = action::new(vector[increment_requirement(b"counter")]);
    let mut req = e.enable_action(string::utf8(b"increment"), action, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    // Interact: satisfy injected proximity, then borrow the module and mutate.
    let mut req = e.interact(string::utf8(b"increment"), scenario.ctx());
    location_service::verify_proximity(&mut req, location_hash());
    let counter = e.module_mut<Counter>(&req, internal::permit<Counter>()).inner_mut();
    let (_requirement, frame) = req.take_next<Bump>(internal::permit<Bump>());
    counter.value = counter.value + 1;
    req.enqueue(frame);
    e.complete_request(req);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test]
fun interact_injects_proximity_when_location_set() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let (mut e, mut req) = entity::new(&mut registry, 1, tenant(), b"loc");
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    let mut req = e.mint_access(@0xA, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, @0xA);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.enable_action(string::utf8(b"noop"), action::new(vector[]), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    let mut req = e.interact(string::utf8(b"noop"), scenario.ctx());
    location_service::verify_proximity(&mut req, b"loc");
    e.complete_request(req);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test]
fun interact_skips_proximity_when_location_empty() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim_character(&mut registry, &acl, 1, scenario.ctx());
    let mut req = e.mint_access(@0xA, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, @0xA);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.enable_action(string::utf8(b"noop"), action::new(vector[]), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    // Empty location_hash: no proximity requirement — complete without verify_proximity.
    let req = e.interact(string::utf8(b"noop"), scenario.ctx());
    e.complete_request(req);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = request::ENoRequirements)]
fun verify_proximity_aborts_when_location_empty() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim_character(&mut registry, &acl, 1, scenario.ctx());
    let mut req = e.mint_access(@0xA, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, @0xA);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.enable_action(string::utf8(b"noop"), action::new(vector[]), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    let mut req = e.interact(string::utf8(b"noop"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);

    abort
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun cannot_complete_with_pending_requirement() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let acl = take_acl(&scenario);
    let mut e = claim_test_entity(&mut scenario, &acl);

    let mut req = e.install(
        string::utf8(b"counter"),
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
    let action = action::new(vector[increment_requirement(b"counter")]);
    let mut req = e.enable_action(string::utf8(b"increment"), action, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    // Try to complete without satisfying the requirement.
    let req = e.interact(string::utf8(b"increment"), scenario.ctx());
    e.complete_request(req);

    abort
}
