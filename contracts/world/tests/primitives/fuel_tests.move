#[test_only]

module world::fuel_tests;

use std::unit_test::assert_eq;
use sui::{clock, derived_object, test_scenario as ts};
use world::{
    access::AdminCap,
    fuel::{Self, FuelConfig, Fuel},
    in_game_id::{create_key, TenantItemId},
    object_registry::ObjectRegistry,
    test_helpers::{
        Self,
        tenant,
        admin,
        user_a,
        fuel_type_1,
        fuel_type_2,
        fuel_type_3,
        fuel_efficiency_1,
        fuel_efficiency_2,
        fuel_efficiency_3
    }
};

const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_SECONDS: u64 = 3600;
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;
const DEPOSIT_AMOUNT: u64 = 50;
const WITHDRAW_AMOUNT: u64 = 20;

// Time conversion constants
const MS_PER_SECOND: u64 = 1000;
const SECONDS_PER_MINUTE: u64 = 60;
const MS_PER_MINUTE: u64 = SECONDS_PER_MINUTE * MS_PER_SECOND; // 60,000
const MS_PER_HOUR: u64 = 60 * MS_PER_MINUTE; // 3,600,000

public struct NetworkNode has key {
    id: UID,
    key: TenantItemId,
    fuel: Fuel,
}

// === Test Helper Functions ===
fun fuel_deposit(
    nwn: &mut NetworkNode,
    type_id: u64,
    volume: u64,
    quantity: u64,
    clock: &clock::Clock,
) {
    let nwn_id = object::id(nwn);
    let nwn_key = nwn.key;
    nwn.fuel.deposit(nwn_id, nwn_key, type_id, volume, quantity, clock);
}

fun fuel_withdraw(nwn: &mut NetworkNode, quantity: u64) {
    let nwn_id = object::id(nwn);
    let nwn_key = nwn.key;
    nwn.fuel.withdraw(nwn_id, nwn_key, quantity);
}

fun fuel_start_burning(nwn: &mut NetworkNode, clock: &clock::Clock) {
    let nwn_id = object::id(nwn);
    let nwn_key = nwn.key;
    nwn.fuel.start_burning(nwn_id, nwn_key, clock);
}

fun fuel_stop_burning(nwn: &mut NetworkNode, fuel_config: &FuelConfig, clock: &clock::Clock) {
    let nwn_id = object::id(nwn);
    let nwn_key = nwn.key;
    nwn.fuel.stop_burning(nwn_id, nwn_key, fuel_config, clock);
}

fun fuel_update(nwn: &mut NetworkNode, fuel_config: &FuelConfig, clock: &clock::Clock) {
    let nwn_id = object::id(nwn);
    let nwn_key = nwn.key;
    nwn.fuel.update(nwn_id, nwn_key, fuel_config, clock);
}

// Helper Functions
fun create_network_node(ts: &mut ts::Scenario, max_capacity: u64, burn_rate_in_seconds: u64): ID {
    ts::next_tx(ts, admin());
    let nwn_id = {
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let nwn_key = create_key(44444, tenant());
        let nwn_uid = derived_object::claim(registry.borrow_registry_id(), nwn_key);
        let nwn_id = object::uid_to_inner(&nwn_uid);

        let burn_rate_in_ms = burn_rate_in_seconds * MS_PER_SECOND;
        let nwn = NetworkNode {
            id: nwn_uid,
            key: nwn_key,
            fuel: fuel::create(max_capacity, burn_rate_in_ms),
        };
        transfer::share_object(nwn);
        ts::return_shared(registry);
        nwn_id
    };
    nwn_id
}

#[test]
fun set_and_get_fuel_efficiency() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let efficiency_1 = fuel_config.fuel_efficiency(fuel_type_1());
        let efficiency_2 = fuel_config.fuel_efficiency(fuel_type_2());
        let efficiency_3 = fuel_config.fuel_efficiency(fuel_type_3());

        assert_eq!(efficiency_1, fuel_efficiency_1());
        assert_eq!(efficiency_2, fuel_efficiency_2());
        assert_eq!(efficiency_3, fuel_efficiency_3());

        ts::return_shared(fuel_config);
    };

    ts::end(ts);
}

