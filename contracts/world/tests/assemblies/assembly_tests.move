#[test_only]
module world::assembly_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::{clock, test_scenario as ts};
use world::{
    access::{Self, AdminACL, OwnerCap},
    assembly::{Self, Assembly},
    character::{Self, Character},
    energy::{Self, EnergyConfig},
    location::{Self, LocationRegistry},
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    status,
    test_helpers::{Self, governor, admin, user_a, user_b, tenant, in_game_id}
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

const ASSEMBLY_B_ITEM_ID: u64 = 1002;
const CHARACTER_B_ITEM_ID: u32 = 2002;

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
            let admin_acl = ts::take_shared<AdminACL>(ts);
            let mut registry = ts::take_shared<ObjectRegistry>(ts);
            let character = character::create_character(
                &mut registry,
                &admin_acl,
                item_id,
                tenant(),
                100,
                user,
                utf8(b"name"),
                ts.ctx(),
            );
            let character_id = object::id(&character);
            character.share_character(&admin_acl, ts.ctx());
            ts::return_shared(registry);
            ts::return_shared(admin_acl);
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
    let admin_acl = ts::take_shared<AdminACL>(ts);

    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_acl,
        NWN_ITEM_ID,
        NWN_TYPE_ID,
        LOCATION_HASH,
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let id = object::id(&nwn);
    nwn.share_network_node(&admin_acl, ts.ctx());

    ts::return_shared(character);
    ts::return_shared(admin_acl);
    ts::return_shared(registry);
    id
}

// Helper to create assembly. Returns assembly_id.
fun create_assembly(ts: &mut ts::Scenario, nwn_id: ID, character_id: ID): ID {
    create_assembly_with_item_id(ts, nwn_id, character_id, ITEM_ID)
}

fun create_assembly_with_item_id(
    ts: &mut ts::Scenario,
    nwn_id: ID,
    character_id: ID,
    item_id: u64,
): ID {
    ts::next_tx(ts, admin());
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);

    let assembly = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        item_id,
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    let assembly_id = object::id(&assembly);
    assembly.share_assembly(&admin_acl, ts.ctx());

    ts::return_shared(character);
    ts::return_shared(admin_acl);
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
    let (owner_cap, receipt) = character.borrow_owner_cap<NetworkNode>(
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
    character.return_owner_cap(owner_cap, receipt);

    ts::next_tx(&mut ts, user_a());
    let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
    let energy_config = ts::take_shared<EnergyConfig>(&ts);

    // OwnerCap<Assembly> is on Character; borrow from character, use, return
    ts::next_tx(&mut ts, user_a());
    {
        let (owner_cap, receipt) = character.borrow_owner_cap<Assembly>(
            ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id),
            ts.ctx(),
        );
        assert_eq!(energy::total_reserved_energy(nwn.energy()), 0);

        assembly.online(&mut nwn, &energy_config, &owner_cap);
        assert_eq!(status::status_to_u8(assembly::status(&assembly)), STATUS_ONLINE);
        assert_eq!(energy::total_reserved_energy(nwn.energy()), ASSEMBLY_ENERGY_REQUIRED);

        character.return_owner_cap(owner_cap, receipt);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let access_cap_ticket = ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Assembly>(
            access_cap_ticket,
            ts.ctx(),
        );
        assert_eq!(energy::total_reserved_energy(nwn.energy()), ASSEMBLY_ENERGY_REQUIRED);

        assembly.offline(&mut nwn, &energy_config, &owner_cap);
        assert_eq!(status::status_to_u8(assembly::status(&assembly)), STATUS_OFFLINE);
        assert_eq!(energy::total_reserved_energy(nwn.energy()), 0);

        character.return_owner_cap(owner_cap, receipt);
    };

    ts::return_shared(assembly);
    ts::return_shared(nwn);
    ts::return_shared(energy_config);
    ts::return_shared(character);
    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun test_borrow_owner_cap_and_transfer_to_address() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), (CHARACTER_ITEM_ID as u32));
    let nwn_id = create_network_node(&mut ts, character_id);
    let assembly_id = create_assembly(&mut ts, nwn_id, character_id);
    let clock = clock::create_for_testing(ts.ctx());

    // OwnerCap<Assembly> is on Character; borrow from character, transfer to user_b, then use as user_b in next tx
    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Assembly>(
            ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id),
            ts.ctx(),
        );

        access::transfer_owner_cap_with_receipt<Assembly>(
            owner_cap,
            receipt,
            user_b(),
            ts.ctx(),
        );
        ts::return_shared(character);
    };

    // Bring network node online so assembly can reserve energy
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<NetworkNode>(
            ts::most_recent_receiving_ticket<OwnerCap<NetworkNode>>(&character_id),
            ts.ctx(),
        );
        nwn.deposit_fuel_test(&owner_cap, FUEL_TYPE_ID, FUEL_VOLUME, 10, &clock);
        nwn.online(&owner_cap, &clock);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(nwn);
    };

    // user_b (new owner of the cap) brings assembly online to validate cross-account transfer
    ts::next_tx(&mut ts, user_b());
    {
        let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap<Assembly>>(&ts);
        assembly.online(&mut nwn, &energy_config, &owner_cap);
        ts::return_to_sender(&ts, owner_cap);
        ts::return_shared(assembly);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };
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
    let admin_acl = ts::take_shared<AdminACL>(&ts);

    let assembly = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
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
    assembly.unanchor(&mut nwn, &energy_config, &admin_acl, ts.ctx());
    assert!(!network_node::is_assembly_connected(&nwn, assembly_id), 0);

    // As per implementation, derived object is not reclaimed, so assembly_exists should be true
    // but object is gone.
    assert!(registry.object_exists(in_game_id(ITEM_ID)), 0);

    ts::return_shared(nwn);
    ts::return_shared(energy_config);
    ts::return_shared(admin_acl);
    ts::return_shared(registry);
    ts::end(ts);
}

