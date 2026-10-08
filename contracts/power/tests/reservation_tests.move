#[test_only]
module power::reservation_tests;

use core::{
    access_cap::{Self, AccessCap},
    admin_service,
    entity::Entity,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use power::{
    grid_scenario::{
        Self,
        active,
        connect,
        enable_admin,
        has_reservation,
        install_consumer,
        connect_module,
        connect_module_as,
        set_priority,
        release,
        release_priority,
        reservation_of,
        reserve_elastic,
        reserve_firm,
        disconnect_module,
        used
    },
    power_grid::{Self, ModuleConnected, PriorityChanged, Released, Reserved}
};
use std::string;
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const OUTPUT: u64 = 50;
const MOD_A: u64 = 201;
const MOD_B: u64 = 202;
const MOD_C: u64 = 203;
/// First component id of the bulk modules in the connect-cap test.
const BULK_BASE: u64 = 1_000;

// === Helpers ===

/// One Generator of `OUTPUT` and modules A and B (installed, not registered).
/// With `powered`, the grid is on and the Generator online.
fun setup_entity(scenario: &mut ts::Scenario, powered: bool, clock: &Clock): ID {
    let entity_id = grid_scenario::setup_entity(
        scenario,
        vector[OUTPUT],
        vector[MOD_A, MOD_B, MOD_C],
        clock,
    );
    if (powered) grid_scenario::power_up(scenario, entity_id, 1, clock);
    entity_id
}

// === Tests ===

#[test]
fun register_stores_line_loss_and_connects() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);

    connect_module(&mut scenario, entity_id, MOD_A, 5, &clock);
    let connected = event::events_by_type<ModuleConnected>();
    assert!(connected.length() == 1);
    let (event_entity, module_id, line_loss, priority) = connected[0].module_connected_fields();
    assert!(event_entity == entity_id && module_id == MOD_A);
    assert!(line_loss == 5 && priority == 0);

    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        let grid = power_grid::power_grid(&e);
        assert!(grid.is_module_registered(MOD_A));
        assert!(!grid.is_module_registered(MOD_B));
        let state = grid.module_state(MOD_A);
        assert!(state.line_loss() == 5);
        assert!(state.reservation().is_none());
        assert!(grid.is_connected(MOD_A));
        assert!(grid.priority(MOD_A) == 0);
        ts::return_shared(e);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun unregister_removes_module() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);
    connect_module(&mut scenario, entity_id, MOD_A, 5, &clock);
    disconnect_module(&mut scenario, entity_id, MOD_A, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        let grid = power_grid::power_grid(&e);
        assert!(grid.modules().is_empty());
        assert!(grid.modules().is_empty());
        ts::return_shared(e);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun reserve_grants_when_it_fits() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 5, 0, &clock);

    reserve_firm(&mut scenario, entity_id, MOD_A, 20, &clock);
    let reserved = event::events_by_type<Reserved>();
    assert!(reserved.length() == 1);
    let (event_entity, module_id, kind, requested, line_loss, active_draw) = reserved[
        0,
    ].reserved_fields();
    assert!(event_entity == entity_id && module_id == MOD_A && kind.is_firm());
    assert!(requested == 20 && line_loss == 5 && active_draw == 20);

    let reservation = reservation_of(&mut scenario, entity_id, MOD_A);
    assert!(reservation.requested() == 20);
    assert!(reservation.active_draw() == 20);
    assert!(reservation.kind().is_firm());
    // Line loss occupies the pool alongside the draw.
    assert!(used(&mut scenario, entity_id) == 25);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EInsufficientPower)]
fun reserve_aborts_when_short() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 5, 0, &clock);
    // 46 + 5 = 51 > 50: the draw alone would fit, but its line loss does not.
    reserve_firm(&mut scenario, entity_id, MOD_A, 46, &clock);

    abort
}

