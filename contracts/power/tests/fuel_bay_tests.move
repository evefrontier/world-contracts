#[test_only]
module power::fuel_bay_tests;

use core::{entity::Entity, test_helpers::setup};
use power::{
    fuel_math,
    grid_fuel::{
        Self,
        FuelRestored,
        FuelUnstashed,
        FuelStashed,
        FuelAdded,
        FuelBayAttached,
        FuelBayToggled,
        FuelLoadDestroyed
    },
    grid_scenario::{
        Self,
        admin,
        bay_fuel,
        burden,
        catch_up,
        deposit_fuel,
        deposit_fuel_into,
        deposit_fuel_via,
        draw,
        destroy_stash,
        enable_manage_stash,
        enable_owner_in_handler,
        firm_power,
        move_stash,
        refit_stash,
        fuel_bay_id,
        fuel_capacity,
        fuel_type,
        impulse,
        install_fuel,
        install_module,
        owner,
        power_up,
        projected,
        projected_bay_amount,
        set_desired,
        set_fuel_bay,
        setup_empty_grid,
        setup_empty_grid_in_tenant,
        setup_entity,
        settled_fuel,
        starting_fuel,
        starting_units,
        stashed_fuel,
        uninstall_fuel,
        volatility
    },
    power_grid
};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const FUEL_B: u64 = 9_002;
const MOD_A: u64 = 401;
/// 15 MW.
const OUTPUT: u64 = 15;
/// 10 MW.
const DRAW: u64 = 10;
/// Containment reduction 10.
const CONTAINMENT: u64 = 10;
const GATED_DEPOSIT: vector<u8> = b"gated_deposit";
const OTHER_TYPE: u64 = 8;
const BANNED_TYPE: u64 = 9;
/// Plain units.
const BAY_B_CAPACITY: u64 = 2_000;

// === Helpers ===

/// One online Generator of `OUTPUT`, grid on, `MOD_A` desired and drawing `DRAW`.
fun loaded(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[OUTPUT], vector[CONTAINMENT], clock);
    power_up(scenario, entity_id, 1, clock);
    install_module(scenario, entity_id, MOD_A, firm_power(DRAW), clock);
    set_desired(scenario, entity_id, MOD_A, true, clock);
    entity_id
}

/// The overview's blend: fuel A (1000 units) and fuel B (500 units) loaded into
/// `FUEL_B`, the only bay, online. A 10 MW Generator at reduction 10 sends out
/// 10 MW to `MOD_A`.
fun overview_blend(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[DRAW], vector[CONTAINMENT], clock);
    uninstall_fuel(scenario, entity_id, fuel_bay_id(), clock);
    install_fuel(scenario, entity_id, FUEL_B, BAY_B_CAPACITY, clock);
    deposit_fuel_into(scenario, entity_id, FUEL_B, 1_000, 25, 4, 6, clock);
    deposit_fuel_into(scenario, entity_id, FUEL_B, 500, 90, 14, 5, clock);
    set_fuel_bay(scenario, entity_id, FUEL_B, true, clock);
    power_up(scenario, entity_id, 1, clock);
    install_module(scenario, entity_id, MOD_A, firm_power(DRAW), clock);
    set_desired(scenario, entity_id, MOD_A, true, clock);
    entity_id
}

/// A grid whose owner action `GATED_DEPOSIT` accepts fuel types `fuel_type()` and
/// `OTHER_TYPE`, impulse >= 50, burden <= 15, and 10 to 1_000 units per deposit.
fun gated_deposit(scenario: &mut ts::Scenario, clock: &Clock): ID {
    let entity_id = setup_entity(scenario, vector[], vector[], clock);
    enable_owner_in_handler(
        scenario,
        entity_id,
        GATED_DEPOSIT,
        power_grid::deposit_fuel_requirement(
            vector[fuel_type(), OTHER_TYPE],
            option::some(50),
            option::some(15),
            option::some(10),
            option::some(1_000),
        ),
    );
    entity_id
}