#[test]
fun set_new_fuel_efficiency() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_config.set_fuel_efficiency(&admin_cap, 4, 95);

        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::next_tx(&mut ts, admin());
    {
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let efficiency = fuel_config.fuel_efficiency(4);
        assert_eq!(efficiency, 95);

        ts::return_shared(fuel_config);
    };

    ts::end(ts);
}

#[test]
fun unset_fuel_efficiency() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_config.unset_fuel_efficiency(&admin_cap, fuel_type_2());

        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::next_tx(&mut ts, admin());
    {
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        // Should still be able to get other types
        let efficiency_1 = fuel_config.fuel_efficiency(fuel_type_1());
        assert_eq!(efficiency_1, fuel_efficiency_1());

        ts::return_shared(fuel_config);
    };

    ts::end(ts);
}

#[test]
fun update_existing_fuel_efficiency() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);

    // Update an existing fuel type efficiency
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_config.set_fuel_efficiency(&admin_cap, fuel_type_1(), 85);

        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::next_tx(&mut ts, admin());
    {
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let efficiency = fuel_config.fuel_efficiency(fuel_type_1());
        assert_eq!(efficiency, 85);

        ts::return_shared(fuel_config);
    };

    ts::end(ts);
}

#[test]
fun deposit_fuel() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, DEPOSIT_AMOUNT, &clock);
        assert_eq!(nwn.fuel.quantity(), DEPOSIT_AMOUNT);
        assert!(option::is_some(&nwn.fuel.type_id()));
        assert_eq!(*option::borrow(&nwn.fuel.type_id()), FUEL_TYPE_ID);
        assert!(option::is_some(&nwn.fuel.volume()));
        assert_eq!(*option::borrow(&nwn.fuel.volume()), FUEL_VOLUME);
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun deposit_fuel_multiple_times() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);

    let clock = clock::create_for_testing(ts.ctx());
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, DEPOSIT_AMOUNT, &clock);
        assert_eq!(nwn.fuel.quantity(), DEPOSIT_AMOUNT);
        ts::return_shared(nwn);
    };
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, DEPOSIT_AMOUNT, &clock);
        assert_eq!(nwn.fuel.quantity(), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT);
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun withdraw_fuel() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, DEPOSIT_AMOUNT, &clock);
        ts::return_shared(nwn);
    };
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_withdraw(&mut nwn, WITHDRAW_AMOUNT);
        assert_eq!(nwn.fuel.quantity(), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun deposit_and_withdraw_fuel() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, DEPOSIT_AMOUNT, &clock);
        assert_eq!(nwn.fuel.quantity(), DEPOSIT_AMOUNT);
        ts::return_shared(nwn);
    };
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_withdraw(&mut nwn, WITHDRAW_AMOUNT);
        assert_eq!(nwn.fuel.quantity(), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);
        ts::return_shared(nwn);
    };
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, DEPOSIT_AMOUNT, &clock);
        assert_eq!(nwn.fuel.quantity(), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT + DEPOSIT_AMOUNT);
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun start_burning() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        assert_eq!(nwn.fuel.quantity(), 5);
        assert_eq!(nwn.fuel.is_burning(), false);
        ts::return_shared(nwn);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        assert_eq!(nwn.fuel.is_burning(), true);
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun stop_burning() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let mut clock = clock::create_for_testing(ts.ctx());
    let time_start = 1000;
    let time_stop = 2000;

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        clock.set_for_testing(time_start);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.is_burning(), true);
        ts::return_shared(nwn);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_stop);
        fuel_stop_burning(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.is_burning(), false);
        assert_eq!(nwn.fuel.quantity(), 4);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun update_fuel() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let mut clock = clock::create_for_testing(ts.ctx());
    let time_start = 1000;
    let time_after_1_hour = MS_PER_HOUR + time_start;

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        clock.set_for_testing(time_start);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        ts::return_shared(nwn);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_after_1_hour);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 3);
        assert_eq!(nwn.fuel.is_burning(), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun update_fuel_no_change_when_not_burning() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        // Not burning, so update should do nothing
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 5);
        assert_eq!(nwn.fuel.is_burning(), false);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun has_enough_fuel() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let mut clock = clock::create_for_testing(ts.ctx());
    let time_start = 1000;
    let time_after_3_units = time_start + (3 * MS_PER_HOUR) + MS_PER_SECOND; // 3 units consumed (3 hours)
    let time_after_4_units = time_after_3_units + MS_PER_HOUR + MS_PER_SECOND; // 4th unit consumed (4 hours)
    let time_before_last_unit_finishes = time_after_4_units + (30 * MS_PER_MINUTE); // Last unit still burning (30 mins into 5th hour)
    let time_after_all_units = time_start + (5 * MS_PER_HOUR) + MS_PER_SECOND; // All 5 units consumed (5 hours)

    // Scenario 1: Not burning, should return false
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), false);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Scenario 2: Burning with fuel, should return true
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_start);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Scenario 3: After 3 units consumed, still has fuel, should return true
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_after_3_units);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 1);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Scenario 4: Quantity is 0 but last unit is still burning, should return true
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_after_4_units);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Scenario 5: Check again - last unit should still be burning
    ts::next_tx(&mut ts, user_a());
    {
        let nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_before_last_unit_finishes);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Scenario 6: All fuel consumed and burning stopped, should return false
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_after_all_units);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), false);
        fuel_update(&mut nwn, &fuel_config, &clock);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