#[test]
fun reserve_fills_capacity_exactly() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 5, 0, &clock);

    // 45 + 5 fills the pool exactly.
    reserve_firm(&mut scenario, entity_id, MOD_A, 45, &clock);
    assert!(active(&mut scenario, entity_id, MOD_A) == 45);
    assert!(used(&mut scenario, entity_id) == OUTPUT);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EInsufficientPower)]
fun reserve_when_full_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 5, 0, &clock);
    connect(&mut scenario, entity_id, MOD_B, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 45, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_B, 1, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EInsufficientPower)]
fun reserve_while_off_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);
    // Generator online but the grid off: rated capacity, zero effective.
    grid_scenario::set_generator(&mut scenario, entity_id, 0, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);

    abort
}

#[test]
fun release_frees_capacity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 5, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 45, &clock);
    assert!(used(&mut scenario, entity_id) == 50);

    clock.set_for_testing(5_000);
    release(&mut scenario, entity_id, MOD_A, &clock);
    let released = event::events_by_type<Released>();
    assert!(released.length() == 1);
    let (event_entity, module_id) = released[0].released_fields();
    assert!(event_entity == entity_id && module_id == MOD_A);

    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        let grid = power_grid::power_grid(&e);
        assert!(grid.used_mw() == 0);
        assert!(!grid.has_reservation(MOD_A));
        assert!(grid.last_settled_ms() == 5_000);
        ts::return_shared(e);
    };

    // The freed draw + line loss is available again.
    reserve_firm(&mut scenario, entity_id, MOD_A, 45, &clock);
    assert!(active(&mut scenario, entity_id, MOD_A) == 45);
    assert!(used(&mut scenario, entity_id) == 50);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EAlreadyReserved)]
fun duplicate_reserve_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::ENotConnected)]
fun reserve_unconnected_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EZeroDraw)]
fun reserve_zero_draw_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::ENotReserved)]
fun release_without_reservation_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    release(&mut scenario, entity_id, MOD_A, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EModuleMissing)]
fun register_missing_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);
    connect_module(&mut scenario, entity_id, 999, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EModuleAlreadyRegistered)]
fun register_module_twice_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);
    connect_module(&mut scenario, entity_id, MOD_A, 0, &clock);
    connect_module(&mut scenario, entity_id, MOD_A, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun register_module_by_non_admin_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);
    connect_module_as(&mut scenario, OWNER, entity_id, MOD_A, 0, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EModuleNotRegistered)]
fun unregister_unknown_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);
    disconnect_module(&mut scenario, entity_id, MOD_A, &clock);

    abort
}

#[test]
fun unregister_releases_reservation() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 5, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 40, &clock);

    disconnect_module(&mut scenario, entity_id, MOD_A, &clock);
    let released = event::events_by_type<Released>();
    assert!(released.length() == 1);
    let (_, module_id) = released[0].released_fields();
    assert!(module_id == MOD_A);
    assert!(!has_reservation(&mut scenario, entity_id, MOD_A));
    assert!(used(&mut scenario, entity_id) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun owner_sets_priority() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);
    connect_module(&mut scenario, entity_id, MOD_A, 0, &clock);

    set_priority(&mut scenario, entity_id, MOD_A, 4, &clock);
    let changed = event::events_by_type<PriorityChanged>();
    assert!(changed.length() == 1);
    let (event_entity, module_id, priority) = changed[0].priority_changed_fields();
    assert!(event_entity == entity_id && module_id == MOD_A && priority == 4);

    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        assert!(power_grid::power_grid(&e).priority(MOD_A) == 4);
        ts::return_shared(e);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::ENotConnected)]
fun set_priority_unknown_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);
    set_priority(&mut scenario, entity_id, MOD_A, 1, &clock);

    abort
}