#[test]
fun reveal_assembly_location() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), (CHARACTER_ITEM_ID as u32));
    let nwn_id = create_network_node(&mut ts, character_id);
    let assembly_id = create_assembly(&mut ts, nwn_id, character_id);

    let solarsystem: u64 = 42;
    let x = utf8(b"100");
    let y = utf8(b"200");
    let z = utf8(b"300");

    ts::next_tx(&mut ts, admin());
    {
        let assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let mut registry = ts::take_shared<LocationRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        assembly::reveal_location(
            &assembly,
            &mut registry,
            &admin_acl,
            solarsystem,
            x,
            y,
            z,
            ts.ctx(),
        );
        ts::return_shared(admin_acl);
        ts::return_shared(registry);
        ts::return_shared(assembly);
    };

    ts::next_tx(&mut ts, admin());
    {
        let registry = ts::take_shared<LocationRegistry>(&ts);
        let coords = location::get_location(&registry, assembly_id);
        assert!(option::is_some(&coords), 0);
        let coords_ref = option::borrow(&coords);
        let expected_solarsystem: u64 = 42;
        let expected_x = utf8(b"100");
        let expected_y = utf8(b"200");
        let expected_z = utf8(b"300");
        assert_eq!(location::solarsystem(coords_ref), expected_solarsystem);
        assert_eq!(location::x(coords_ref), expected_x);
        assert_eq!(location::y(coords_ref), expected_y);
        assert_eq!(location::z(coords_ref), expected_z);
        ts::return_shared(registry);
    };
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
    let admin_acl = ts::take_shared<AdminACL>(&ts);
    let assembly1 = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        ITEM_ID,
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    assembly1.share_assembly(&admin_acl, ts.ctx());

    // Second anchor with same ITEM_ID should fail
    let assembly2 = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        ITEM_ID,
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    ts::return_shared(character);
    assembly2.share_assembly(&admin_acl, ts.ctx());

    ts::return_shared(admin_acl);
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
    let admin_acl = ts::take_shared<AdminACL>(&ts);

    let assembly = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        ITEM_ID,
        0, // Invalid Type ID
        LOCATION_HASH,
        ts.ctx(),
    );
    ts::return_shared(character);
    assembly.share_assembly(&admin_acl, ts.ctx());

    ts::return_shared(admin_acl);
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
    let admin_acl = ts::take_shared<AdminACL>(&ts);

    let assembly = assembly::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        0, // Invalid Item ID
        TYPE_ID,
        LOCATION_HASH,
        ts.ctx(),
    );
    ts::return_shared(character);
    assembly.share_assembly(&admin_acl, ts.ctx());

    ts::return_shared(admin_acl);
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
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        assembly.unanchor_orphan(&admin_acl, ts.ctx());
        ts::return_shared(admin_acl);
    };

    ts::end(ts);
}

#[test]
fun test_update_metadata_assembly_success() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), (CHARACTER_ITEM_ID as u32));
    let nwn_id = create_network_node(&mut ts, character_id);
    let assembly_id = create_assembly(&mut ts, nwn_id, character_id);

    ts::next_tx(&mut ts, user_a());
    {
        let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Assembly>(
            ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id),
            ts.ctx(),
        );
        assembly.update_metadata_name(&owner_cap, utf8(b"New Name"));
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(assembly);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::EAssemblyNotAuthorized)]
fun test_update_metadata_assembly_wrong_cap() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_a_id = create_character(&mut ts, user_a(), (CHARACTER_ITEM_ID as u32));
    let nwn_id = create_network_node(&mut ts, character_a_id);
    let assembly_a_id = create_assembly(&mut ts, nwn_id, character_a_id);

    let character_b_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);
    let _assembly_b_id = create_assembly_with_item_id(
        &mut ts,
        nwn_id,
        character_b_id,
        ASSEMBLY_B_ITEM_ID,
    );

    // user_b tries to update user_a's assembly using user_b's OwnerCap<Assembly>
    ts::next_tx(&mut ts, user_b());
    {
        let mut assembly_a = ts::take_shared_by_id<Assembly>(&ts, assembly_a_id);
        let mut character_b = ts::take_shared_by_id<Character>(&ts, character_b_id);
        let (owner_cap_b, receipt) = character_b.borrow_owner_cap<Assembly>(
            ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_b_id),
            ts.ctx(),
        );
        assembly_a.update_metadata_name(&owner_cap_b, utf8(b"X"));
        character_b.return_owner_cap(owner_cap_b, receipt);
        ts::return_shared(character_b);
        ts::return_shared(assembly_a);
    };
    ts::end(ts);
}
