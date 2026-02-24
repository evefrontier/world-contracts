#[test_only]
module world::turret_tests;

use std::{bcs, string::utf8, unit_test::assert_eq};
use sui::{clock, test_scenario as ts};
use world::{
    access::{AdminACL, OwnerCap},
    character::{Self, Character},
    energy::EnergyConfig,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, tenant, user_a},
    turret::{Self, Turret, OnlineReceipt}
};

// Turret constants
const TURRET_TYPE_ID: u64 = 5555;
const TURRET_ITEM_ID_1: u64 = 6001;
const TURRET_ITEM_ID_2: u64 = 6002;

// Network node constants (match gate_tests)
const MS_PER_SECOND: u64 = 1000;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const NWN_ITEM_ID_2: u64 = 5001;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 100;
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

// BCS layout for TurretTarget: (address, u64, address, u32, u64, u64, u64, bool, u64)
public struct TurretTargetBcs has copy, drop {
    target_id: address,
    target_type_id: u64,
    target_character_id: address,
    target_character_tribe: u32,
    hp_ratio: u64,
    shield_ratio: u64,
    armor_ratio: u64,
    is_agressor: bool,
    weight: u64,
}

// Mock extension witness for authorize_extension tests
public struct TurretAuth has drop {}

// Mock get_target_priority_list in extension contract
public fun get_target_priority_list(
    turret: &Turret,
    _: &Character,
    priority_list: vector<u8>,
    _: vector<u8>,
    receipt: OnlineReceipt,
): vector<u8> {
    assert!(turret::receipt_turret_id(&receipt) == object::id(turret), 0);
    receipt.destroy_online_receipt(TurretAuth {});
    // for testing purposes, don't add the target to the priority list; return the priority list as is
    priority_list
}

fun setup(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);
    test_helpers::register_server_address(ts);
}

fun create_character(ts: &mut ts::Scenario, user: address, item_id: u32, tribe_id: u32): ID {
    ts::next_tx(ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(ts);
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let character = character::create_character(
            &mut registry,
            &admin_acl,
            item_id,
            tenant(),
            tribe_id,
            user,
            utf8(b"name"),
            ts.ctx(),
        );
        let character_id = object::id(&character);
        character.share_character(&admin_acl, ts.ctx());
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
        character_id
    }
}

fun create_network_node(ts: &mut ts::Scenario, character_id: ID): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_acl,
        NWN_ITEM_ID,
        NWN_TYPE_ID,
        test_helpers::get_verified_location_hash(),
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let nwn_id = object::id(&nwn);
    nwn.share_network_node(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    nwn_id
}

fun create_network_node_with_item_id(
    ts: &mut ts::Scenario,
    character_id: ID,
    nwn_item_id: u64,
): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_acl,
        nwn_item_id,
        NWN_TYPE_ID,
        test_helpers::get_verified_location_hash(),
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let nwn_id = object::id(&nwn);
    nwn.share_network_node(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    nwn_id
}

fun create_turret(ts: &mut ts::Scenario, character_id: ID, nwn_id: ID, item_id: u64): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let turret_obj = turret::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        item_id,
        TURRET_TYPE_ID,
        test_helpers::get_verified_location_hash(),
        ts.ctx(),
    );
    let turret_id = object::id(&turret_obj);
    turret_obj.share_turret(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(nwn);
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    turret_id
}