#[test]
fun release_priority_releases_whole_group() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 5, &clock);
    connect(&mut scenario, entity_id, MOD_B, 0, 5, &clock);
    connect(&mut scenario, entity_id, MOD_C, 0, 1, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_B, 10, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_C, 10, &clock);

    release_priority(&mut scenario, entity_id, 5, &clock);
    assert!(event::events_by_type<Released>().length() == 2);
    assert!(!has_reservation(&mut scenario, entity_id, MOD_A));
    assert!(!has_reservation(&mut scenario, entity_id, MOD_B));
    assert!(has_reservation(&mut scenario, entity_id, MOD_C));
    assert!(used(&mut scenario, entity_id) == 10);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun release_priority_zero_releases_default_group() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    connect(&mut scenario, entity_id, MOD_B, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_B, 10, &clock);

    release_priority(&mut scenario, entity_id, 0, &clock);
    assert!(event::events_by_type<Released>().length() == 2);
    assert!(used(&mut scenario, entity_id) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = access_cap::ENotOwner)]
fun reserve_with_other_entity_cap_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);

    // OWNER also holds the cap of a second entity; it must not reserve on the first.
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut other = claim(&mut registry, &acl, 2, scenario.ctx());
    let mut req = other.mint_access(OWNER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    other.complete_request(req);
    let other_id = other.id();
    other.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let other_cap = ts::take_from_sender<AccessCap>(&scenario);
    assert!(other_cap.entity() == other_id);
    let mut req = e.interact(string::utf8(b"operate_grid"), scenario.ctx());
    access_cap::verify(&mut req, &other_cap);

    abort
}

#[test]
fun assert_reserved_passes_on_matching_reservation() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 20, &clock);

    grid_scenario::temp_action!(
        &mut scenario,
        entity_id,
        power_grid::reserve_requirement(MOD_A, 20, power_grid::firm()),
        |e, req| power_grid::assert_reserved(e, req, &clock),
    );

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::ENotReserved)]
fun assert_reserved_without_reservation_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);

    grid_scenario::temp_action!(
        &mut scenario,
        entity_id,
        power_grid::reserve_requirement(MOD_A, 1, power_grid::firm()),
        |e, req| power_grid::assert_reserved(e, req, &clock),
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EDrawBelowMin)]
fun assert_reserved_short_draw_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    connect(&mut scenario, entity_id, MOD_B, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 40, &clock);
    // Elastic asks 30 but only 10 is left.
    reserve_elastic(&mut scenario, entity_id, MOD_B, 30, &clock);

    grid_scenario::temp_action!(
        &mut scenario,
        entity_id,
        power_grid::reserve_requirement(MOD_B, 30, power_grid::elastic()),
        |e, req| power_grid::assert_reserved(e, req, &clock),
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EDrawKindMismatch)]
fun assert_reserved_wrong_kind_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, true, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    reserve_elastic(&mut scenario, entity_id, MOD_A, 10, &clock);

    grid_scenario::temp_action!(
        &mut scenario,
        entity_id,
        power_grid::reserve_requirement(MOD_A, 10, power_grid::firm()),
        |e, req| power_grid::assert_reserved(e, req, &clock),
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EModulesRegistered)]
fun grid_uninstall_with_registered_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut req = power_grid::install(&mut e, &clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    install_consumer(&mut e, &acl, MOD_A, scenario.ctx());
    enable_admin(
        &mut e,
        &acl,
        b"manage_module",
        power_grid::manage_module_requirement(),
        scenario.ctx(),
    );
    let mut req = e.interact(string::utf8(b"manage_module"), scenario.ctx());
    power_grid::connect_module(&mut e, &mut req, MOD_A, 0, &clock);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let _req = power_grid::uninstall(&mut e, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = power_grid::ETooManyConnected)]
fun register_past_max_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, false, &clock);

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let acl = take_acl(&scenario);
    101u64.do!(|i| install_consumer(&mut e, &acl, BULK_BASE + i, scenario.ctx()));
    ts::return_shared(acl);
    ts::return_shared(e);

    // 100 connect_module; the 101st aborts.
    101u64.do!(|i| connect(&mut scenario, entity_id, BULK_BASE + i, 0, 0, &clock));

    abort
}
