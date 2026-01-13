#[test_only]

module world::network_node_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::{clock, test_scenario as ts};
use world::{
    access::{AdminCap, OwnerCap, AdminACL},
    assembly::{Self, Assembly},
    character::{Self, Character},
    energy::EnergyConfig,
    fuel::{Self, FuelConfig},
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    test_helpers::{Self, governor, admin, in_game_id, tenant, user_a, user_b}
};

const MS_PER_SECOND: u64 = 1000;

const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const STATUS_ONLINE: u8 = 1;
const STATUS_OFFLINE: u8 = 2;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 100;

// Fuel constants
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

// Assembly constants
const TYPE_ID: u64 = 8888;
const ITEM_ID_1: u64 = 1001;
const ITEM_ID_2: u64 = 1002;
const ASSEMBLY_ENERGY_REQUIRED: u64 = 50; // Energy required for TYPE_ID 8888
const CHARACTER_ITEM_ID_OFFSET: u32 = 10000;

// Helper Functions
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
                ts::ctx(ts),
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

fun create_network_node(
    ts: &mut ts::Scenario,
    item_id: u64,
    burn_rate_in_seconds: u64,
    character_id: ID,
): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_cap,
        item_id,
        NWN_TYPE_ID,
        LOCATION_HASH,
        FUEL_MAX_CAPACITY,
        burn_rate_in_seconds,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let id = object::id(&nwn);
    nwn.share_network_node(&admin_cap);

    ts::return_shared(character);
    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(registry);
    id
}

fun create_assembly(ts: &mut ts::Scenario, nwn_id: ID, item_id: u64): ID {
    let character_item_id = (item_id as u32) + CHARACTER_ITEM_ID_OFFSET;
    let character_id = create_character(ts, user_a(), character_item_id);
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);
    let assembly = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_cap,
        item_id,
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    ts::return_shared(character);
    let id = object::id(&assembly);
    assembly::share_assembly(assembly, &admin_cap);

    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(registry);
    ts::return_shared(nwn);
    id
}

fun get_owner_cap_for_assembly(
    ts: &ts::Scenario,
    assembly: &Assembly,
    sender: address,
): OwnerCap<Assembly> {
    let owner_cap_id = assembly::owner_cap_id(assembly);
    ts::take_from_address_by_id<OwnerCap<Assembly>>(ts, sender, owner_cap_id)
}

fun get_owner_cap_for_network_node(
    ts: &ts::Scenario,
    nwn: &NetworkNode,
    sender: address,
): OwnerCap<NetworkNode> {
    let owner_cap_id = network_node::owner_cap_id(nwn);
    ts::take_from_address_by_id<OwnerCap<NetworkNode>>(ts, sender, owner_cap_id)
}

fun do_deposit_fuel(
    ts: &mut ts::Scenario,
    nwn_id: ID,
    quantity: u64,
    clock: &clock::Clock,
    sender: address,
) {
    ts::next_tx(ts, sender);
    let nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let owner_cap = get_owner_cap_for_network_node(ts, &nwn, sender);
    ts::return_shared(nwn);

    ts::next_tx(ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let admin_acl = ts::take_shared<AdminACL>(ts);
        nwn.deposit_fuel_test(
            &admin_acl,
            &owner_cap,
            FUEL_TYPE_ID,
            FUEL_VOLUME,
            quantity,
            clock,
            ts.ctx(),
        );
        ts::return_shared(admin_acl);
        ts::return_shared(nwn);
    };
    ts::next_tx(ts, sender);
    {
        ts::return_to_sender(ts, owner_cap);
    };
}

