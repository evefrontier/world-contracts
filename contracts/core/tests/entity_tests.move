#[test_only]
module core::entity_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service,
    entity,
    request,
    test_helpers::{setup, take_registry, take_acl, claim, create_entity, tenant}
};
use std::string;
use sui::test_scenario as ts;

public struct Counter has store {
    value: u64,
}

fun counter_id(): u64 {
    0xC0
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
        assert!(!entity::has_component(&e, counter_id()));
        assert!(entity::component_ids(&e).is_empty());

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

// === Components ===

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
        counter_id(),
        option::some(counter_name()),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    assert!(e.has_component(counter_id()));
    assert!(e.has_component_with_type<Counter>(counter_id()));
    assert!(e.component_ids() == vector[counter_id()]);

    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EComponentExists)]
fun install_duplicate_component_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let mut req = e.install(
        counter_id(),
        option::some(counter_name()),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    let req = e.install(
        counter_id(),
        option::some(counter_name()),
        Counter { value: 1 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
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
        counter_id(),
        option::some(counter_name()),
        Counter { value: 9 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    let (m, mut req) = e.uninstall<Counter>(counter_id(), internal::permit<Counter>(), ctx);
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    assert!(!e.has_component(counter_id()));
    assert!(e.component_ids().is_empty());
    let Counter { value } = m.unwrap(internal::permit<Counter>());
    assert!(value == 9);

    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EComponentMissing)]
fun uninstall_missing_component_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let (_m, _req) = e.uninstall<Counter>(counter_id(), internal::permit<Counter>(), ctx);

    abort
}

#[test]
fun install_two_modules_of_same_type() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();
    let second_id = 0xC1;

    let mut req = e.install(
        counter_id(),
        option::some(counter_name()),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    let mut req = e.install(
        second_id,
        option::some(string::utf8(b"counter-2")),
        Counter { value: 1 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    assert!(e.has_component_with_type<Counter>(counter_id()));
    assert!(e.has_component_with_type<Counter>(second_id));
    assert!(e.component_ref<Counter>(counter_id(), internal::permit<Counter>()).inner().value == 0);
    assert!(e.component_ref<Counter>(second_id, internal::permit<Counter>()).inner().value == 1);
    assert!(e.component_ids() == vector[counter_id(), second_id]);

    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun uninstall_one_of_two_keeps_the_other_listed() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();
    let second_id = 0xC1;

    let mut req = e.install(
        counter_id(),
        option::some(counter_name()),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    let mut req = e.install(
        second_id,
        option::some(string::utf8(b"counter-2")),
        Counter { value: 1 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    // Remove the first component. The list keeps the second one only.
    let (m, mut req) = e.uninstall<Counter>(counter_id(), internal::permit<Counter>(), ctx);
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);
    let Counter { value: _ } = m.unwrap(internal::permit<Counter>());

    assert!(e.component_ids() == vector[second_id]);
    assert!(!e.has_component(counter_id()));
    assert!(e.has_component(second_id));

    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
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
    e.verify_owner(&mut req, &cap);
    e.complete_request(req);

    let mut req = e.disable_action(string::utf8(b"act"), scenario.ctx());
    e.verify_owner(&mut req, &cap);
    e.complete_request(req);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EUnknownAction)]
fun owner_cannot_disable_admin_action_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut req = e.mint_access(@0xB, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let mut req = e.enable_admin_action(
        string::utf8(b"act"),
        action::new(vector[]),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);

    // The admin action is not in the owner's map, so the owner cannot remove it.
    ts::next_tx(&mut scenario, @0xB);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let req = e.disable_action(string::utf8(b"act"), scenario.ctx());
    e.complete_request(req);

    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun enable_admin_action_by_non_admin_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = claim(&mut registry, &acl, 1, scenario.ctx());
    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, @0xB);
    let mut e = ts::take_shared<entity::Entity>(&scenario);
    let acl = take_acl(&scenario);
    let mut req = e.enable_admin_action(
        string::utf8(b"act"),
        action::new(vector[]),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = entity::EUnknownAction)]
fun admin_cannot_disable_owner_action_aborts() {
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
    let mut req = e.enable_action(
        string::utf8(b"retrieve_the_one_piece"),
        action::new(vector[]),
        scenario.ctx(),
    );
    e.verify_owner(&mut req, &cap);
    e.complete_request(req);
    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);

    // The owner's action is not in the admin map, so the admin cannot remove it.
    ts::next_tx(&mut scenario, @0xA);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let req = e.disable_admin_action(string::utf8(b"retrieve_the_one_piece"), scenario.ctx());
    e.complete_request(req);

    abort
}

#[test]
fun interact_prefers_admin_action() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut req = e.mint_access(@0xB, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    // The admin action needs an admin. The owner's action, below, needs nothing.
    let mut req = e.enable_admin_action(
        string::utf8(b"give_unlimited_lux"),
        action::new(vector[admin_service::admin_requirement()]),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let e_id = e.id();
    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);

    // The same name in the owner's map is allowed.
    ts::next_tx(&mut scenario, @0xB);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.enable_action(
        string::utf8(b"give_unlimited_lux"),
        action::new(vector[]),
        scenario.ctx(),
    );
    e.verify_owner(&mut req, &cap);
    e.complete_request(req);
    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);

    // The request carries the admin requirement, so the admin action was chosen.
    ts::next_tx(&mut scenario, @0xA);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let acl = take_acl(&scenario);
    let mut req = e.interact(string::utf8(b"give_unlimited_lux"), scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(e);
    scenario.end();
}

#[test]
fun interact_falls_back_to_owner_action() {
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
    e.verify_owner(&mut req, &cap);
    e.complete_request(req);

    // No admin action has this name, so the owner's action is used.
    let req = e.interact(string::utf8(b"act"), scenario.ctx());
    e.complete_request(req);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EUnknownAction)]
fun interact_after_disable_admin_action_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut req = e.enable_admin_action(
        string::utf8(b"retrieve_the_one_piece"),
        action::new(vector[]),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let mut req = e.disable_admin_action(string::utf8(b"retrieve_the_one_piece"), scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    let req = e.interact(string::utf8(b"retrieve_the_one_piece"), scenario.ctx());
    e.complete_request(req);

    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun disable_admin_action_by_non_admin_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut req = e.enable_admin_action(
        string::utf8(b"retrieve_the_one_piece"),
        action::new(vector[]),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, @0xB);
    let mut e = ts::take_shared<entity::Entity>(&scenario);
    let acl = take_acl(&scenario);
    let mut req = e.disable_admin_action(string::utf8(b"retrieve_the_one_piece"), scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());

    abort
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
    e1.verify_owner(&mut req, &cap);

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
    e.verify_owner(&mut req, &cap);
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

    let req = e.interact(string::utf8(b"missing"), ctx);
    e.complete_request(req);

    abort
}

// === Delete ===

#[test]
fun delete_empty_entity() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let key = e.key();

    let (mut req, ticket) = e.request_delete();
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.delete(req, ticket);

    assert!(registry.exists(key));
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun delete_after_uninstall() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let mut req = e.install(
        counter_id(),
        option::some(counter_name()),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    let (m, mut req) = e.uninstall<Counter>(counter_id(), internal::permit<Counter>(), ctx);
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);
    let Counter { value: _ } = m.unwrap(internal::permit<Counter>());

    let (mut req, ticket) = e.request_delete();
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.delete(req, ticket);

    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun delete_shared_entity() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = claim(&mut registry, &acl, 1, scenario.ctx());
    let e_id = e.id();
    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, @0xA);
    let mut e = ts::take_shared_by_id<entity::Entity>(&scenario, e_id);
    let acl = take_acl(&scenario);
    let (mut req, ticket) = e.request_delete();
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.delete(req, ticket);
    ts::return_shared(acl);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EComponentsInstalled)]