/// Tests fuel consumption flow with multiple updates at different times, then stopping.
/// Verifies: partial consumption tracking, burn_start_time updates, previous_cycle_elapsed_time
/// preservation, and state transitions. With 100% efficiency, consumption rate is 1 hour per unit.
#[test]
fun fuel_consumption_with_multiple_updates_then_stop() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let mut clock = clock::create_for_testing(ts.ctx());

    let time_10_00 = 1000;
    let time_10_30 = time_10_00 + (30 * MS_PER_MINUTE); // 30 minutes later
    let time_11_00 = time_10_00 + MS_PER_HOUR; // 1 hour later (1 unit consumed)
    let time_12_30 = time_11_00 + (1 * MS_PER_HOUR) + (30 * MS_PER_MINUTE); // 1.5 hours later
    let time_14_00 = time_12_30 + (1 * MS_PER_HOUR) + (30 * MS_PER_MINUTE); // 1.5 hours later

    // Deposit 5 fuel, start burning at 10:00
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        clock.set_for_testing(time_10_00);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_10_00);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Update at 10:30
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_10_30);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 0);
        assert_eq!(remaining_elapsed_ms, 30 * MS_PER_MINUTE);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_10_00);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Update at 11:00
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_11_00);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 1);
        assert_eq!(remaining_elapsed_ms, 0);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 3);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_11_00);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Stop before the last unit
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_12_30);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 1);
        assert_eq!(remaining_elapsed_ms, 30 * MS_PER_MINUTE);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 2);
        assert_eq!(nwn.fuel.is_burning(), true);

        // After update, burn_start_time resets
        clock.set_for_testing(time_14_00);
        let (units_to_consume_after, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume_after, 2);
        assert_eq!(remaining_elapsed_ms, 0);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), true); // Last unit should start burning
        assert_eq!(nwn.fuel.burn_start_time(), time_14_00);

        // stop when last unit is burning
        clock.set_for_testing(time_14_00 + 30 * MS_PER_MINUTE);
        let (units_to_consume_final, remaining_elapsed_ms_final) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume_final, 0);
        assert_eq!(remaining_elapsed_ms_final, 30 * MS_PER_MINUTE);
        fuel_stop_burning(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.is_burning(), false);
        assert_eq!(nwn.fuel.burn_start_time(), 0);
        assert_eq!(nwn.fuel.previous_cycle_elapsed_time(), 30 * MS_PER_MINUTE);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), false);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::ETypeIdEmtpy)]
fun set_fuel_efficiency_with_empty_type_id() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_config.set_fuel_efficiency(&admin_cap, 0, 50); // Should abort

        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EInvalidFuelEfficiency)]
fun set_fuel_efficiency_exceeding_max() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_config.set_fuel_efficiency(&admin_cap, 5, 101); // Should abort

        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::ETypeIdEmtpy)]
fun unset_fuel_efficiency_with_empty_type_id() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_config.unset_fuel_efficiency(&admin_cap, 0); // Should abort

        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EIncorrectFuelType)]
fun get_fuel_efficiency_for_unconfigured_type() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    ts::next_tx(&mut ts, admin());
    {
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let _ = fuel_config.fuel_efficiency(999);
        ts::return_shared(fuel_config);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EInsufficientFuel)]