fun online_assembly(ts: &mut ts::Scenario, assembly_id: ID, nwn_id: ID, sender: address) {
    ts::next_tx(ts, sender);
    {
        let mut assembly = ts::take_shared_by_id<Assembly>(ts, assembly_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let owner_cap = get_owner_cap_for_assembly(ts, &assembly, sender);
        assembly.online(&mut nwn, &energy_config, &owner_cap);
        ts::return_shared(assembly);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_to_sender(ts, owner_cap);
    };
}

fun offline_assembly(ts: &mut ts::Scenario, assembly_id: ID, nwn_id: ID, sender: address) {
    ts::next_tx(ts, sender);
    {
        let mut assembly = ts::take_shared_by_id<Assembly>(ts, assembly_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let owner_cap = get_owner_cap_for_assembly(ts, &assembly, sender);
        assembly.offline(&mut nwn, &energy_config, &owner_cap);
        ts::return_shared(assembly);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_to_sender(ts, owner_cap);
    };
}

#[test]
fun anchor_network_node() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);

    ts::next_tx(&mut ts, admin());
    {
        let registry = ts::take_shared<ObjectRegistry>(&ts);
        assert!(registry.object_exists(in_game_id(NWN_ITEM_ID)), 0);
        ts::return_shared(registry);
    };

    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert_eq!(nwn.status().status_to_u8(), STATUS_OFFLINE);

        assert_eq!(nwn.fuel().quantity(), 0);
        assert_eq!(option::is_some(&nwn.fuel().type_id()), false);
        assert_eq!(option::is_some(&nwn.fuel().volume()), false);
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
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let clock = clock::create_for_testing(ts.ctx());

    do_deposit_fuel(&mut ts, nwn_id, 10, &clock, user_a());

    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert_eq!(nwn.fuel().quantity(), 10);
        assert!(option::is_some(&nwn.fuel().type_id()));
        assert_eq!(*option::borrow(&nwn.fuel().type_id()), FUEL_TYPE_ID);
        assert!(option::is_some(&nwn.fuel().volume()));
        assert_eq!(*option::borrow(&nwn.fuel().volume()), FUEL_VOLUME);
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun withdraw_fuel() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let clock = clock::create_for_testing(ts.ctx());

    do_deposit_fuel(&mut ts, nwn_id, 10, &clock, user_a());

    ts::next_tx(&mut ts, user_a());
    let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);

        nwn.withdraw_fuel_test(&admin_acl, &owner_cap, 5, ts.ctx());
        assert_eq!(nwn.fuel().quantity(), 5);

        ts::return_shared(admin_acl);
        ts::return_shared(nwn);
    };

    ts::next_tx(&mut ts, user_a());
    ts::return_to_sender(&ts, owner_cap);

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun online() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let clock = clock::create_for_testing(ts.ctx());

    // Deposit fuel
    do_deposit_fuel(&mut ts, nwn_id, 10, &clock, user_a());

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
fun connected_assemblies_online_offline() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let clock = clock::create_for_testing(ts.ctx());

    // Create two assemblies connected to this network node
    let assembly1_id = create_assembly(&mut ts, nwn_id, ITEM_ID_1);
    let assembly2_id = create_assembly(&mut ts, nwn_id, ITEM_ID_2);

    do_deposit_fuel(&mut ts, nwn_id, 10, &clock, user_a());

    // Bring network node online
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        nwn.online(&owner_cap, &clock);
        assert_eq!(nwn.status().status_to_u8(), STATUS_ONLINE);
        assert_eq!(nwn.fuel().is_burning(), true);
        assert_eq!(nwn.energy().current_energy_production(), MAX_PRODUCTION);
        assert_eq!(nwn.energy().total_reserved_energy(), 0);
        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Bring connected assemblies online (should reserve energy)
    online_assembly(&mut ts, assembly1_id, nwn_id, user_a());
    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert_eq!(nwn.energy().total_reserved_energy(), ASSEMBLY_ENERGY_REQUIRED);
        ts::return_shared(nwn);
    };

    online_assembly(&mut ts, assembly2_id, nwn_id, user_a());
    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert_eq!(nwn.energy().total_reserved_energy(), ASSEMBLY_ENERGY_REQUIRED * 2);
        ts::return_shared(nwn);
    };

    // Bring assemblies offline (should release energy)
    offline_assembly(&mut ts, assembly1_id, nwn_id, user_a());
    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert_eq!(nwn.energy().total_reserved_energy(), ASSEMBLY_ENERGY_REQUIRED);
        ts::return_shared(nwn);
    };

    offline_assembly(&mut ts, assembly2_id, nwn_id, user_a());
    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert_eq!(nwn.energy().total_reserved_energy(), 0);
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun update_fuel_intervals() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let mut clock = clock::create_for_testing(ts.ctx());
    let assembly_id = create_assembly(&mut ts, nwn_id, ITEM_ID_1);

    let time_start = 1000;
    let time_after_1_hour = time_start + FUEL_BURN_RATE_IN_MS;
    let time_after_2_hours = time_start + (FUEL_BURN_RATE_IN_MS * 2);

    clock.set_for_testing(time_start);
    do_deposit_fuel(&mut ts, nwn_id, 10, &clock, user_a());

    // Bring network node online (consumes 1 unit immediately)
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        clock.set_for_testing(time_start);
        nwn.online(&owner_cap, &clock);
        assert_eq!(nwn.fuel().quantity(), 9);
        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    online_assembly(&mut ts, assembly_id, nwn_id, user_a());

    // Update fuel after 1 hour (should consume 1 more unit)
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        clock.set_for_testing(time_after_1_hour);
        let offline_assemblies = nwn.update_fuel(&fuel_config, &admin_cap, &clock);
        // Should still be online, empty hot potato
        assert_eq!(offline_assemblies.ids_length(), 0);
        assert_eq!(nwn.fuel().quantity(), 8);
        assert_eq!(nwn.status().status_to_u8(), STATUS_ONLINE);
        // Destroy the empty hot potato
        offline_assemblies.destroy_offline_assemblies();
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Advance clock to consume more fuel (after 2 hours total)
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        clock.set_for_testing(time_after_2_hours);
        let offline_assemblies = nwn.update_fuel(&fuel_config, &admin_cap, &clock);
        assert_eq!(offline_assemblies.ids_length(), 0);
        assert_eq!(nwn.fuel().quantity(), 7);
        // Destroy the empty hot potato
        offline_assemblies.destroy_offline_assemblies();
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun update_fuel_depletion_offline() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let mut clock = clock::create_for_testing(ts.ctx());

    let assembly_id = create_assembly(&mut ts, nwn_id, ITEM_ID_1);

    let time_10_00 = 1000;
    clock.set_for_testing(time_10_00);
    do_deposit_fuel(&mut ts, nwn_id, 2, &clock, user_a());

    // 10:00 am - Bring network node online (consumes 1 unit immediately, 1 remaining)
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        nwn.online(&owner_cap, &clock);
        assert_eq!(nwn.fuel().quantity(), 1);
        assert_eq!(nwn.fuel().is_burning(), true);
        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    online_assembly(&mut ts, assembly_id, nwn_id, user_a());

    // 11:05 - Fuel: 0 remaining but last unit is still burning
    // FUEL_BURN_RATE_IN_MS = 3600 * 1000 = 3,600,000 ms = 1 hour
    // 10:00 + 1 hour + 5 minutes = 11:05
    let time_11_05 = time_10_00 + FUEL_BURN_RATE_IN_MS + (5 * 60 * MS_PER_SECOND);
    clock.set_for_testing(time_11_05);
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let offline_assemblies = nwn.update_fuel(&fuel_config, &admin_cap, &clock);

        // Quantity is 0, but still burning (last unit is burning)
        assert_eq!(offline_assemblies.ids_length(), 0);
        assert_eq!(nwn.fuel().quantity(), 0);
        assert_eq!(nwn.fuel().is_burning(), true);
        assert_eq!(nwn.status().status_to_u8(), STATUS_ONLINE);
        offline_assemblies.destroy_offline_assemblies();
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    // 11:15 - Update: nothing happens, nwn is still online
    let time_11_15 = time_11_05 + (10 * 60 * MS_PER_SECOND);
    clock.set_for_testing(time_11_15);
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let offline_assemblies = nwn.update_fuel(&fuel_config, &admin_cap, &clock);

        // Still burning, still online
        assert_eq!(offline_assemblies.ids_length(), 0);
        assert_eq!(nwn.fuel().quantity(), 0);
        assert_eq!(nwn.fuel().is_burning(), true);
        assert_eq!(nwn.status().status_to_u8(), STATUS_ONLINE);
        offline_assemblies.destroy_offline_assemblies();
        ts::return_shared(nwn);
        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    // 12:06 - Update: then nwn goes offline and connected assemblies
    let time_12_06 = time_11_05 + FUEL_BURN_RATE_IN_MS + (1 * 60 * MS_PER_SECOND);
    clock.set_for_testing(time_12_06);
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let offline_assemblies = nwn.update_fuel(&fuel_config, &admin_cap, &clock);

        // Network node should go offline - burning stopped (2 units consumed)
        assert_eq!(offline_assemblies.ids_length() > 0, true);
        assert_eq!(nwn.fuel().quantity(), 0);
        assert_eq!(nwn.fuel().is_burning(), false);
        assert_eq!(nwn.status().status_to_u8(), STATUS_OFFLINE);
        assert_eq!(nwn.energy().current_energy_production(), 0);

        // Process the offline assemblies - bring connected assembly offline
        let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let updated_offline_assemblies = assembly.offline_connected_assembly(
            offline_assemblies,
            &mut nwn,
            &energy_config,
        );
        // Energy should be released
        assert_eq!(nwn.energy().total_reserved_energy(), 0);

        // Destroy the offline assemblies struct
        updated_offline_assemblies.destroy_offline_assemblies();

        ts::return_shared(nwn);
        ts::return_shared(assembly);
        ts::return_shared(energy_config);
        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun update_energy_source_after_unanchor() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn1_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let clock = clock::create_for_testing(ts.ctx());
    let assembly_id = create_assembly(&mut ts, nwn1_id, ITEM_ID_1);

    // Deposit fuel and bring network node online
    do_deposit_fuel(&mut ts, nwn1_id, 10, &clock, user_a());
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn1_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Bring assembly online
    online_assembly(&mut ts, assembly_id, nwn1_id, user_a());

    // Unanchor the first network node - returns hot potato with connected assemblies
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn1_id);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let offline_assemblies = nwn.unanchor(&admin_cap);

        // Process the connected assembly - brings it offline and releases energy
        let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let updated_offline_assemblies = assembly.offline_connected_assembly(
            offline_assemblies,
            &mut nwn,
            &energy_config,
        );

        // Destroy the network node after all assemblies are processed
        nwn.destroy_network_node(updated_offline_assemblies, &admin_cap);

        ts::return_shared(assembly);
        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Create a new network node
    let nwn2_id = create_network_node(&mut ts, NWN_ITEM_ID + 1, FUEL_BURN_RATE_IN_MS, character_id);

    // Update energy source for assembly to the new network node
    ts::next_tx(&mut ts, admin());
    {
        let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let mut nwn2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn2_id);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        assembly.update_energy_source(&mut nwn2, &admin_cap);
        assert!(nwn2.is_assembly_connected(assembly_id), 0);
        ts::return_shared(assembly);
        ts::return_shared(nwn2);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Deposit fuel to new network node and bring it online
    do_deposit_fuel(&mut ts, nwn2_id, 10, &clock, user_a());
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn2_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Assembly online should work with the new network node
    online_assembly(&mut ts, assembly_id, nwn2_id, user_a());
    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn2_id);
        assert_eq!(nwn.energy().total_reserved_energy(), ASSEMBLY_ENERGY_REQUIRED);
        ts::return_shared(nwn);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = network_node::ENetworkNodeAlreadyExists)]
