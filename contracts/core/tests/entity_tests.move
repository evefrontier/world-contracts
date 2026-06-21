#[test_only]
module core::entity_tests;

use core::{
    action,
    admin_service::{Self, AdminACL},
    entity,
    object_registry::{Self, ObjectRegistry}
};
use std::string;
use sui::test_scenario as ts;

public struct Counter has store {
    value: u64,
}

const TENANT: vector<u8> = b"test";

fun setup(scenario: &mut ts::Scenario) {
    object_registry::init_for_testing(scenario.ctx());
    admin_service::init_for_testing(scenario.ctx());
}

fun take_registry(scenario: &ts::Scenario): ObjectRegistry {
    ts::take_shared<ObjectRegistry>(scenario)
}

fun take_acl(scenario: &ts::Scenario): AdminACL {
    ts::take_shared<AdminACL>(scenario)
}

/// Claim and admin-approve an entity, returning it unlocked.
fun claim(
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    id: u64,
    ctx: &mut TxContext,
): entity::Entity {
    let (mut e, mut req) = entity::new(registry, id, string::utf8(TENANT), vector[]);
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
    e
}

fun counter_name(): string::String {
    string::utf8(b"counter")
}

// === Construction ===

#[test]
fun new_sets_initial_fields() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let mut registry = take_registry(&scenario);
        let acl = take_acl(&scenario);
        let (mut e, mut req) = entity::new(&mut registry, 1, string::utf8(TENANT), b"loc");
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);

        assert!(entity::version(&e) == 1);
        assert!(entity::location_hash(&e) == b"loc");
        assert!(entity::key(&e).id() == 1);
        assert!(entity::key(&e).tenant() == string::utf8(TENANT));
        assert!(!entity::has_module(&e, counter_name()));

        entity::share(e);
        ts::return_shared(acl);
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = entity::EEntityAlreadyExists)]
fun reclaiming_same_id_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let _first = claim(&mut registry, &acl, 7, scenario.ctx());
    let _second = claim(&mut registry, &acl, 7, scenario.ctx());

    abort
}

#[test]
fun distinct_ids_yield_distinct_entities() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let mut registry = take_registry(&scenario);
        let acl = take_acl(&scenario);
        let a = claim(&mut registry, &acl, 1, scenario.ctx());
        let b = claim(&mut registry, &acl, 2, scenario.ctx());
        assert!(entity::id(&a) != entity::id(&b));
        entity::share(a);
        entity::share(b);
        ts::return_shared(acl);
        ts::return_shared(registry);
    };

    scenario.end();
}

// === Modules ===

#[test]
fun install_adds_module() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let req = e.install(counter_name(), Counter { value: 0 }, 1, internal::permit<Counter>(), ctx);
    e.complete_request(req);

    assert!(e.has_module(counter_name()));
    assert!(e.has_module_with_type<Counter>(counter_name()));

    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EModuleExists)]
fun install_duplicate_module_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let req = e.install(counter_name(), Counter { value: 0 }, 1, internal::permit<Counter>(), ctx);
    e.complete_request(req);

    let req = e.install(counter_name(), Counter { value: 1 }, 1, internal::permit<Counter>(), ctx);
    e.complete_request(req);

    abort
}

#[test]
fun uninstall_removes_and_returns_module() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let req = e.install(counter_name(), Counter { value: 9 }, 1, internal::permit<Counter>(), ctx);
    e.complete_request(req);

    let (m, req) = e.uninstall<Counter>(counter_name(), internal::permit<Counter>(), ctx);
    e.complete_request(req);

    assert!(!e.has_module(counter_name()));
    let Counter { value } = m.unwrap(internal::permit<Counter>());
    assert!(value == 9);

    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EModuleMissing)]
fun uninstall_missing_module_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let (_m, _req) = e.uninstall<Counter>(counter_name(), internal::permit<Counter>(), ctx);

    abort
}

// === Actions ===

#[test]
fun enable_then_disable_action() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let req = e.enable_action(string::utf8(b"act"), action::new(vector[]), ctx);
    e.complete_request(req);

    let req = e.disable_action(string::utf8(b"act"), ctx);
    e.complete_request(req);

    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EActionExists)]
fun enable_duplicate_action_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let req = e.enable_action(string::utf8(b"act"), action::new(vector[]), ctx);
    e.complete_request(req);
    let req = e.enable_action(string::utf8(b"act"), action::new(vector[]), ctx);
    e.complete_request(req);

    abort
}

#[test, expected_failure(abort_code = entity::EUnknownAction)]
fun disable_unknown_action_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let req = e.disable_action(string::utf8(b"missing"), ctx);
    e.complete_request(req);

    abort
}

#[test, expected_failure(abort_code = entity::EUnknownAction)]
fun interact_unknown_action_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let req = e.interact(string::utf8(b"missing"), ctx);
    e.complete_request(req);

    abort
}