/// Deposit through `GATED_DEPOSIT` into the default bay.
fun gated(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    fuel_type: u64,
    amount: u64,
    impulse: u64,
    burden: u64,
    clock: &Clock,
) {
    deposit_fuel_via(
        scenario,
        entity_id,
        GATED_DEPOSIT,
        fuel_bay_id(),
        fuel_type,
        amount,
        impulse,
        burden,
        volatility(),
        clock,
    );
}

fun bay_online(scenario: &mut ts::Scenario, entity_id: ID, fuel_bay_id: u64): bool {
    ts::next_tx(scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let online = power_grid::fuel_bay_state(&entity, fuel_bay_id).bay_online();
    ts::return_shared(entity);
    online
}

// === Fuel factor ===

#[test]
fun fuel_factor_matches_client() {
    // impulse 90, burden 14, reduction 10 -> 90 / 1.4 = 64.2857
    assert!(fuel_math::fuel_factor(90, 14, 10) == 642_857);
    // impulse 10, burden 3, reduction 10 -> burden ratio floors at 1 -> 10
    assert!(fuel_math::fuel_factor(10, 3, 10) == 100_000);
    // impulse 0 clamps up to 1
    assert!(fuel_math::fuel_factor(0, 3, 10) == 10_000);
    // impulse 200 clamps down to 100
    assert!(fuel_math::fuel_factor(200, 3, 10) == 1_000_000);
    // reduction 0 floors at 1 -> 90 / 14 = 6.4285
    assert!(fuel_math::fuel_factor(90, 14, 0) == 64_285);
}

// === Install and uninstall ===

#[test]
fun install_fuel_bay_starts_offline_and_empty() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, BAY_B_CAPACITY, &clock);

    let attached = event::events_by_type<FuelBayAttached>();
    let (_, attached_bay, attached_capacity) = attached[0].fuel_bay_attached_fields();
    assert!(attached_bay == FUEL_B && attached_capacity == BAY_B_CAPACITY);
    ts::next_tx(&mut scenario, owner());
    let entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(power_grid::is_fuel_bay_connected(&entity, FUEL_B));
    let state = power_grid::fuel_bay_state(&entity, FUEL_B);
    assert!(state.capacity() == BAY_B_CAPACITY && !state.bay_online());
    assert!(state.fuel().quantity() == 0);
    ts::return_shared(entity);

    clock.destroy_for_testing();
    scenario.end();
}

/// Uninstalling stashes the bay's exact fuel on the grid; the other bay keeps its own.
#[test]
fun uninstall_stashes_the_bays_exact_fuel() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, BAY_B_CAPACITY, &clock);
    deposit_fuel_into(&mut scenario, entity_id, FUEL_B, 7, 25, 4, 6, &clock);

    uninstall_fuel(&mut scenario, entity_id, FUEL_B, &clock);

    let stashed = event::events_by_type<FuelStashed>();
    let (stashed_entity, stashed_bay, quantity, stashed_volatility) = stashed[
        0,
    ].fuel_stashed_fields();
    assert!(stashed_entity == entity_id && stashed_bay == FUEL_B);
    assert!(quantity == 70_000 && stashed_volatility == 6);
    let fuel = stashed_fuel(&mut scenario, entity_id, FUEL_B).destroy_some();
    assert!(fuel.quantity() == 70_000 && fuel.impulse() == 25);
    assert!(fuel.containment_burden() == 4 && fuel.volatility() == 6);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());

    clock.destroy_for_testing();
    scenario.end();
}

/// A stash never burns, even when it came from the only online bay.
#[test]
fun stashed_fuel_never_burns() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);
    clock.set_for_testing(10_000);
    let left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);

    uninstall_fuel(&mut scenario, entity_id, fuel_bay_id(), &clock);
    clock.set_for_testing(1_000_000);

    assert!(
        stashed_fuel(&mut scenario, entity_id, fuel_bay_id()).destroy_some().quantity() == left,
    );
    let (fuel_left, capacity, _, _) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == 0 && capacity == 0);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// Refitting the bay takes its stash back, offline; it feeds the grid once online.
