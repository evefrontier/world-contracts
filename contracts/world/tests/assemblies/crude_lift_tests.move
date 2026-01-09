#[test_only]

module world::crude_lift_tests;

use std::unit_test::assert_eq;
use sui::{clock, test_scenario as ts};
use world::{
    access::{OwnerCap, AdminCap},
    assembly::AssemblyRegistry,
    character::{Self, Character, CharacterRegistry},
    crude_lift::{Self, CrudeLift},
    energy::EnergyConfig,
    fuel::FuelConfig,
    network_node::{Self, NetworkNode},
    rift::{Self, Rift},
    test_helpers::{Self, governor, admin, user_a, tenant}
};

// Constants
const CHARACTER_ITEM_ID: u32 = 1234u32;
const CRUDE_LIFT_TYPE_ID: u64 = 50001;
const CRUDE_LIFT_ITEM_ID: u64 = 90001;
const LOCATION_HASH: vector<u8> = x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const MAX_INVENTORY_CAPACITY: u64 = 10000;
const EPHEMERAL_INVENTORY_CAPACITY: u64 = 5000;
const INITIAL_RIFT_CRUDE: u64 = 1000;
const MINING_RATE: u64 = 10; // crude per second

// === Helper Functions ===

fun create_crude_lift(ts: &mut ts::Scenario, character_id: ID): ID {
    ts::next_tx(ts, admin());
    let mut assembly_registry = ts::take_shared<AssemblyRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let crude_lift_id = {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let crude_lift = crude_lift::anchor(
            &mut assembly_registry,
            &character,
            &admin_cap,
            CRUDE_LIFT_ITEM_ID,
            CRUDE_LIFT_TYPE_ID,
            MAX_INVENTORY_CAPACITY,
            EPHEMERAL_INVENTORY_CAPACITY,
            LOCATION_HASH,
            ts.ctx(),
        );
        let crude_lift_id = object::id(&crude_lift);
        crude_lift.share_crude_lift(&admin_cap);
        ts::return_to_sender(ts, admin_cap);
        crude_lift_id
    };
    ts::return_shared(character);
    ts::return_shared(assembly_registry);
    crude_lift_id
}

fun create_rift(ts: &mut ts::Scenario): ID {
    ts::next_tx(ts, admin());
    let rift_id;
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        rift_id = rift::create_and_share_test_rift(
            &admin_cap,
            INITIAL_RIFT_CRUDE,
            LOCATION_HASH,
            ts.ctx(),
        );
        ts::return_to_sender(ts, admin_cap);
    };
    rift_id
}

fun online_crude_lift(ts: &mut ts::Scenario, user: address, crude_lift_id: ID, network_node_id: ID) {
    ts::next_tx(ts, user);
    {
        let mut crude_lift = ts::take_shared_by_id<CrudeLift>(ts, crude_lift_id);
        let mut network_node = ts::take_shared_by_id<NetworkNode>(ts, network_node_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let owner_cap = ts::take_from_sender<OwnerCap<CrudeLift>>(ts);

        crude_lift.online(&mut network_node, &energy_config, &owner_cap);

        assert!(crude_lift.is_online());
        ts::return_shared(crude_lift);
        ts::return_shared(network_node);
        ts::return_shared(energy_config);
        ts::return_to_sender(ts, owner_cap);
    };
}


fun start_mining(ts: &mut ts::Scenario, user: address, crude_lift_id: ID, rift_id: ID) {
    ts::next_tx(ts, user);
    {
        let mut crude_lift = ts::take_shared_by_id<CrudeLift>(ts, crude_lift_id);
        let mut rift = ts::take_shared_by_id<Rift>(ts, rift_id);
        let clock = clock::create_for_testing(ts.ctx());
        let owner_cap = ts::take_from_sender<OwnerCap<CrudeLift>>(ts);

        crude_lift.start_mining(&mut rift, MINING_RATE, &clock, &owner_cap);

        assert!(crude_lift.is_mining());
        clock.destroy_for_testing();
        ts::return_shared(crude_lift);
        ts::return_shared(rift);
        ts::return_to_sender(ts, owner_cap);
    };
}

fun stop_mining(ts: &mut ts::Scenario, user: address, crude_lift_id: ID, rift_id: ID) {
    ts::next_tx(ts, user);
    {
        let mut crude_lift = ts::take_shared_by_id<CrudeLift>(ts, crude_lift_id);
        let mut rift = ts::take_shared_by_id<Rift>(ts, rift_id);
        let fuel_config = ts::take_shared<FuelConfig>(ts);
        let clock = clock::create_for_testing(ts.ctx());
        let owner_cap = ts::take_from_sender<OwnerCap<CrudeLift>>(ts);

        crude_lift.stop_mining(&mut rift, &fuel_config, &clock, &owner_cap, ts.ctx());

        assert!(!crude_lift.is_mining());
        clock.destroy_for_testing();
        ts::return_shared(crude_lift);
        ts::return_shared(rift);
        ts::return_shared(fuel_config);
        ts::return_to_sender(ts, owner_cap);
    };
}

// === Test Functions ===

// Test creating and anchoring a CrudeLift
#[test]
fun test_anchor_crude_lift() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_ITEM_ID);
    let crude_lift_id = create_crude_lift(&mut ts, character_id);

    ts::next_tx(&mut ts, admin());
    {
        let crude_lift = ts::take_shared_by_id<CrudeLift>(&ts, crude_lift_id);
        let owner_cap_id = crude_lift.owner_cap_id();

        assert_eq!(crude_lift.inventory_capacity(), MAX_INVENTORY_CAPACITY);
        assert!(crude_lift.has_inventory(owner_cap_id));
        assert!(!crude_lift.is_online());
        assert!(!crude_lift.is_mining());
        assert_eq!(crude_lift.crude_amount(), 0);
        assert_eq!(crude_lift.location_hash(), LOCATION_HASH);

        ts::return_shared(crude_lift);
    };

    ts::end(ts);
}

