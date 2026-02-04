#[test_only]
module world::assembly_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::{clock, test_scenario as ts};
use world::{
    access::{AdminCap, OwnerCap},
    assembly::{Self, Assembly},
    character::{Self, Character},
    energy::{Self, EnergyConfig},
    location,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    status,
    test_helpers::{Self, governor, admin, user_a, tenant, in_game_id}
};

const CHARACTER_ITEM_ID: u32 = 2001;

const MS_PER_SECOND: u64 = 1000;
const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const TYPE_ID: u64 = 8888;
const ITEM_ID: u64 = 1001;
const STATUS_ONLINE: u8 = 1;
const STATUS_OFFLINE: u8 = 2;

// Network node constants
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 100;

// Fuel constants
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

// Energy constants (ASSEMBLY_TYPE_1 = 8888 requires 50 energy)
const ASSEMBLY_ENERGY_REQUIRED: u64 = 50;

// Helper to setup test environment
fun setup(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);
}

fun create_character(ts: &mut ts::Scenario, user: address, item_id: u32): ID {
    ts::next_tx(ts, admin());
    {
        let character_id = {
            let admin_cap = ts::take_from_sender<AdminCap>(ts);
            let mut registry = ts::take_shared<ObjectRegistry>(ts);
            let character = character::create_character(
                &mut registry,
                &admin_cap,
                item_id,
                tenant(),
                100,
                user,
                utf8(b"name"),
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
}

// Helper to create network node
fun create_network_node(ts: &mut ts::Scenario, character_id: ID): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_cap,
        NWN_ITEM_ID,
        NWN_TYPE_ID,
        LOCATION_HASH,
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let id = object::id(&nwn);
    network_node::share_network_node(nwn, &admin_cap);

    ts::return_shared(character);
    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(registry);
    id
}

// Helper to create assembly. Returns (assembly_id, character_id).
fun create_assembly(ts: &mut ts::Scenario, nwn_id: ID, character_id: ID): ID {
    ts::next_tx(ts, admin());
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    let assembly = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_cap,
        ITEM_ID,
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    let assembly_id = object::id(&assembly);
    assembly::share_assembly(assembly, &admin_cap);

    ts::return_shared(character);
    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(registry);
    ts::return_shared(nwn);
    assembly_id
}

#[test]
fun test_anchor_assembly() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, character_id);
    let assembly_id = create_assembly(&mut ts, nwn_id, character_id);

    ts::next_tx(&mut ts, admin());
    {
        let registry = ts::take_shared<ObjectRegistry>(&ts);
        assert!(registry.object_exists(in_game_id(ITEM_ID)), 0);
        ts::return_shared(registry);
    };

    ts::next_tx(&mut ts, admin());
    {
        let assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let status = assembly::status(&assembly);
        assert_eq!(status::status_to_u8(status), STATUS_OFFLINE);

        let loc = assembly::location(&assembly);
        assert_eq!(location::hash(loc), LOCATION_HASH);

        ts::return_shared(assembly);
    };

    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert!(network_node::is_assembly_connected(&nwn, assembly_id), 0);
        ts::return_shared(nwn);
    };
    ts::end(ts);
}