#[test]
fun reinstall_takes_back_its_stash_offline() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    uninstall_fuel(&mut scenario, entity_id, fuel_bay_id(), &clock);

    install_fuel(&mut scenario, entity_id, fuel_bay_id(), fuel_capacity(), &clock);

    let restored = event::events_by_type<FuelRestored>();
    let (_, restored_bay, restored_quantity, _) = restored[0].fuel_restored_fields();
    assert!(restored_bay == fuel_bay_id() && restored_quantity == starting_fuel());
    assert!(stashed_fuel(&mut scenario, entity_id, fuel_bay_id()).is_none());
    let fuel = bay_fuel(&mut scenario, entity_id, fuel_bay_id());
    assert!(fuel.quantity() == starting_fuel());
    assert!(fuel.impulse() == impulse() && fuel.containment_burden() == burden());
    assert!(fuel.volatility() == volatility());
    assert!(settled_fuel(&mut scenario, entity_id) == 0);
    set_fuel_bay(&mut scenario, entity_id, fuel_bay_id(), true, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());

    clock.destroy_for_testing();
    scenario.end();
}

/// A different bay id does not take another bay's stash.
#[test]
fun other_bay_does_not_take_the_stash() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    uninstall_fuel(&mut scenario, entity_id, fuel_bay_id(), &clock);

    install_fuel(&mut scenario, entity_id, FUEL_B, BAY_B_CAPACITY, &clock);

    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == 0);
    assert!(stashed_fuel(&mut scenario, entity_id, fuel_bay_id()).is_some());

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_fuel::EFuelOverCapacity)]
fun reinstall_smaller_than_its_stash_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    // The default bay holds 50_000 units, more than a 2_000 unit bay takes.
    uninstall_fuel(&mut scenario, entity_id, fuel_bay_id(), &clock);

    install_fuel(&mut scenario, entity_id, fuel_bay_id(), BAY_B_CAPACITY, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelBayNotConnected)]
fun uninstall_unknown_fuel_bay_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    uninstall_fuel(&mut scenario, entity_id, FUEL_B, &clock);

    abort
}

// === Take, stash and destroy ===

/// The stash follows the bay item to another grid, and a refit there takes it back.
#[test]
fun move_stash_carries_fuel_to_another_grid() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);
    uninstall_fuel(&mut scenario, from, fuel_bay_id(), &clock);
    enable_manage_stash(&mut scenario, from);
    enable_manage_stash(&mut scenario, to);

    move_stash(&mut scenario, admin(), from, to, fuel_bay_id());

    let taken = event::events_by_type<FuelUnstashed>();
    let (taken_entity, taken_bay, taken_quantity, _) = taken[0].fuel_unstashed_fields();
    assert!(taken_entity == from && taken_bay == fuel_bay_id());
    assert!(taken_quantity == starting_fuel());
    let stashed = event::events_by_type<FuelStashed>();
    let (stashed_entity, _, stashed_quantity, _) = stashed[0].fuel_stashed_fields();
    assert!(stashed_entity == to && stashed_quantity == starting_fuel());
    assert!(stashed_fuel(&mut scenario, from, fuel_bay_id()).is_none());
    install_fuel(&mut scenario, to, fuel_bay_id(), fuel_capacity(), &clock);
    let fuel = bay_fuel(&mut scenario, to, fuel_bay_id());
    assert!(fuel.quantity() == starting_fuel() && fuel.impulse() == impulse());

    clock.destroy_for_testing();
    scenario.end();
}

/// The stash can be refitted straight onto another Creation's bay.
#[test]
fun take_stash_refits_on_another_grid() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);
    uninstall_fuel(&mut scenario, from, fuel_bay_id(), &clock);
    enable_manage_stash(&mut scenario, from);

    refit_stash(&mut scenario, admin(), from, to, fuel_bay_id(), fuel_capacity(), &clock);

    assert!(stashed_fuel(&mut scenario, from, fuel_bay_id()).is_none());
    let fuel = bay_fuel(&mut scenario, to, fuel_bay_id());
    assert!(fuel.quantity() == starting_fuel() && fuel.volatility() == volatility());

    clock.destroy_for_testing();
    scenario.end();
}