// Test bringing CrudeLift online and offline
#[test]
fun test_online_offline_crude_lift() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_ITEM_ID);
    let crude_lift_id = create_crude_lift(&mut ts, character_id);
    let network_node_id = create_network_node(&mut ts);

    // Bring online
    online_crude_lift(&mut ts, user_a(), crude_lift_id, network_node_id);

    ts::next_tx(&mut ts, admin());
    {
        let crude_lift = ts::take_shared_by_id<CrudeLift>(&ts, crude_lift_id);
        assert!(crude_lift.is_online());
        ts::return_shared(crude_lift);
    };

    // Bring offline
    ts::next_tx(&mut ts, user_a());
    {
        let mut crude_lift = ts::take_shared_by_id<CrudeLift>(&ts, crude_lift_id);
        let mut network_node = ts::take_shared_by_id<NetworkNode>(&ts, network_node_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap<CrudeLift>>(&ts);

        crude_lift.offline(&mut network_node, &energy_config, &owner_cap);

        assert!(!crude_lift.is_online());
        ts::return_shared(crude_lift);
        ts::return_shared(network_node);
        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::end(ts);
}




// Test basic mining flow
#[test]
fun test_basic_mining_flow() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_ITEM_ID);
    let crude_lift_id = create_crude_lift(&mut ts, character_id);
    let rift_id = create_rift(&mut ts);
    let network_node_id = create_network_node(&mut ts);

    // Setup CrudeLift
    online_crude_lift(&mut ts, user_a(), crude_lift_id, network_node_id);

    // Start mining
    start_mining(&mut ts, user_a(), crude_lift_id, rift_id);

    ts::next_tx(&mut ts, admin());
    {
        let crude_lift = ts::take_shared_by_id<CrudeLift>(&ts, crude_lift_id);
        let rift = ts::take_shared_by_id<Rift>(&ts, rift_id);

        assert!(crude_lift.is_mining());
        assert!(rift.is_being_mined());
        assert_eq!(rift.mining_crude_lift_id().borrow(), &crude_lift_id);

        ts::return_shared(crude_lift);
        ts::return_shared(rift);
    };

    // Stop mining
    stop_mining(&mut ts, user_a(), crude_lift_id, rift_id);

    ts::next_tx(&mut ts, admin());
    {
        let crude_lift = ts::take_shared_by_id<CrudeLift>(&ts, crude_lift_id);
        let rift = ts::take_shared_by_id<Rift>(&ts, rift_id);

        assert!(!crude_lift.is_mining());
        assert!(!rift.is_being_mined());
        assert!(crude_lift.crude_amount() > 0);

        ts::return_shared(crude_lift);
        ts::return_shared(rift);
    };

    ts::end(ts);
}