fun anchor_duplicate_item_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 1);
    let _ = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);

    // Second anchor with same ITEM_ID should fail
    let _ = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = network_node::ENetworkNodeTypeIdEmpty)]
fun anchor_invalid_type_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 1);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let nwn = network_node::anchor(
            &mut registry,
            &character,
            &admin_cap,
            NWN_ITEM_ID,
            0, // Invalid Type ID
            LOCATION_HASH,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_IN_MS,
            MAX_PRODUCTION,
            ts.ctx(),
        );
        ts::return_shared(character);
        nwn.share_network_node(&admin_cap);

        ts::return_to_sender(&ts, admin_cap);
        ts::return_shared(registry);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = network_node::ENetworkNodeItemIdEmpty)]
fun anchor_invalid_item_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 1);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let nwn = network_node::anchor(
            &mut registry,
            &character,
            &admin_cap,
            0, // Invalid Item ID
            NWN_TYPE_ID,
            LOCATION_HASH,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_IN_MS,
            MAX_PRODUCTION,
            ts.ctx(),
        );
        ts::return_shared(character);
        nwn.share_network_node(&admin_cap);

        ts::return_to_sender(&ts, admin_cap);
        ts::return_shared(registry);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = fuel::ENoFuelToBurn)]
fun online_without_fuel() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
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
    let character_a_id = create_character(&mut ts, user_a(), 1);
    let character_b_id = create_character(&mut ts, user_b(), 2);
    let nwn_id_a = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_a_id);
    let _ = create_network_node(&mut ts, NWN_ITEM_ID + 1, FUEL_BURN_RATE_IN_MS, character_b_id);
    let clock = clock::create_for_testing(ts.ctx());

    do_deposit_fuel(&mut ts, nwn_id_a, 10, &clock, user_a());

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