fun delete_with_component_installed_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    let mut req = e.install(
        counter_id(),
        option::some(counter_name()),
        Counter { value: 0 },
        1,
        internal::permit<Counter>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    let (mut req, ticket) = e.request_delete();
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.delete(req, ticket);

    abort
}

#[test, expected_failure(abort_code = entity::ELocked)]
fun request_delete_while_locked_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let (mut e, _req) = entity::new(&mut registry, 1, tenant());
    let (_req2, _ticket) = e.request_delete();

    abort
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun delete_without_admin_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let (req, ticket) = e.request_delete();
    e.delete(req, ticket);

    abort
}

// === Docking ===

/// Dock `chaser` at `target` as an admin, completing the request on each.
fun dock_as_admin(
    target: &mut entity::Entity,
    chaser: &mut entity::Entity,
    acl: &admin_service::AdminACL,
    ctx: &mut TxContext,
) {
    let (mut target_req, mut chaser_req) = target.dock(chaser);
    admin_service::verify_admin(&mut target_req, acl, ctx);
    admin_service::verify_admin(&mut chaser_req, acl, ctx);
    target.complete_request(target_req);
    chaser.complete_request(chaser_req);
}

/// Undock `chaser` from `target` as an admin, completing the request on each.
fun undock_as_admin(
    target: &mut entity::Entity,
    chaser: &mut entity::Entity,
    acl: &admin_service::AdminACL,
    ctx: &mut TxContext,
) {
    let (mut target_req, mut chaser_req) = target.undock(chaser);
    admin_service::verify_admin(&mut target_req, acl, ctx);
    admin_service::verify_admin(&mut chaser_req, acl, ctx);
    target.complete_request(target_req);
    chaser.complete_request(chaser_req);
}