// Test starting mining when already mining fails
#[test]
#[expected_failure(abort_code = crude_lift::EAlreadyMining)]
fun test_start_mining_twice_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_ITEM_ID);
    let crude_lift_id = create_crude_lift(&mut ts, character_id);
    let rift_id = create_rift(&mut ts);
    let network_node_id = create_network_node(&mut ts);

    // Setup CrudeLift
    online_crude_lift(&mut ts, user_a(), crude_lift_id, network_node_id);

    // Start mining first time
    start_mining(&mut ts, user_a(), crude_lift_id, rift_id);

    // Try to start mining again - should fail
    ts::next_tx(&mut ts, user_a());
    {
        let mut crude_lift = ts::take_shared_by_id<CrudeLift>(&ts, crude_lift_id);
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        let clock = clock::create_for_testing(ts.ctx());
        let owner_cap = ts::take_from_sender<OwnerCap<CrudeLift>>(&ts);

        crude_lift.start_mining(&mut rift, MINING_RATE, &clock, &owner_cap);
    };

    ts::end(ts);
}

// Test stopping mining when not mining fails
#[test]
#[expected_failure(abort_code = crude_lift::ENotMining)]
fun test_stop_mining_without_mining_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_ITEM_ID);
    let crude_lift_id = create_crude_lift(&mut ts, character_id);
    let rift_id = create_rift(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut crude_lift = ts::take_shared_by_id<CrudeLift>(&ts, crude_lift_id);
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let clock = clock::create_for_testing(ts.ctx());
        let owner_cap = ts::take_from_sender<OwnerCap<CrudeLift>>(&ts);

        crude_lift.stop_mining(&mut rift, &fuel_config, &clock, &owner_cap, ts.ctx());
    };

    ts::end(ts);
}



// Test mining with rift collapse
#[test]
fun test_mining_rift_collapse() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_ITEM_ID);
    let crude_lift_id = create_crude_lift(&mut ts, character_id);
    let rift_id = create_rift(&mut ts);
    let network_node_id = create_network_node(&mut ts);

    // Setup CrudeLift
    online_crude_lift(&mut ts, user_a(), crude_lift_id, network_node_id);

    // Start mining
    start_mining(&mut ts, user_a(), crude_lift_id, rift_id);

    // Collapse rift during mining
    ts::next_tx(&mut ts, admin());
    {
        let mut clock = clock::create_for_testing(ts.ctx());
        clock.increment_for_testing(30000); // 30 seconds

        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        rift.collapse_rift(&clock);

        ts::return_shared(rift);
        clock.destroy_for_testing();
    };

    // Stop mining - should handle collapsed rift
    stop_mining(&mut ts, user_a(), crude_lift_id, rift_id);

    ts::next_tx(&mut ts, admin());
    {
        let rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        assert!(rift.is_collapsed());
        ts::return_shared(rift);
    };

    ts::end(ts);
}


// Test offline while mining fails
#[test]
#[expected_failure(abort_code = crude_lift::ECrudeLiftWrongState)]
fun test_offline_while_mining_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_ITEM_ID);
    let crude_lift_id = create_crude_lift(&mut ts, character_id);
    let rift_id = create_rift(&mut ts);
    let network_node_id = create_network_node(&mut ts);

    // Setup CrudeLift and start mining
    online_crude_lift(&mut ts, user_a(), crude_lift_id, network_node_id);
    start_mining(&mut ts, user_a(), crude_lift_id, rift_id);

    // Try to go offline while mining - should fail
    ts::next_tx(&mut ts, user_a());
    {
        let mut crude_lift = ts::take_shared_by_id<CrudeLift>(&ts, crude_lift_id);
        let mut network_node = ts::take_shared_by_id<NetworkNode>(&ts, network_node_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap<CrudeLift>>(&ts);

        crude_lift.offline(&mut network_node, &energy_config, &owner_cap);
    };

    ts::end(ts);
}

// === Helper Functions for Tests ===

fun create_character(ts: &mut ts::Scenario, user: address, item_id: u32): ID {
    ts::next_tx(ts, admin());
    let character_id = {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let mut registry = ts::take_shared<CharacterRegistry>(ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            item_id,
            tenant(),
            100,
            user,
            std::string::utf8(b"name"),
            ts.ctx(),
        );
        let character_id = object::id(&character);
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(ts, admin_cap);
        character_id
    };
    character_id
}

fun create_network_node(ts: &mut ts::Scenario): ID {
    ts::next_tx(ts, admin());
    let network_node_id = {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let mut registry = ts::take_shared<network_node::NetworkNodeRegistry>(ts);
        let network_node = network_node::anchor(
            &mut registry,
            &admin_cap,
            user_a(),
            tenant(),
            1, // item_id
            1, // type_id
            1000, // volume
            LOCATION_HASH,
            10000, // fuel_max_capacity
            3600000, // fuel_burn_rate_in_ms
            1000, // max_energy_production
            ts.ctx(),
        );
        let network_node_id = object::id(&network_node);
        network_node::share_network_node(network_node, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(ts, admin_cap);
        network_node_id
    };
    network_node_id
}