/// Destroying a stash removes its fuel and frees the grid to be uninstalled.
#[test]
fun destroy_stash_removes_the_fuel() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    uninstall_fuel(&mut scenario, entity_id, fuel_bay_id(), &clock);
    enable_manage_stash(&mut scenario, entity_id);

    destroy_stash(&mut scenario, admin(), entity_id, fuel_bay_id());

    let destroyed = event::events_by_type<FuelLoadDestroyed>();
    let (destroyed_entity, destroyed_bay, destroyed_quantity, _) = destroyed[
        0,
    ].fuel_load_destroyed_fields();
    assert!(destroyed_entity == entity_id && destroyed_bay == fuel_bay_id());
    assert!(destroyed_quantity == starting_fuel());
    assert!(stashed_fuel(&mut scenario, entity_id, fuel_bay_id()).is_none());

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_fuel::EStashMissing)]
fun take_stash_without_stash_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    enable_manage_stash(&mut scenario, entity_id);

    destroy_stash(&mut scenario, admin(), entity_id, fuel_bay_id());

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EStashExists)]
fun stash_load_onto_a_fitted_bay_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    let to = setup_empty_grid(&mut scenario, 2, &clock);
    uninstall_fuel(&mut scenario, from, fuel_bay_id(), &clock);
    install_fuel(&mut scenario, to, fuel_bay_id(), fuel_capacity(), &clock);
    enable_manage_stash(&mut scenario, from);
    enable_manage_stash(&mut scenario, to);

    move_stash(&mut scenario, admin(), from, to, fuel_bay_id());

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EWrongTenant)]
fun stash_load_across_tenants_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let from = setup_entity(&mut scenario, vector[], vector[], &clock);
    let to = setup_empty_grid_in_tenant(&mut scenario, 2, b"OTHER", &clock);
    uninstall_fuel(&mut scenario, from, fuel_bay_id(), &clock);
    enable_manage_stash(&mut scenario, from);
    enable_manage_stash(&mut scenario, to);

    move_stash(&mut scenario, admin(), from, to, fuel_bay_id());

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EWrongFuelBay)]
fun refit_load_on_another_bay_id_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    uninstall_fuel(&mut scenario, entity_id, fuel_bay_id(), &clock);
    enable_manage_stash(&mut scenario, entity_id);

    ts::next_tx(&mut scenario, admin());
    let mut entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let (_req, load) = grid_scenario::take_stash(&mut entity, fuel_bay_id(), scenario.ctx());
    let _install = grid_fuel::install_with_fuel(
        &mut entity,
        FUEL_B,
        option::none(),
        fuel_capacity(),
        load,
        &clock,
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = core::admin_service::EUnauthorizedAdmin)]
fun take_stash_by_non_admin_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    uninstall_fuel(&mut scenario, entity_id, fuel_bay_id(), &clock);
    enable_manage_stash(&mut scenario, entity_id);

    destroy_stash(&mut scenario, owner(), entity_id, fuel_bay_id());

    abort
}

// === Online and offline ===

#[test]
fun set_fuel_bay_toggles_online() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, BAY_B_CAPACITY, &clock);

    set_fuel_bay(&mut scenario, entity_id, FUEL_B, true, &clock);

    let toggled = event::events_by_type<FuelBayToggled>();
    let (_, toggled_bay, toggled_online) = toggled[0].fuel_bay_toggled_fields();
    assert!(toggled_bay == FUEL_B && toggled_online);
    assert!(bay_online(&mut scenario, entity_id, FUEL_B));
    set_fuel_bay(&mut scenario, entity_id, FUEL_B, false, &clock);
    assert!(!bay_online(&mut scenario, entity_id, FUEL_B));

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_fuel::EFuelBayAlreadyOnline)]
fun set_fuel_bay_online_twice_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);

    set_fuel_bay(&mut scenario, entity_id, fuel_bay_id(), true, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelBayAlreadyOffline)]