#[test]
#[expected_failure(abort_code = network_node::EAssembliesConnected)]
fun offline_hot_potato_not_consumed() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let clock = clock::create_for_testing(ts.ctx());

    // Create two assemblies connected to this network node
    let assembly1_id = create_assembly(&mut ts, nwn_id, ITEM_ID_1);
    let assembly2_id = create_assembly(&mut ts, nwn_id, ITEM_ID_2);

    do_deposit_fuel(&mut ts, nwn_id, 10, &clock, user_a());
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    online_assembly(&mut ts, assembly1_id, nwn_id, user_a());
    online_assembly(&mut ts, assembly2_id, nwn_id, user_a());

    // Bring network node offline - returns hot potato with 2 assemblies
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let owner_cap = ts::take_from_address<OwnerCap<NetworkNode>>(&ts, user_a());
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let offline_assemblies = nwn.offline(&fuel_config, &owner_cap, &clock);

        // Process only one assembly (not both)
        let mut assembly1 = ts::take_shared_by_id<Assembly>(&ts, assembly1_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let updated_offline_assemblies = assembly1.offline_connected_assembly(
            offline_assemblies,
            &mut nwn,
            &energy_config,
        );

        // Try to destroy hot potato without processing all assemblies - should fail
        updated_offline_assemblies.destroy_offline_assemblies();

        ts::return_shared(nwn);
        ts::return_shared(assembly1);
        ts::return_shared(energy_config);
        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, owner_cap);
        ts::return_to_sender(&ts, admin_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::ENetworkNodeDoesNotExist)]