#[test]
fun dock_records_both_sides() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship = claim(&mut registry, &acl, 2, scenario.ctx());
    assert!(station.docked_entities().is_empty());

    dock_as_admin(&mut station, &mut ship, &acl, scenario.ctx());
    assert!(station.docked_entities().contains(&ship.id()));
    assert!(ship.docked_entities().contains(&station.id()));

    // Each side accepts the other as a transfer source, and itself.
    station.assert_docked(ship.id());
    ship.assert_docked(station.id());
    let station_id = station.id();
    station.assert_docked(station_id);

    station.share();
    ship.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

/// `dock` locks the target too: until its own request completes, it can't open another.
#[test, expected_failure(abort_code = sui::dynamic_field::EFieldAlreadyExists)]
fun dock_locks_target_until_its_request_completes() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship_a = claim(&mut registry, &acl, 2, scenario.ctx());
    let mut ship_b = claim(&mut registry, &acl, 3, scenario.ctx());

    let (_target_req, mut chaser_req) = station.dock(&mut ship_a);
    admin_service::verify_admin(&mut chaser_req, &acl, scenario.ctx());
    ship_a.complete_request(chaser_req);

    // The station's request is still open, so it is still locked.
    let (_station_req, _ship_b_req) = station.dock(&mut ship_b);

    abort
}

/// Completing both requests unlocks both sides: each can dock again straight after.
#[test]
fun dock_and_undock_leave_both_sides_unlocked() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship_a = claim(&mut registry, &acl, 2, scenario.ctx());
    let mut ship_b = claim(&mut registry, &acl, 3, scenario.ctx());

    dock_as_admin(&mut station, &mut ship_a, &acl, scenario.ctx());
    // The target was not left locked: it can take another dock, as target or chaser.
    dock_as_admin(&mut station, &mut ship_b, &acl, scenario.ctx());
    undock_as_admin(&mut station, &mut ship_a, &acl, scenario.ctx());
    dock_as_admin(&mut ship_a, &mut station, &acl, scenario.ctx());

    station.share();
    ship_a.share();
    ship_b.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun multiple_docked_entities_each_pass_as_source() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship_a = claim(&mut registry, &acl, 2, scenario.ctx());
    let mut ship_b = claim(&mut registry, &acl, 3, scenario.ctx());
    let mut ship_c = claim(&mut registry, &acl, 4, scenario.ctx());
    dock_as_admin(&mut station, &mut ship_a, &acl, scenario.ctx());
    dock_as_admin(&mut station, &mut ship_b, &acl, scenario.ctx());
    dock_as_admin(&mut station, &mut ship_c, &acl, scenario.ctx());

    let docked = station.docked_entities();
    assert!(docked.length() == 3);
    assert!(docked.contains(&ship_a.id()));
    assert!(docked.contains(&ship_b.id()));
    assert!(docked.contains(&ship_c.id()));

    // Every docked entity is accepted as a transfer source.
    station.assert_docked(ship_a.id());
    station.assert_docked(ship_b.id());
    station.assert_docked(ship_c.id());

    station.share();
    ship_a.share();
    ship_b.share();
    ship_c.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EWrongSource)]
fun multiple_docked_entities_reject_undocked_source() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship_a = claim(&mut registry, &acl, 2, scenario.ctx());
    let mut ship_b = claim(&mut registry, &acl, 3, scenario.ctx());
    let ship_c = claim(&mut registry, &acl, 4, scenario.ctx());
    dock_as_admin(&mut station, &mut ship_a, &acl, scenario.ctx());
    dock_as_admin(&mut station, &mut ship_b, &acl, scenario.ctx());

    // Two entities are docked, but not this one.
    station.assert_docked(ship_c.id());

    abort
}