fun set_fuel_bay_offline_while_offline_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, BAY_B_CAPACITY, &clock);

    set_fuel_bay(&mut scenario, entity_id, FUEL_B, false, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelBayNotConnected)]
fun set_unknown_fuel_bay_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);

    set_fuel_bay(&mut scenario, entity_id, FUEL_B, true, &clock);

    abort
}

/// A reserve bay keeps its fuel while the online bay burns.
#[test]
fun offline_bay_keeps_its_fuel() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, BAY_B_CAPACITY, &clock);
    deposit_fuel_into(&mut scenario, entity_id, FUEL_B, 7, impulse(), burden(), 0, &clock);

    clock.set_for_testing(10_000);
    assert!(projected_bay_amount(&mut scenario, entity_id, FUEL_B, &clock) == 70_000);
    let default_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    assert!(default_left == starting_fuel() - 15_556);
    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == 70_000);

    clock.destroy_for_testing();
    scenario.end();
}

/// With every fuel-holding bay offline the grid has no capacity; bringing the
/// bay back regrants.
#[test]
fun all_fuel_offline_cuts_power() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    set_fuel_bay(&mut scenario, entity_id, fuel_bay_id(), false, &clock);
    let (fuel_left, capacity, _, _) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == 0 && capacity == 0);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);

    set_fuel_bay(&mut scenario, entity_id, fuel_bay_id(), true, &clock);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == DRAW);

    clock.destroy_for_testing();
    scenario.end();
}

// === Deposit ===

/// Equal amounts average the stats: impulse (90 + 10) / 2, burden (14 + 4) / 2,
/// volatility (1 + 7) / 2.
#[test]
fun deposit_blends_by_weighted_average() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel_into(
        &mut scenario,
        entity_id,
        fuel_bay_id(),
        starting_units(),
        10,
        4,
        7,
        &clock,
    );

    let added = event::events_by_type<FuelAdded>();
    assert!(added.length() == 1);
    let (_, bay, _, amount, resulting, impulse, burden, volatility) = added[0].fuel_added_fields();
    assert!(bay == fuel_bay_id() && amount == starting_units());
    assert!(resulting == 2 * starting_fuel());
    assert!(impulse == 50 && burden == 9 && volatility == 4);
    assert!(settled_fuel(&mut scenario, entity_id) == 2 * starting_fuel());

    clock.destroy_for_testing();
    scenario.end();
}

/// The overview's blend: 1000 units of A and 500 of B. Stats round down to whole
/// numbers: impulse 46.67 to 46, burden 7.33 to 7.
#[test]
fun deposit_matches_overview_blend() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = overview_blend(&mut scenario, &clock);

    let fuel = bay_fuel(&mut scenario, entity_id, FUEL_B);
    assert!(fuel.quantity() == 15_000_000);
    assert!(fuel.impulse() == 46);
    assert!(fuel.containment_burden() == 7);
    assert!(fuel.volatility() == 5);

    clock.destroy_for_testing();
    scenario.end();
}

/// A deposit blends only the bay it names.
#[test]
fun deposit_blends_only_its_bay() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, BAY_B_CAPACITY, &clock);

    deposit_fuel_into(&mut scenario, entity_id, FUEL_B, 7, 10, 4, 7, &clock);

    let default_fuel = bay_fuel(&mut scenario, entity_id, fuel_bay_id());
    assert!(default_fuel.quantity() == starting_fuel() && default_fuel.impulse() == impulse());
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).impulse() == 10);

    clock.destroy_for_testing();
    scenario.end();
}