fun assembly_online_fails_without_updating_energy_source() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn1_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let clock = clock::create_for_testing(ts.ctx());
    let assembly_id = create_assembly(&mut ts, nwn1_id, ITEM_ID_1);

    do_deposit_fuel(&mut ts, nwn1_id, 10, &clock, user_a());
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn1_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };
    online_assembly(&mut ts, assembly_id, nwn1_id, user_a());

    // Unanchor the first network node - returns hot potato with connected assemblies
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn1_id);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let offline_assemblies = nwn.unanchor(&admin_cap);

        // Process the connected assembly - brings it offline and releases energy
        let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let updated_offline_assemblies = assembly.offline_connected_assembly(
            offline_assemblies,
            &mut nwn,
            &energy_config,
        );

        // Destroy the network node after all assemblies are processed
        nwn.destroy_network_node(updated_offline_assemblies, &admin_cap);

        ts::return_shared(assembly);
        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    let nwn2_id = create_network_node(&mut ts, NWN_ITEM_ID + 1, FUEL_BURN_RATE_IN_MS, character_id);
    do_deposit_fuel(&mut ts, nwn2_id, 10, &clock, user_a());
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn2_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Try to bring assembly online without updating energy source - should fail
    // because assembly still points to the deleted nwn1_id
    online_assembly(&mut ts, assembly_id, nwn2_id, user_a());

    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::EAssemblyOnline)]
fun update_energy_source_when_assembly_online() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_id = create_character(&mut ts, user_a(), 1);
    let nwn1_id = create_network_node(&mut ts, NWN_ITEM_ID, FUEL_BURN_RATE_IN_MS, character_id);
    let nwn2_id = create_network_node(&mut ts, NWN_ITEM_ID + 1, FUEL_BURN_RATE_IN_MS, character_id);
    let clock = clock::create_for_testing(ts.ctx());
    let assembly_id = create_assembly(&mut ts, nwn1_id, ITEM_ID_1);

    do_deposit_fuel(&mut ts, nwn1_id, 10, &clock, user_a());
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn1_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
        ts::return_to_sender(&ts, owner_cap);
    };
    online_assembly(&mut ts, assembly_id, nwn1_id, user_a());

    // Try to update energy source while assembly is online - should fail
    ts::next_tx(&mut ts, admin());
    {
        let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let mut nwn2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn2_id);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        assembly.update_energy_source(&mut nwn2, &admin_cap);
        ts::return_shared(assembly);
        ts::return_shared(nwn2);
        ts::return_to_sender(&ts, admin_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}