#[test]
fun undock_removes_both_sides() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship_a = claim(&mut registry, &acl, 2, scenario.ctx());
    let mut ship_b = claim(&mut registry, &acl, 3, scenario.ctx());
    dock_as_admin(&mut station, &mut ship_a, &acl, scenario.ctx());
    dock_as_admin(&mut station, &mut ship_b, &acl, scenario.ctx());

    undock_as_admin(&mut station, &mut ship_a, &acl, scenario.ctx());

    assert!(!station.docked_entities().contains(&ship_a.id()));
    assert!(station.docked_entities().contains(&ship_b.id()));
    assert!(ship_a.docked_entities().is_empty());
    assert!(ship_b.docked_entities().contains(&station.id()));

    station.share();
    ship_a.share();
    ship_b.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::ENotDocked)]
fun assert_docked_with_nothing_docked_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let station = claim(&mut registry, &acl, 1, scenario.ctx());
    let ship = claim(&mut registry, &acl, 2, scenario.ctx());
    station.assert_docked(ship.id());

    abort
}

#[test]
fun assert_docked_with_self_source() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = claim(&mut registry, &acl, 1, scenario.ctx());
    let self_id = e.id();
    e.assert_docked(self_id);

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::ENotDocked)]
fun assert_docked_after_last_undock_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship = claim(&mut registry, &acl, 2, scenario.ctx());
    dock_as_admin(&mut station, &mut ship, &acl, scenario.ctx());
    undock_as_admin(&mut station, &mut ship, &acl, scenario.ctx());

    station.assert_docked(ship.id());

    abort
}

#[test, expected_failure(abort_code = entity::EWrongSource)]
fun assert_docked_with_undocked_source_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship = claim(&mut registry, &acl, 2, scenario.ctx());
    let other_ship = claim(&mut registry, &acl, 3, scenario.ctx());
    dock_as_admin(&mut station, &mut ship, &acl, scenario.ctx());

    // Something is docked, but not the source.
    station.assert_docked(other_ship.id());

    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun dock_by_non_admin_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let station_id = create_entity(&mut scenario, 1);
    let ship_id = create_entity(&mut scenario, 2);

    ts::next_tx(&mut scenario, @0xB);
    let mut station = ts::take_shared_by_id<entity::Entity>(&scenario, station_id);
    let mut ship = ts::take_shared_by_id<entity::Entity>(&scenario, ship_id);
    let acl = take_acl(&scenario);
    let (mut req, _chaser_req) = station.dock(&mut ship);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun undock_by_non_admin_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let station_id = create_entity(&mut scenario, 1);
    let ship_id = create_entity(&mut scenario, 2);

    ts::next_tx(&mut scenario, @0xA);
    let mut station = ts::take_shared_by_id<entity::Entity>(&scenario, station_id);
    let mut ship = ts::take_shared_by_id<entity::Entity>(&scenario, ship_id);
    let acl = take_acl(&scenario);
    dock_as_admin(&mut station, &mut ship, &acl, scenario.ctx());
    ts::return_shared(station);
    ts::return_shared(ship);
    ts::return_shared(acl);

    ts::next_tx(&mut scenario, @0xB);
    let mut station = ts::take_shared_by_id<entity::Entity>(&scenario, station_id);
    let mut ship = ts::take_shared_by_id<entity::Entity>(&scenario, ship_id);
    let acl = take_acl(&scenario);
    let (mut req, _chaser_req) = station.undock(&mut ship);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = sui::vec_set::EKeyAlreadyExists)]
fun dock_same_pair_twice_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship = claim(&mut registry, &acl, 2, scenario.ctx());
    dock_as_admin(&mut station, &mut ship, &acl, scenario.ctx());
    dock_as_admin(&mut station, &mut ship, &acl, scenario.ctx());

    abort
}

/// Docking is symmetric, so swapping target and chaser is the same pair.
#[test, expected_failure(abort_code = sui::vec_set::EKeyAlreadyExists)]
fun dock_same_pair_reversed_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship = claim(&mut registry, &acl, 2, scenario.ctx());
    dock_as_admin(&mut station, &mut ship, &acl, scenario.ctx());
    dock_as_admin(&mut ship, &mut station, &acl, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = entity::EWrongSource)]
fun undock_pair_not_docked_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut station = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut ship = claim(&mut registry, &acl, 2, scenario.ctx());
    let (_target_req, _chaser_req) = station.undock(&mut ship);

    abort
}
