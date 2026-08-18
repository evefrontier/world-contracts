#[test_only]
module core::entity_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service,
    entity,
    test_helpers::{setup, take_registry, take_acl, claim, tenant}
};
use std::string;
use sui::test_scenario as ts;

public struct Counter has store {
    value: u64,
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
        let (mut e, mut req) = entity::new(&mut registry, 1, tenant());
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);

        assert!(entity::version(&e) == 1);
        assert!(entity::key(&e).id() == 1);
        assert!(entity::key(&e).tenant() == tenant());
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

    let mut req = e.install(
        counter_name(),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
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

    let mut req = e.install(
        counter_name(),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
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

    let mut req = e.install(
        counter_name(),
        Counter { value: 9 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    let (m, mut req) = e.uninstall<Counter>(counter_name(), internal::permit<Counter>(), ctx);
    admin_service::verify_admin(&mut req, &acl, ctx);
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
    let mut req = e.mint_access(@0xB, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);

    // Owner enables then disables the action.
    ts::next_tx(&mut scenario, @0xB);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.enable_action(string::utf8(b"act"), action::new(vector[]), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    let mut req = e.disable_action(string::utf8(b"act"), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = access_cap::ENotOwner)]
fun enable_action_by_non_owner_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e1 = claim(&mut registry, &acl, 1, scenario.ctx());
    let e1_id = e1.id();
    entity::share(e1);
    // Mint entity two's cap to @0xB: a cap that does not own entity one.
    let mut e2 = claim(&mut registry, &acl, 2, scenario.ctx());
    let mut req = e2.mint_access(@0xB, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e2.complete_request(req);
    entity::share(e2);
    ts::return_shared(acl);
    ts::return_shared(registry);

    // @0xB tries to configure entity one with the wrong entity's cap.
    ts::next_tx(&mut scenario, @0xB);
    let mut e1 = ts::take_shared_by_id<entity::Entity>(&scenario, e1_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e1.enable_action(string::utf8(b"act"), action::new(vector[]), scenario.ctx());
    access_cap::verify(&mut req, &cap);

    abort
}

#[test, expected_failure(abort_code = entity::EActionExists)]
fun enable_duplicate_action_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut req = e.mint_access(@0xB, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, @0xB);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.enable_action(string::utf8(b"act"), action::new(vector[]), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);
    let req = e.enable_action(string::utf8(b"act"), action::new(vector[]), scenario.ctx());
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

    let req = e.interact(string::utf8(b"missing"), vector[], ctx);
    e.complete_request(req);

    abort
}