fun withdraw_insufficient_fuel() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_withdraw(&mut nwn, WITHDRAW_AMOUNT); // Should abort
        ts::return_shared(nwn);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EFuelCapacityExceeded)]
fun deposit_exceeds_capacity() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    let small_capacity: u64 = 100;
    create_network_node(&mut ts, small_capacity, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        // volume * quantity = 10 * 11 = 110 > 100 (capacity)
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 11, &clock); // Should abort
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EFuelTypeMismatch)]
fun deposit_different_fuel_type() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, DEPOSIT_AMOUNT, &clock);
        ts::return_shared(nwn);
    };
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, 2, FUEL_VOLUME, DEPOSIT_AMOUNT, &clock); // Should abort
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EFuelAlreadyBurning)]
fun start_burning_when_already_burning() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        fuel_start_burning(&mut nwn, &clock);
        fuel_start_burning(&mut nwn, &clock); // Should abort
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::ENoFuelToBurn)]
fun start_burning_with_no_fuel() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        // No fuel deposited, quantity is 0
        fuel_start_burning(&mut nwn, &clock); // Should abort
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EFuelNotBurning)]
fun stop_burning_when_not_burning() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        fuel_stop_burning(&mut nwn, &fuel_config, &clock); // Should abort
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EInvalidDepositQuantity)]
fun deposit_with_zero_quantity() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let nwn_id = object::id(&nwn);
        let nwn_key = nwn.key;
        nwn.fuel.deposit(nwn_id, nwn_key, FUEL_TYPE_ID, FUEL_VOLUME, 0, &clock); // Should abort
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EInvalidWithdrawQuantity)]
fun withdraw_with_zero_quantity() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, DEPOSIT_AMOUNT, &clock);
        fuel_withdraw(&mut nwn, 0); // Should abort
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EInvalidVolume)]
fun deposit_with_zero_volume() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, 0, DEPOSIT_AMOUNT, &clock); // Should abort
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::EInvalidFuelEfficiency)]
fun set_fuel_efficiency_below_minimum() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_config.set_fuel_efficiency(&admin_cap, 5, 9); // Should abort (< 10)

        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::ENoFuelToBurn)]
fun start_burning_with_empty_type_id() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        // No fuel deposited, type_id = 0, quantity = 0
        let nwn_id = object::id(&nwn);
        let nwn_key = nwn.key;
        nwn.fuel.start_burning(nwn_id, nwn_key, &clock); // Should abort with ENoFuelToBurn
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

/// Tests complete scenario with stop/start/update when quantity = 0
#[test]
fun last_unit_burning_scenario() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let mut clock = clock::create_for_testing(ts.ctx());

    let time_10_00 = 1000;
    let time_11_05 = time_10_00 + MS_PER_HOUR + (5 * MS_PER_MINUTE);
    let time_11_30 = time_10_00 + MS_PER_HOUR + (30 * MS_PER_MINUTE);
    let time_15_00 = time_10_00 + (5 * MS_PER_HOUR);
    let time_15_35 = time_10_00 + (5 * MS_PER_HOUR) + (35 * MS_PER_MINUTE);

    // Deposit 2 fuel, start burning at 10:00
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 2, &clock);
        clock.set_for_testing(time_10_00);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 1);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_10_00);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Update at 11:05
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_11_05);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 1);
        assert_eq!(remaining_elapsed_ms, 5 * MS_PER_MINUTE);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_10_00 + MS_PER_HOUR);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Stop at 11:30
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_11_30);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 0);
        assert_eq!(remaining_elapsed_ms, 30 * MS_PER_MINUTE);
        fuel_stop_burning(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), false);
        assert_eq!(nwn.fuel.previous_cycle_elapsed_time(), 30 * MS_PER_MINUTE);
        assert_eq!(nwn.fuel.burn_start_time(), 0);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), false);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Start at 15:00
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_15_00);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_15_00);
        assert_eq!(nwn.fuel.previous_cycle_elapsed_time(), 30 * MS_PER_MINUTE);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Update at 15:35
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_15_35);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 1);
        assert_eq!(remaining_elapsed_ms, 5 * MS_PER_MINUTE);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), false);
        assert_eq!(nwn.fuel.previous_cycle_elapsed_time(), 0);
        assert_eq!(nwn.fuel.burn_start_time(), 0);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), false);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