fun bring_network_node_online(ts: &mut ts::Scenario, character_id: ID, nwn_id: ID) {
    ts::next_tx(ts, user_a());
    {
        let clock = clock::create_for_testing(ts.ctx());
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let mut character = ts::take_shared_by_id<Character>(ts, character_id);
        let nwn_owner_cap_id = network_node::owner_cap_id(&nwn);
        let nwn_ticket = ts::receiving_ticket_by_id<OwnerCap<NetworkNode>>(nwn_owner_cap_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<NetworkNode>(nwn_ticket, ts.ctx());
        nwn.deposit_fuel_test(&owner_cap, FUEL_TYPE_ID, FUEL_VOLUME, 10, &clock);
        nwn.online(&owner_cap, &clock);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(nwn);
        ts::return_shared(character);
        clock.destroy_for_testing();
    };
}

fun bring_turret_online(ts: &mut ts::Scenario, character_id: ID, turret_id: ID, nwn_id: ID) {
    ts::next_tx(ts, user_a());
    {
        let mut turret = ts::take_shared_by_id<Turret>(ts, turret_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let mut character = ts::take_shared_by_id<Character>(ts, character_id);
        let owner_cap_id = turret::owner_cap_id(&turret);
        let turret_ticket = ts::receiving_ticket_by_id<OwnerCap<Turret>>(owner_cap_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Turret>(turret_ticket, ts.ctx());
        turret.online(&mut nwn, &energy_config, &owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };
}

fun turret_target_bcs_to_bytes(
    target_id: address,
    target_type_id: u64,
    target_character_id: address,
    target_character_tribe: u32,
    hp_ratio: u64,
    shield_ratio: u64,
    armor_ratio: u64,
    is_agressor: bool,
    weight: u64,
): vector<u8> {
    let target = TurretTargetBcs {
        target_id,
        target_type_id,
        target_character_id,
        target_character_tribe,
        hp_ratio,
        shield_ratio,
        armor_ratio,
        is_agressor,
        weight,
    };
    bcs::to_bytes(&target)
}

// === Tests ===

#[test]
fun anchor_turret_succeeds() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 101, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        assert_eq!(turret.type_id(), TURRET_TYPE_ID);
        assert_eq!(turret.is_online(), false);
        assert_eq!(turret.is_extension_configured(), false);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun online_and_offline_turret() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 102, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        assert_eq!(turret.is_online(), true);
        ts::return_shared(turret);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret::owner_cap_id(&turret)),
            ts.ctx(),
        );
        turret.offline(&mut nwn, &energy_config, &owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        assert_eq!(turret.is_online(), false);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun authorize_extension_succeeds() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 103, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);

    ts::next_tx(&mut ts, user_a());
    {
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret::owner_cap_id(&turret)),
            ts.ctx(),
        );
        turret.authorize_extension<TurretAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        assert_eq!(turret::is_extension_configured(&turret), true);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun priority_list_without_extension_adds_aggressor() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 104, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    let new_target_bytes = turret_target_bcs_to_bytes(
        @0x1,
        1,
        @0x2,
        200,
        80,
        50,
        30,
        true,
        10,
    );
    let empty_list: vector<u8> = vector::empty();

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret::verify_online(&turret);
        let result = turret.get_target_priority_list(
            &character,
            empty_list,
            new_target_bytes,
            receipt,
        );
        let decoded = turret::unpack_priority_list(result);
        assert_eq!(vector::length(&decoded), 1);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun priority_list_without_extension_adds_different_tribe() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 105, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    let new_target_bytes = turret_target_bcs_to_bytes(
        @0x1,
        1,
        @0x2,
        200,
        80,
        50,
        30,
        false,
        10,
    );
    let empty_list: vector<u8> = vector::empty();

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret::verify_online(&turret);
        let result = turret.get_target_priority_list(
            &character,
            empty_list,
            new_target_bytes,
            receipt,
        );
        let decoded = turret::unpack_priority_list(result);
        assert_eq!(vector::length(&decoded), 1);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun priority_list_without_extension_does_not_add_same_tribe() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 106, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    let new_target_bytes = turret_target_bcs_to_bytes(
        @0x1,
        1,
        @0x2,
        100,
        80,
        50,
        30,
        false,
        10,
    );
    let empty_list: vector<u8> = vector::empty();

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret::verify_online(&turret);
        let result = turret.get_target_priority_list(
            &character,
            empty_list,
            new_target_bytes,
            receipt,
        );
        let decoded = turret::unpack_priority_list(result);
        assert_eq!(vector::length(&decoded), 0);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun priority_list_with_extension_contract() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 103, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);

    ts::next_tx(&mut ts, user_a());
    {
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret::owner_cap_id(&turret)),
            ts.ctx(),
        );
        turret.authorize_extension<TurretAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
    };

    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    let new_target_bytes = turret_target_bcs_to_bytes(
        @0x1,
        1,
        @0x2,
        100,
        80,
        50,
        30,
        true,
        10,
    );
    let empty_list: vector<u8> = vector::empty();

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret::verify_online(&turret);
        let result = get_target_priority_list(
            &turret,
            &character,
            empty_list,
            new_target_bytes,
            receipt,
        );
        let decoded = turret::unpack_priority_list(result);
        assert_eq!(vector::length(&decoded), 0);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun peel_turret_target() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let bytes = turret_target_bcs_to_bytes(@0x1, 2, @0x3, 4, 50, 60, 70, true, 99);
    let decoded = turret::peel_turret_target(bytes);
    let re_encoded = bcs::to_bytes(&decoded);
    let decoded2 = turret::peel_turret_target(re_encoded);
    assert_eq!(turret::target_id(&decoded), turret::target_id(&decoded2));
    assert_eq!(turret::target_type_id(&decoded), turret::target_type_id(&decoded2));
    assert_eq!(turret::target_character_tribe(&decoded), turret::target_character_tribe(&decoded2));
    assert_eq!(turret::is_agressor(&decoded), turret::is_agressor(&decoded2));
    assert_eq!(turret::weight(&decoded), turret::weight(&decoded2));

    ts::end(ts);
}

