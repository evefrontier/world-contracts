#[test_only]

module world::network_node_tests;

use std::unit_test::assert_eq;
use sui::{clock, test_scenario as ts};
use world::{
    access::{AdminCap, OwnerCap},
    assembly::{Self, AssemblyRegistry},
    fuel,
    network_node::{Self, NetworkNodeRegistry, NetworkNode},
    test_helpers::{Self, governor, admin, in_game_id, tenant, user_a, user_b}
};

const MS_PER_SECOND: u64 = 1000;

const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const VOLUME: u64 = 1000;
const STATUS_ONLINE: u8 = 1;
const STATUS_OFFLINE: u8 = 2;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 100;

// Fuel constants
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

// Assembly constanct
const TYPE_ID: u64 = 1;
const ITEM_ID: u64 = 1001;

// Helper Functions
fun setup(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);
}

fun create_network_node(
    ts: &mut ts::Scenario,
    item_id: u64,
    burn_rate_in_seconds: u64,
    user: address,
): ID {
    ts::next_tx(ts, admin());
    let mut nwn_registry = ts::take_shared<NetworkNodeRegistry>(ts);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    let nwn = network_node::anchor(
        &mut nwn_registry,
        &admin_cap,
        user,
        tenant(),
        item_id,
        NWN_TYPE_ID,
        VOLUME,
        LOCATION_HASH,
        FUEL_MAX_CAPACITY,
        burn_rate_in_seconds,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let id = object::id(&nwn);
    network_node::share_network_node(nwn, &admin_cap);

    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(nwn_registry);
    id
}

fun create_assembly(ts: &mut ts::Scenario): ID {
    ts::next_tx(ts, admin());
    let mut assembly_registry = ts::take_shared<AssemblyRegistry>(ts);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    let assembly = assembly::anchor(
        &mut assembly_registry,
        &admin_cap,
        user_a(),
        tenant(),
        ITEM_ID,
        TYPE_ID,
        VOLUME,
        LOCATION_HASH,
        ts.ctx(),
    );
    let id = object::id(&assembly);
    assembly::share_assembly(assembly, &admin_cap);

    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(assembly_registry);
    id
}

#[test]
fun anchor_network_node() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, user_a());

    ts::next_tx(&mut ts, admin());
    {
        let nwn_registry = ts::take_shared<NetworkNodeRegistry>(&ts);
        assert!(network_node::nwn_exists(&nwn_registry, in_game_id(NWN_ITEM_ID)), 0);
        ts::return_shared(nwn_registry);
    };

    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert_eq!(nwn.status().status_to_u8(), STATUS_OFFLINE);

        assert_eq!(nwn.fuel().quantity(), 0);
        assert_eq!(nwn.fuel().type_id(), 0);
        assert_eq!(nwn.fuel().volume(), 0);
        assert_eq!(nwn.fuel().max_capacity(), FUEL_MAX_CAPACITY);
        assert_eq!(nwn.fuel().burn_rate_in_ms(), FUEL_BURN_RATE_IN_MS);
        assert_eq!(nwn.fuel().is_burning(), false);

        assert_eq!(nwn.energy().energy_source_id(), nwn_id);
        assert_eq!(nwn.energy().max_energy_production(), MAX_PRODUCTION);
        assert_eq!(nwn.energy().current_energy_production(), 0);
        assert_eq!(nwn.energy().total_reserved_energy(), 0);

        ts::return_shared(nwn);
    };
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::end(ts);
}

#[test]
fun deposit_fuel() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, user_a());
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);

        nwn.deposit_fuel(&owner_cap, FUEL_TYPE_ID, FUEL_VOLUME, 10, &clock);

        assert_eq!(nwn.fuel().quantity(), 10);
        assert_eq!(nwn.fuel().type_id(), FUEL_TYPE_ID);
        assert_eq!(nwn.fuel().volume(), FUEL_VOLUME);

        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun withdraw_fuel() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, user_a());
    let clock = clock::create_for_testing(ts.ctx());

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);

        nwn.deposit_fuel(&owner_cap, FUEL_TYPE_ID, FUEL_VOLUME, 10, &clock);

        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);

        nwn.withdraw_fuel(&owner_cap, 5);
        assert_eq!(nwn.fuel().quantity(), 5);

        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun online() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, user_a());
    let clock = clock::create_for_testing(ts.ctx());

    // Deposit fuel
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);

        nwn.deposit_fuel(&owner_cap, FUEL_TYPE_ID, FUEL_VOLUME, 10, &clock);

        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Bring network node online
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);

        nwn.online(&owner_cap, &clock);

        // Check status is online
        assert_eq!(nwn.status().status_to_u8(), STATUS_ONLINE);

        // Check fuel is burning (1 unit consumed immediately when starting)
        assert_eq!(nwn.fuel().is_burning(), true);
        assert_eq!(nwn.fuel().quantity(), 9);

        // Check energy production started at max
        assert_eq!(nwn.energy().current_energy_production(), MAX_PRODUCTION);
        assert_eq!(nwn.energy().max_energy_production(), MAX_PRODUCTION);

        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = network_node::ENetworkNodeAlreadyExists)]
fun anchor_duplicate_item_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let _ = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, user_a());

    // Second anchor with same ITEM_ID should fail
    let _ = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, user_a());

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = network_node::ENetworkNodeTypeIdEmpty)]
fun anchor_invalid_type_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    ts::next_tx(&mut ts, admin());
    let mut nwn_registry = ts::take_shared<NetworkNodeRegistry>(&ts);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let nwn = network_node::anchor(
        &mut nwn_registry,
        &admin_cap,
        user_a(),
        tenant(),
        NWN_ITEM_ID,
        0, // Invalid Type ID
        VOLUME,
        LOCATION_HASH,
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    network_node::share_network_node(nwn, &admin_cap);

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(nwn_registry);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = network_node::ENetworkNodeItemIdEmpty)]
fun anchor_invalid_item_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    ts::next_tx(&mut ts, admin());
    let mut nwn_registry = ts::take_shared<NetworkNodeRegistry>(&ts);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let nwn = network_node::anchor(
        &mut nwn_registry,
        &admin_cap,
        user_a(),
        tenant(),
        0, // Invalid Item ID
        NWN_TYPE_ID,
        VOLUME,
        LOCATION_HASH,
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    network_node::share_network_node(nwn, &admin_cap);

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(nwn_registry);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::ENoFuelToBurn)]
fun online_without_fuel() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, user_a());
    let clock = clock::create_for_testing(ts.ctx());

    // Try to bring online without depositing fuel
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);

        nwn.online(&owner_cap, &clock); // Should abort - no fuel

        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = network_node::ENetworkNodeNotAuthorized)]
fun online_unauthorized_owner() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let nwn_id_a = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, user_a());
    let _ = create_network_node(&mut ts, NWN_ITEM_ID + 1, FUEL_BURN_RATE_IN_MS, user_b());
    let clock = clock::create_for_testing(ts.ctx());

    // Deposit fuel for user_a's network node
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id_a);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);

        nwn.deposit_fuel(&owner_cap, FUEL_TYPE_ID, FUEL_VOLUME, 10, &clock);

        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Try to bring user_a's network node online using user_b's owner cap (wrong cap)
    ts::next_tx(&mut ts, user_b());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id_a);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts); // This is for nwn_id_b

        nwn.online(&owner_cap, &clock); // Should abort - unauthorized

        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}