/// Tests updating first, then stopping to verify time accumulation
#[test]
fun update_before_stop() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let mut clock = clock::create_for_testing(ts.ctx());

    let time_10_00 = 1000;
    let time_10_15 = time_10_00 + (15 * MS_PER_MINUTE);
    let time_10_30 = time_10_00 + (30 * MS_PER_MINUTE);

    // Start burning at 10:00
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        clock.set_for_testing(time_10_00);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_10_00);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Update at 10:15
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_10_15);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 0);
        assert_eq!(remaining_elapsed_ms, 15 * MS_PER_MINUTE);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_10_00);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Stop at 10:30
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_10_30);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 0);
        assert_eq!(remaining_elapsed_ms, 30 * MS_PER_MINUTE);
        fuel_stop_burning(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        assert_eq!(nwn.fuel.is_burning(), false);
        assert_eq!(nwn.fuel.previous_cycle_elapsed_time(), 30 * MS_PER_MINUTE);
        assert_eq!(nwn.fuel.burn_start_time(), 0);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), false);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun running_out_of_fuel() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let mut clock = clock::create_for_testing(ts.ctx());

    let time_10_00 = 1000;
    let time_11_00 = time_10_00 + MS_PER_HOUR;

    // Start with 1 unit, start burning at 10:00
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 1, &clock);
        clock.set_for_testing(time_10_00);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true); // Last unit still burning
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Update at 11:00
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_11_00);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 1);
        assert_eq!(remaining_elapsed_ms, 0);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), false);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 0);
        assert_eq!(nwn.fuel.is_burning(), false);
        assert_eq!(nwn.fuel.burn_start_time(), 0);
        assert_eq!(nwn.fuel.previous_cycle_elapsed_time(), 0);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

/// Cron Job Failure / Missed Updates
/// Test catching up after missed updates
#[test]
fun cron_job_failure_missed_updates() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let mut clock = clock::create_for_testing(ts.ctx());

    let time_10_00 = 1000;
    let time_12_30 = time_10_00 + (2 * MS_PER_HOUR) + (30 * MS_PER_MINUTE);

    // Start burning at 10:00
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        clock.set_for_testing(time_10_00);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_10_00);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Skip update at 11:00, update at 12:30
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_12_30);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 2);
        assert_eq!(remaining_elapsed_ms, 30 * MS_PER_MINUTE);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 2);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.burn_start_time(), time_12_30 - (30 * MS_PER_MINUTE)); // 12:00
        assert_eq!(nwn.fuel.previous_cycle_elapsed_time(), 0);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

/// Test with 50% efficiency to verify consumption rate changes
#[test]
fun fuel_efficiency_impact() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_fuel(&mut ts);
    create_network_node(&mut ts, FUEL_MAX_CAPACITY, FUEL_BURN_RATE_IN_SECONDS);
    let mut clock = clock::create_for_testing(ts.ctx());

    // Configure fuel type with 50% efficiency
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_config.set_fuel_efficiency(&admin_cap, FUEL_TYPE_ID, 50);
        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    let time_10_00 = 1000;
    let time_10_30 = time_10_00 + (30 * MS_PER_MINUTE);

    // Start burning at 10:00
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        fuel_deposit(&mut nwn, FUEL_TYPE_ID, FUEL_VOLUME, 5, &clock);
        clock.set_for_testing(time_10_00);
        fuel_start_burning(&mut nwn, &clock);
        assert_eq!(nwn.fuel.quantity(), 4);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    // Update at 10:30
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared<NetworkNode>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        clock.set_for_testing(time_10_30);
        let (units_to_consume, remaining_elapsed_ms) = nwn
            .fuel
            .units_to_consume(&fuel_config, clock.timestamp_ms());
        assert_eq!(units_to_consume, 1);
        assert_eq!(remaining_elapsed_ms, 0);
        fuel_update(&mut nwn, &fuel_config, &clock);
        assert_eq!(nwn.fuel.quantity(), 3);
        assert_eq!(nwn.fuel.is_burning(), true);
        assert_eq!(nwn.fuel.has_enough_fuel(&fuel_config, &clock), true);
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}