/// A tiny deposit pulls the average down by less than one whole step: the
/// blend rounds down.
#[test]
fun deposit_blend_rounds_down() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel(&mut scenario, entity_id, 3, 1, 14, &clock);

    let fuel = bay_fuel(&mut scenario, entity_id, fuel_bay_id());
    assert!(fuel.impulse() == 89);
    assert!(fuel.containment_burden() == 14);

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_fuel::EFuelOverCapacity)]
fun deposit_over_capacity_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    let room = fuel_capacity() - starting_units();
    deposit_fuel(&mut scenario, entity_id, room + 1, impulse(), burden(), &clock);

    abort
}

#[test]
fun deposit_up_to_capacity_succeeds() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    let room = fuel_capacity() - starting_units();
    deposit_fuel(&mut scenario, entity_id, room, impulse(), burden(), &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == fuel_capacity() * power_grid::scale());

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_fuel::EFuelBayNotConnected)]
fun deposit_into_unknown_bay_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel_into(&mut scenario, entity_id, FUEL_B, 7, impulse(), burden(), 0, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EZeroFuel)]
fun deposit_zero_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    deposit_fuel(&mut scenario, entity_id, 0, impulse(), burden(), &clock);

    abort
}

#[test]
fun deposit_meeting_fuel_requirement_succeeds() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    gated(&mut scenario, entity_id, fuel_type(), 500, 60, 10, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel() + 500 * power_grid::scale());

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = grid_fuel::EFuelTypeNotAllowed)]
fun deposit_disallowed_fuel_type_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    gated(&mut scenario, entity_id, BANNED_TYPE, 500, 60, 10, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EImpulseBelowMin)]
fun deposit_low_impulse_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    gated(&mut scenario, entity_id, fuel_type(), 500, 40, 10, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EBurdenAboveMax)]
fun deposit_high_burden_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    gated(&mut scenario, entity_id, fuel_type(), 500, 60, 20, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelAmountBelowMin)]
fun deposit_below_min_amount_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    gated(&mut scenario, entity_id, fuel_type(), 5, 60, 10, &clock);

    abort
}

#[test, expected_failure(abort_code = grid_fuel::EFuelAmountAboveMax)]
fun deposit_above_max_amount_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = gated_deposit(&mut scenario, &clock);
    gated(&mut scenario, entity_id, fuel_type(), 2_000, 60, 10, &clock);

    abort
}

// === Burn ===

/// 10 MW at factor 64.2857 burns 0.15556 units/s: 15_556 at `SCALE` over 10 s,
/// rounded up. The view matches the state after the next settle.
#[test]
fun burn_over_time_and_view_matches_settle() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);

    clock.set_for_testing(10_000);
    let (fuel_left, capacity, used_mw, online) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == starting_fuel() - 15_556);
    assert!(capacity == OUTPUT);
    assert!(used_mw == DRAW);
    assert!(online == vector[MOD_A]);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());

    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == fuel_left);

    clock.destroy_for_testing();
    scenario.end();
}

/// The overview's generator example: 10 MW on the blend (factor 46, rounded
/// down from 46.67) burns 0.2174 units in a second.
#[test]
fun overview_blend_burns_at_its_factor() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = overview_blend(&mut scenario, &clock);

    clock.set_for_testing(1_000);
    let (fuel_left, _, _, _) = projected(&mut scenario, entity_id, &clock);
    assert!(fuel_left == 15_000_000 - 2_174);

    clock.destroy_for_testing();
    scenario.end();
}

/// Two online bays share the burn by what they hold: 4/5 and 1/5 of 15_556.
/// The rounding remainder comes off the larger bay, and the view matches the settle.
#[test]
fun online_bays_burn_in_proportion() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, fuel_capacity(), &clock);
    let quarter = starting_units() / 4;
    deposit_fuel_into(
        &mut scenario,
        entity_id,
        FUEL_B,
        quarter,
        impulse(),
        burden(),
        volatility(),
        &clock,
    );
    set_fuel_bay(&mut scenario, entity_id, FUEL_B, true, &clock);

    clock.set_for_testing(10_000);
    let default_left = projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock);
    let b_left = projected_bay_amount(&mut scenario, entity_id, FUEL_B, &clock);
    assert!(default_left == starting_fuel() - 12_445);
    assert!(b_left == quarter * power_grid::scale() - 3_111);

    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(bay_fuel(&mut scenario, entity_id, fuel_bay_id()).quantity() == default_left);
    assert!(bay_fuel(&mut scenario, entity_id, FUEL_B).quantity() == b_left);

    clock.destroy_for_testing();
    scenario.end();
}