#[test]
fun unpack_priority_list_empty() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let empty: vector<u8> = vector::empty();
    let list = turret::unpack_priority_list(empty);
    assert_eq!(vector::length(&list), 0);

    ts::end(ts);
}

#[test]
fun unanchor_turret_with_energy_source() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 107, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let orphaned_assemblies = nwn.unanchor(&admin_acl, ts.ctx());
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let updated = turret.offline_orphaned_turret(orphaned_assemblies, &mut nwn, &energy_config);
        nwn.destroy_network_node(updated, &admin_acl, ts.ctx());
        ts::return_shared(turret);
        ts::return_shared(energy_config);
        ts::return_shared(admin_acl);
    };
    ts::end(ts);
}

#[test]
fun unanchor_then_anchor_with_new_network_node() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 120, 100);
    let nwn_1_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_1_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_1_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_1_id);

    // Unanchor nwn_1: turret is offlined and orphaned, then nwn_1 is destroyed
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn_1 = ts::take_shared_by_id<NetworkNode>(&ts, nwn_1_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let orphaned_assemblies = nwn_1.unanchor(&admin_acl, ts.ctx());
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let updated = turret.offline_orphaned_turret(
            orphaned_assemblies,
            &mut nwn_1,
            &energy_config,
        );
        nwn_1.destroy_network_node(updated, &admin_acl, ts.ctx());
        ts::return_shared(turret);
        ts::return_shared(energy_config);
        ts::return_shared(admin_acl);
    };

    // Create and online a second network node
    let nwn_2_id = create_network_node_with_item_id(&mut ts, character_id, NWN_ITEM_ID_2);
    bring_network_node_online(&mut ts, character_id, nwn_2_id);

    // Re-anchor turret to the new network node (update_energy_source), then bring turret online
    ts::next_tx(&mut ts, admin());
    {
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let mut nwn_2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn_2_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        turret.update_energy_source(&mut nwn_2, &admin_acl, ts.ctx());
        ts::return_shared(turret);
        ts::return_shared(nwn_2);
        ts::return_shared(admin_acl);
    };

    bring_turret_online(&mut ts, character_id, turret_id, nwn_2_id);

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        assert_eq!(turret.is_online(), true);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

// === Negative tests ===

// anchor_fails_type_id_empty / anchor_fails_item_id_empty

#[test]
#[expected_failure(abort_code = turret::ENotOnline)]
fun priority_list_fails_when_offline() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 111, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    // Turret is never brought online; verify_online aborts with ENotOnline (destroy unreachable)
    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let receipt = turret::verify_online(&turret);
        receipt.destroy_online_receipt_test();
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = turret::EExtensionConfigured)]
fun priority_list_fails_when_extension_configured() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 112, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    ts::next_tx(&mut ts, user_a());
    {
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret::owner_cap_id(&turret)),
            ts.ctx(),
        );
        turret.authorize_extension<TurretAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
    };

    let new_target_bytes = turret_target_bcs_to_bytes(@0x1, 1, @0x2, 100, 80, 50, 30, true, 10);
    let empty_list: vector<u8> = vector::empty();

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret::verify_online(&turret);
        let _ = turret.get_target_priority_list(&character, empty_list, new_target_bytes, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = turret::ETurretNotAuthorized)]
fun online_fails_unauthorized_owner_cap() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 113, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_1_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    let turret_2_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_2);
    bring_network_node_online(&mut ts, character_id, nwn_id);

    ts::next_tx(&mut ts, user_a());
    {
        let turret_1 = ts::take_shared_by_id<Turret>(&ts, turret_1_id);
        let cap_1_id = turret::owner_cap_id(&turret_1);
        ts::return_shared(turret_1);
        let mut turret_2 = ts::take_shared_by_id<Turret>(&ts, turret_2_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let wrong_cap_ticket = ts::receiving_ticket_by_id<OwnerCap<Turret>>(cap_1_id);
        let (owner_cap_1, receipt) = character.borrow_owner_cap<Turret>(wrong_cap_ticket, ts.ctx());
        turret_2.online(&mut nwn, &energy_config, &owner_cap_1);
        character.return_owner_cap(owner_cap_1, receipt);
        ts::return_shared(character);
        ts::return_shared(turret_2);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = turret::ETurretHasEnergySource)]
fun unanchor_orphan_fails_when_has_energy_source() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 115, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);

    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        turret.unanchor_orphan(&admin_acl, ts.ctx());
        ts::return_shared(admin_acl);
    };
    ts::end(ts);
}