#[test]
fun test_online_offline() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), (CHARACTER_ITEM_ID as u32));
    let nwn_id = create_network_node(&mut ts, character_id);
    let assembly_id = create_assembly(&mut ts, nwn_id, character_id);
    let clock = clock::create_for_testing(ts.ctx());

    // Deposit fuel to network node
    ts::next_tx(&mut ts, user_a());
    let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
    let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
    let owner_cap = character.borrow_owner_cap<NetworkNode>(
        ts::most_recent_receiving_ticket<OwnerCap<NetworkNode>>(&character_id),
        ts.ctx(),
    );

    ts::next_tx(&mut ts, user_a());
    {
        nwn.deposit_fuel_test(
            &owner_cap,
            FUEL_TYPE_ID,
            FUEL_VOLUME,
            10,
            &clock,
        );
    };

    ts::next_tx(&mut ts, user_a());
    {
        nwn.online(&owner_cap, &clock);
    };
    character.return_owner_cap(owner_cap);

    ts::next_tx(&mut ts, user_a());
    let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
    let energy_config = ts::take_shared<EnergyConfig>(&ts);

    // OwnerCap<Assembly> is on Character; borrow from character, use, return
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = character.borrow_owner_cap<Assembly>(
            ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id),
            ts.ctx(),
        );
        assert_eq!(energy::total_reserved_energy(nwn.energy()), 0);

        assembly.online(&mut nwn, &energy_config, &owner_cap);
        assert_eq!(status::status_to_u8(assembly::status(&assembly)), STATUS_ONLINE);
        assert_eq!(energy::total_reserved_energy(nwn.energy()), ASSEMBLY_ENERGY_REQUIRED);

        character.return_owner_cap(owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let access_cap_ticket = ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id);
        let owner_cap = character.borrow_owner_cap<Assembly>(
            access_cap_ticket,
            ts.ctx(),
        );
        assert_eq!(energy::total_reserved_energy(nwn.energy()), ASSEMBLY_ENERGY_REQUIRED);

        assembly.offline(&mut nwn, &energy_config, &owner_cap);
        assert_eq!(status::status_to_u8(assembly::status(&assembly)), STATUS_OFFLINE);
        assert_eq!(energy::total_reserved_energy(nwn.energy()), 0);

        character.return_owner_cap(owner_cap);
    };

    ts::return_shared(assembly);
    ts::return_shared(nwn);
    ts::return_shared(energy_config);
    ts::return_shared(character);
    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun test_unanchor() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 7);

    let nwn_id = create_network_node(&mut ts, character_id);

    ts::next_tx(&mut ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(&ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let assembly = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_cap,
        ITEM_ID,
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    ts::return_shared(character);
    let assembly_id = object::id(&assembly);
    assert!(network_node::is_assembly_connected(&nwn, assembly_id), 0);

    // Unanchor - consumes assembly
    let energy_config = ts::take_shared<EnergyConfig>(&ts);
    assembly::unanchor(assembly, &mut nwn, &energy_config, &admin_cap);
    assert!(!network_node::is_assembly_connected(&nwn, assembly_id), 0);

    // As per implementation, derived object is not reclaimed, so assembly_exists should be true
    // but object is gone.
    assert!(registry.object_exists(in_game_id(ITEM_ID)), 0);

    ts::return_shared(nwn);
    ts::return_shared(energy_config);
    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(registry);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::EAssemblyAlreadyExists)]
fun test_anchor_duplicate_item_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 4);
    let nwn_id = create_network_node(&mut ts, character_id);

    ts::next_tx(&mut ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(&ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);
    let assembly1 = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_cap,
        ITEM_ID,
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    assembly::share_assembly(assembly1, &admin_cap);

    // Second anchor with same ITEM_ID should fail
    let assembly2 = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_cap,
        ITEM_ID,
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    ts::return_shared(character);
    assembly::share_assembly(assembly2, &admin_cap);

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(registry);
    ts::return_shared(nwn);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::EAssemblyTypeIdEmpty)]
fun test_anchor_invalid_type_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 5);
    let nwn_id = create_network_node(&mut ts, character_id);

    ts::next_tx(&mut ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(&ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let assembly = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_cap,
        ITEM_ID,
        0, // Invalid Type ID
        LOCATION_HASH,
        ts.ctx(),
    );
    ts::return_shared(character);
    assembly::share_assembly(assembly, &admin_cap);

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(registry);
    ts::return_shared(nwn);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::EAssemblyItemIdEmpty)]
fun test_anchor_invalid_item_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 6);
    let nwn_id = create_network_node(&mut ts, character_id);
    ts::next_tx(&mut ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(&ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let assembly = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_cap,
        0, // Invalid Item ID
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    ts::return_shared(character);
    assembly::share_assembly(assembly, &admin_cap);

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(registry);
    ts::return_shared(nwn);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::EAssemblyHasEnergySource)]
fun test_unanchor_orphan_fails_when_energy_source_set() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 8);
    let nwn_id = create_network_node(&mut ts, character_id);
    let assembly_id = create_assembly(&mut ts, nwn_id, character_id);

    // Attempting to orphan-unanchor while still connected should fail.
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        assembly.unanchor_orphan(&admin_cap);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}
