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
    test_helpers::{Self, admin, governor, tenant, user_a, user_b},
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

// BCS layout for TargetCandidate: (u64, u64, u64, u32, u32, u64, u64, u64, bool, u64, behaviour_change u8). behaviour_change: 0=UNSPECIFIED, 1=ENTERED, 2=STARTED_ATTACK, 3=STOPPED_ATTACK
public struct TargetCandidateBcs has copy, drop {
    item_id: u64,
    type_id: u64,
    group_id: u64,
    character_id: u32,
    character_tribe: u32,
    hp_ratio: u64,
    shield_ratio: u64,
    armor_ratio: u64,
    is_aggressor: bool,
    priority_weight: u64,
    behaviour_change: u8,
}

// Mock extension witness for authorize_extension tests
public struct TurretAuth has drop {}

// Mock get_target_priority_list in extension contract: returns BCS of vector<ReturnTargetPriorityList>
public fun get_target_priority_list(
    turret: &Turret,
    _: &Character,
    target_candidate_list: vector<u8>,
    receipt: OnlineReceipt,
): vector<u8> {
    assert!(receipt.turret_id() == object::id(turret), 0);
    receipt.destroy_online_receipt(TurretAuth {});
    let list = turret::unpack_candidate_list(target_candidate_list);
    let mut return_list = vector::empty();
    let mut i = 0u64;
    let len = vector::length(&list);
    while (i < len) {
        let target_candidate = vector::borrow(&list, i);
        vector::push_back(
            &mut return_list,
            turret::new_return_target_priority_list(
                target_candidate.item_id(),
                target_candidate.priority_weight(),
            ),
        );
        i = i + 1;
    };
    bcs::to_bytes(&return_list)
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
        let nwn_owner_cap_id = nwn.owner_cap_id();
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
        let owner_cap_id = turret.owner_cap_id();
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

fun target_candidate_bcs_to_bytes(
    item_id: u64,
    type_id: u64,
    group_id: u64,
    character_id: u32,
    character_tribe: u32,
    hp_ratio: u64,
    shield_ratio: u64,
    armor_ratio: u64,
    is_aggressor: bool,
    priority_weight: u64,
    behaviour_change: u8,
): vector<u8> {
    let target_candidate = TargetCandidateBcs {
        item_id,
        type_id,
        group_id,
        character_id,
        character_tribe,
        hp_ratio,
        shield_ratio,
        armor_ratio,
        is_aggressor,
        priority_weight,
        behaviour_change,
    };
    bcs::to_bytes(&target_candidate)
}

fun candidate_list_bytes_from_target_candidate(
    item_id: u64,
    type_id: u64,
    group_id: u64,
    character_id: u32,
    character_tribe: u32,
    hp_ratio: u64,
    shield_ratio: u64,
    armor_ratio: u64,
    is_aggressor: bool,
    priority_weight: u64,
    behaviour_change: u8,
): vector<u8> {
    let target_candidate = TargetCandidateBcs {
        item_id,
        type_id,
        group_id,
        character_id,
        character_tribe,
        hp_ratio,
        shield_ratio,
        armor_ratio,
        is_aggressor,
        priority_weight,
        behaviour_change,
    };
    bcs::to_bytes(&vector[target_candidate])
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
        assert_eq!(turret.metadata().is_some(), true);
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
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret.owner_cap_id()),
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
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret.owner_cap_id()),
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
        assert_eq!(turret.is_extension_configured(), true);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun freeze_extension_config_succeeds() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 201, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);

    ts::next_tx(&mut ts, user_a());
    {
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret.owner_cap_id()),
            ts.ctx(),
        );
        turret.authorize_extension<TurretAuth>(&owner_cap);
        turret.freeze_extension_config(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        assert_eq!(turret.is_extension_frozen(), true);
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

    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        2,
        200,
        80,
        50,
        30,
        true,
        10,
        0,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret.verify_online();
        let result = turret.get_target_priority_list(
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
        assert_eq!(vector::length(&decoded), 1);
        let entry = vector::borrow(&decoded, 0);
        assert_eq!(turret::return_target_item_id(entry), 1);
        assert_eq!(turret::return_priority_weight(entry), 10);
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

    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        2,
        200,
        80,
        50,
        30,
        false,
        10,
        0,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret.verify_online();
        let result = turret.get_target_priority_list(
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
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

    // Game sends one target (same tribe 100 as owner, not aggressor).
    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        2,
        100,
        80,
        50,
        30,
        false,
        10,
        0,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        assert_eq!(character.tribe(), 100);
        let receipt = turret.verify_online();
        let result = turret.get_target_priority_list(
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
        assert_eq!(vector::length(&decoded), 0);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun priority_list_excludes_owner_by_character_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    // Owner has game_character_id 108 (create_character item_id).
    let character_id = create_character(&mut ts, user_a(), 108, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    // Single candidate: owner's ship (character_id 108). Would be included if not owner (different tribe 200, aggressor).
    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        108, // owner's game_character_id -> must be excluded
        200,
        80,
        50,
        30,
        true,
        10,
        0,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        assert_eq!(character.game_character_id(), 108);
        let receipt = turret.verify_online();
        let result = turret.get_target_priority_list(
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
        assert_eq!(vector::length(&decoded), 0);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun priority_list_same_tribe_aggressor_included() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 106, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        2,
        100,
        80,
        50,
        30,
        true,
        10,
        0,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret.verify_online();
        let result = turret.get_target_priority_list(
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
        assert_eq!(vector::length(&decoded), 1);
        let entry = vector::borrow(&decoded, 0);
        assert_eq!(turret::return_priority_weight(entry), 10);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun affected_bytes_unspecified() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 106, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        2,
        200,
        80,
        50,
        30,
        false,
        10,
        0,
    ); // behaviour_change 0 = UNSPECIFIED

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret.verify_online();
        let result = turret.get_target_priority_list(
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
        assert_eq!(vector::length(&decoded), 1);
        let entry = vector::borrow(&decoded, 0);
        assert_eq!(turret::return_priority_weight(entry), 10);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun affected_bytes_entered() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 106, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        2,
        200,
        80,
        50,
        30,
        false,
        10,
        1,
    ); // behaviour_change 1 = ENTERED

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret.verify_online();
        let result = turret.get_target_priority_list(
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
        assert_eq!(vector::length(&decoded), 1);
        let entry = vector::borrow(&decoded, 0);
        assert_eq!(turret::return_priority_weight(entry), 1010); // base 10 + 1000
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun affected_bytes_started_attack() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 106, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        2,
        200,
        80,
        50,
        30,
        false,
        10,
        2,
    ); // behaviour_change 2 = STARTED_ATTACK

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret.verify_online();
        let result = turret.get_target_priority_list(
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
        assert_eq!(vector::length(&decoded), 1);
        let entry = vector::borrow(&decoded, 0);
        assert_eq!(turret::return_priority_weight(entry), 10010); // base 10 + 10000
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun affected_bytes_stopped_attack() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 106, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);
    bring_network_node_online(&mut ts, character_id, nwn_id);
    bring_turret_online(&mut ts, character_id, turret_id, nwn_id);

    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        2,
        200,
        80,
        50,
        30,
        false,
        10,
        3,
    ); // behaviour_change 3 = STOPPED_ATTACK

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret.verify_online();
        let result = turret.get_target_priority_list(
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
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

    let candidate_list_bytes = candidate_list_bytes_from_target_candidate(
        1,
        1,
        0,
        2,
        100,
        80,
        50,
        30,
        true,
        10,
        0,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret.verify_online();
        let result = get_target_priority_list(
            &turret,
            &character,
            candidate_list_bytes,
            receipt,
        );
        let decoded = turret::unpack_return_priority_list(result);
        assert_eq!(vector::length(&decoded), 1);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
fun peel_target_candidate() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let bytes = target_candidate_bcs_to_bytes(1, 2, 31, 3, 4, 50, 60, 70, true, 99, 0);
    let decoded = turret::peel_target_candidate(bytes);
    let re_encoded = bcs::to_bytes(&decoded);
    let decoded2 = turret::peel_target_candidate(re_encoded);
    assert_eq!(decoded.item_id(), decoded2.item_id());
    assert_eq!(decoded.target_type_id(), decoded2.target_type_id());
    assert_eq!(decoded.group_id(), decoded2.group_id());
    assert_eq!(decoded.character_id(), decoded2.character_id());
    assert_eq!(decoded.character_tribe(), decoded2.character_tribe());
    assert_eq!(decoded.is_aggressor(), decoded2.is_aggressor());
    assert_eq!(decoded.priority_weight(), decoded2.priority_weight());

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

#[test]
#[expected_failure(abort_code = turret::ETurretTypeIdEmpty)]
fun anchor_fails_type_id_empty() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 110, 100);
    let nwn_id = create_network_node(&mut ts, character_id);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let turret = turret::anchor(
            &mut registry,
            &mut nwn,
            &character,
            &admin_acl,
            TURRET_ITEM_ID_1,
            0, // type_id empty
            test_helpers::get_verified_location_hash(),
            ts.ctx(),
        );
        turret.share_turret(&admin_acl, ts.ctx());
        ts::return_shared(character);
        ts::return_shared(nwn);
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = turret::ETurretItemIdEmpty)]
fun anchor_fails_item_id_empty() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 111, 100);
    let nwn_id = create_network_node(&mut ts, character_id);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let turret = turret::anchor(
            &mut registry,
            &mut nwn,
            &character,
            &admin_acl,
            0, // item_id empty
            TURRET_TYPE_ID,
            test_helpers::get_verified_location_hash(),
            ts.ctx(),
        );
        turret.share_turret(&admin_acl, ts.ctx());
        ts::return_shared(character);
        ts::return_shared(nwn);
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
    };
    ts::end(ts);
}

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
        let receipt = turret.verify_online();
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

    let empty_priority: vector<u8> = vector::empty();
    ts::next_tx(&mut ts, user_a());
    {
        let turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let receipt = turret.verify_online();
        let _ = turret.get_target_priority_list(
            &character,
            empty_priority,
            receipt,
        );
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

#[test]
#[expected_failure(abort_code = turret::ETurretNotAuthorized)]
fun test_update_metadata_turret_wrong_cap() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);
    let character_a_id = create_character(&mut ts, user_a(), 117, 100);
    let character_b_id = create_character(&mut ts, user_b(), 118, 100);
    let nwn_a_id = create_network_node(&mut ts, character_a_id);
    let nwn_b_id = create_network_node_with_item_id(&mut ts, character_b_id, NWN_ITEM_ID_2);
    let turret_a_id = create_turret(&mut ts, character_a_id, nwn_a_id, TURRET_ITEM_ID_1);
    let turret_b_id = create_turret(&mut ts, character_b_id, nwn_b_id, TURRET_ITEM_ID_2);

    ts::next_tx(&mut ts, user_b());
    {
        let mut turret_a = ts::take_shared_by_id<Turret>(&ts, turret_a_id);
        let mut character_b = ts::take_shared_by_id<Character>(&ts, character_b_id);
        let turret_b = ts::take_shared_by_id<Turret>(&ts, turret_b_id);
        let (owner_cap_b, receipt) = character_b.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret_b.owner_cap_id()),
            ts.ctx(),
        );
        turret_a.update_metadata_name(&owner_cap_b, utf8(b"X"));
        character_b.return_owner_cap(owner_cap_b, receipt);
        ts::return_shared(character_b);
        ts::return_shared(turret_b);
        ts::return_shared(turret_a);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = turret::EExtensionConfigFrozen)]