/// Online bays run dry at the same moment, and the module loses its grant.
#[test]
fun online_bays_run_dry_together() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);
    install_fuel(&mut scenario, entity_id, FUEL_B, fuel_capacity(), &clock);
    deposit_fuel_into(
        &mut scenario,
        entity_id,
        FUEL_B,
        starting_units() / 4,
        impulse(),
        burden(),
        volatility(),
        &clock,
    );
    set_fuel_bay(&mut scenario, entity_id, FUEL_B, true, &clock);

    clock.set_for_testing(10_000_000_000);
    assert!(projected_bay_amount(&mut scenario, entity_id, fuel_bay_id(), &clock) == 0);
    assert!(projected_bay_amount(&mut scenario, entity_id, FUEL_B, &clock) == 0);
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);
    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == 0);

    clock.destroy_for_testing();
    scenario.end();
}

/// Stored fuel still shows the full tank. The check must burn first, then fail.
#[test, expected_failure(abort_code = power_grid::EFuelBelowMin)]
fun assert_power_grid_rejects_fuel_already_burned() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);

    clock.set_for_testing(10_000);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());
    grid_scenario::temp_action!(
        &mut scenario,
        entity_id,
        power_grid::power_grid_requirement(
            true,
            option::some(starting_units()),
            option::none(),
            0,
            option::none(),
        ),
        |entity, req| power_grid::assert_power_grid(entity, req, &clock),
    );

    abort
}

/// impulse 90, burden 14, 120 MW of 150 MW. Gen A (100 MW, reduction 10) serves
/// 80 MW at factor 64.2857; Gen B (50 MW, reduction 1) serves 40 MW at factor
/// 6.4285. 12_445 + 62_223 per second at `SCALE`.
#[test]
fun each_generator_burns_its_share() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(
        &mut scenario,
        vector[100, 50],
        vector[10, 1],
        &clock,
    );
    power_up(&mut scenario, entity_id, 2, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(120), &clock);
    set_desired(&mut scenario, entity_id, MOD_A, true, &clock);

    clock.set_for_testing(1_000);
    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel() - (12_445 + 62_223));

    clock.destroy_for_testing();
    scenario.end();
}

/// Ten 100 ms settles burn 10 × 156; one 1 s settle burns 1_556. Rounding up
/// costs at most one step per settle and never gives free power.
#[test]
fun frequent_settles_never_burn_less() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = loaded(&mut scenario, &clock);

    10u64.do!(|i| {
        clock.set_for_testing((i + 1) * 100);
        catch_up(&mut scenario, entity_id, MOD_A, &clock);
    });
    let frequent = starting_fuel() - settled_fuel(&mut scenario, entity_id);
    assert!(frequent == 1_560);

    clock.set_for_testing(2_000);
    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    let once = starting_fuel() - frequent - settled_fuel(&mut scenario, entity_id);
    assert!(once == 1_556);

    clock.destroy_for_testing();
    scenario.end();
}

/// No load, no burn: an idle powered grid keeps its fuel.
#[test]
fun idle_grid_burns_nothing() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[OUTPUT], vector[CONTAINMENT], &clock);
    power_up(&mut scenario, entity_id, 1, &clock);
    install_module(&mut scenario, entity_id, MOD_A, firm_power(DRAW), &clock);

    clock.set_for_testing(1_000_000);
    catch_up(&mut scenario, entity_id, MOD_A, &clock);
    assert!(settled_fuel(&mut scenario, entity_id) == starting_fuel());
    assert!(draw(&mut scenario, entity_id, MOD_A, &clock) == 0);

    clock.destroy_for_testing();
    scenario.end();
}
