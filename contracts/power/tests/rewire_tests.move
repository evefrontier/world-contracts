#[test_only]
module power::rewire_tests;

use core::{entity::Entity, test_helpers::setup};
use power::{
    grid_load::{Self, ModuleDisconnected, Released},
    grid_scenario::{
        Self,
        active,
        connect,
        connect_module,
        disconnect_module,
        has_reservation,
        reserve_firm,
        set_priority,
        used
    },
    power_grid
};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const OUTPUT: u64 = 50;
const MOD_A: u64 = 401;
const MOD_B: u64 = 402;

// === Helpers ===

/// A powered grid with one Generator of `OUTPUT` and modules A and B installed.
fun setup_entity(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = grid_scenario::setup_entity(
        scenario,
        vector[OUTPUT],
        vector[MOD_A, MOD_B],
        clock,
    );
    grid_scenario::power_up(scenario, entity_id, 1, clock);
    entity_id
}

// === Tests ===

#[test]
fun disconnect_while_active_frees_capacity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    connect(&mut scenario, entity_id, MOD_A, 5, 0, &clock);
    connect(&mut scenario, entity_id, MOD_B, 0, 0, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 45, &clock);
    assert!(used(&mut scenario, entity_id) == 50);

    disconnect_module(&mut scenario, entity_id, MOD_A, &clock);
    let released = event::events_by_type<Released>();
    assert!(released.length() == 1);
    let (_, released_id) = released[0].released_fields();
    assert!(released_id == MOD_A);
    assert!(event::events_by_type<ModuleDisconnected>().length() == 1);
    assert!(!has_reservation(&mut scenario, entity_id, MOD_A));
    assert!(used(&mut scenario, entity_id) == 0);

    // The freed capacity is usable by another module.
    reserve_firm(&mut scenario, entity_id, MOD_B, 50, &clock);
    assert!(active(&mut scenario, entity_id, MOD_B) == 50);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun reconnect_resets_line_loss_and_priority() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    connect(&mut scenario, entity_id, MOD_A, 5, 3, &clock);

    disconnect_module(&mut scenario, entity_id, MOD_A, &clock);
    assert!(event::events_by_type<Released>().is_empty());
    connect_module(&mut scenario, entity_id, MOD_A, 2, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        let grid = power_grid::power_grid(&e);
        assert!(grid.module_state(MOD_A).line_loss() == 2);
        assert!(grid.priority(MOD_A) == 0);
        ts::return_shared(e);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::ENotConnected)]
fun reserve_after_disconnect_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    disconnect_module(&mut scenario, entity_id, MOD_A, &clock);
    reserve_firm(&mut scenario, entity_id, MOD_A, 10, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::ENotConnected)]
fun set_priority_after_disconnect_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    disconnect_module(&mut scenario, entity_id, MOD_A, &clock);
    set_priority(&mut scenario, entity_id, MOD_A, 1, &clock);

    abort
}

/// A connected module cannot be uninstalled until it is disconnected.
#[test, expected_failure(abort_code = grid_load::EModuleStillConnected)]
fun uninstall_while_connected_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);

    ts::next_tx(&mut scenario, ADMIN);
    let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    grid_load::assert_disconnected(&e, MOD_A);
    abort
}

/// Once disconnected, the module passes the uninstall check.
#[test]
fun uninstall_after_disconnect_passes() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    connect(&mut scenario, entity_id, MOD_A, 0, 0, &clock);
    disconnect_module(&mut scenario, entity_id, MOD_A, &clock);

    ts::next_tx(&mut scenario, ADMIN);
    let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    grid_load::assert_disconnected(&e, MOD_A);
    ts::return_shared(e);
    clock.destroy_for_testing();
    scenario.end();
}