fun authorize_extension_fails_after_freeze() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 202, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);

    ts::next_tx(&mut ts, user_a());
    {
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret.owner_cap_id()),
            ts.ctx(),
        );
        turret.authorize_extension<TurretAuth>(&owner_cap);
        turret.freeze_extension_config(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret.owner_cap_id()),
            ts.ctx(),
        );
        turret.authorize_extension<TurretAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = turret::EExtensionNotConfigured)]
fun freeze_extension_config_fails_when_no_extension() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 203, 100);
    let nwn_id = create_network_node(&mut ts, character_id);
    let turret_id = create_turret(&mut ts, character_id, nwn_id, TURRET_ITEM_ID_1);

    ts::next_tx(&mut ts, user_a());
    {
        let mut turret = ts::take_shared_by_id<Turret>(&ts, turret_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret.owner_cap_id()),
            ts.ctx(),
        );
        turret.freeze_extension_config(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(turret);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = turret::ETurretNotAuthorized)]
fun freeze_extension_config_fails_unauthorized() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_a_id = create_character(&mut ts, user_a(), 204, 100);
    let character_b_id = create_character(&mut ts, user_b(), 205, 101);
    let nwn_id = create_network_node(&mut ts, character_a_id);
    let turret_a_id = create_turret(&mut ts, character_a_id, nwn_id, TURRET_ITEM_ID_1);
    let turret_b_id = create_turret(&mut ts, character_b_id, nwn_id, TURRET_ITEM_ID_2);

    ts::next_tx(&mut ts, user_a());
    {
        let mut turret_a = ts::take_shared_by_id<Turret>(&ts, turret_a_id);
        let mut character_a = ts::take_shared_by_id<Character>(&ts, character_a_id);
        let (owner_cap_a, receipt_a) = character_a.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret_a.owner_cap_id()),
            ts.ctx(),
        );
        turret_a.authorize_extension<TurretAuth>(&owner_cap_a);
        character_a.return_owner_cap(owner_cap_a, receipt_a);
        ts::return_shared(character_a);
        ts::return_shared(turret_a);
    };

    ts::next_tx(&mut ts, user_b());
    {
        let mut turret_a = ts::take_shared_by_id<Turret>(&ts, turret_a_id);
        let turret_b = ts::take_shared_by_id<Turret>(&ts, turret_b_id);
        let mut character_b = ts::take_shared_by_id<Character>(&ts, character_b_id);
        let (owner_cap_b, receipt_b) = character_b.borrow_owner_cap<Turret>(
            ts::receiving_ticket_by_id<OwnerCap<Turret>>(turret_b.owner_cap_id()),
            ts.ctx(),
        );
        turret_a.freeze_extension_config(&owner_cap_b);
        character_b.return_owner_cap(owner_cap_b, receipt_b);
        ts::return_shared(character_b);
        ts::return_shared(turret_a);
        ts::return_shared(turret_b);
    };
    ts::end(ts);
}
