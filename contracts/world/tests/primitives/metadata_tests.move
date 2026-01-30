#[test_only]
module world::metadata_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::test_scenario as ts;
use world::{
    access::{AdminCap, OwnerCap},
    assembly::{Self, Assembly},
    character::{Self, Character},
    in_game_id,
    metadata,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, user_a, user_b, tenant}
};

const ITEM_ID: u64 = 1001;
const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const TYPE_ID: u64 = 1;
const CHARACTER_ITEM_ID_OFFSET: u32 = 10000;
const NAME: vector<u8> = b"Candy Machine";
const DESCRIPTION: vector<u8> = b"I sell candy for kindness";
const URL: vector<u8> = b"https://example.com/item.png";

const NEW_NAME: vector<u8> = b"Christmas Cookies";
const NEW_DESC: vector<u8> = b"cookies for kindness";
const NEW_URL: vector<u8> = b"https://example.com/updated.png";

const USER_B_ITEM_ID: u64 = 1002;

const NWN_ITEM_ID: u64 = 5000;
const NWN_TYPE_ID: u64 = 111000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * 1000;
const MAX_PRODUCTION: u64 = 100;

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

fun create_network_node(ts: &mut ts::Scenario): ID {
    let character_id = create_character(ts, user_a(), 1);
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

fun create_assembly(ts: &mut ts::Scenario, nwn_id: ID, owner: address, item_id: u64): (ID, ID) {
    let character_item_id = (item_id as u32) + CHARACTER_ITEM_ID_OFFSET;
    let character_id = create_character(ts, owner, character_item_id);
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
    let assembly_id = object::id(&assembly);
    assembly::share_assembly(assembly, &admin_cap);

    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(registry);
    ts::return_shared(nwn);
    (assembly_id, character_id)
}

/// Borrows OwnerCap<Assembly> from character; caller must return it with character::return_owner_cap and then ts::return_shared(character).
fun borrow_assembly_owner_cap(
    character: &mut Character,
    ts: &mut ts::Scenario,
): OwnerCap<Assembly> {
    let character_id = object::id(character);
    let access_cap_ticket = ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id);
    character.borrow_owner_cap<Assembly>(access_cap_ticket, ts.ctx())
}

#[test]
fun test_metadata_lifecycle() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let nwn_id = create_network_node(&mut ts);
    let (assembly_id, character_id) = create_assembly(&mut ts, nwn_id, user_a(), ITEM_ID);
    let assembly_key = in_game_id::create_key(ITEM_ID, tenant());

    // Create
    let mut metadata = metadata::create_metadata(
        assembly_id,
        assembly_key,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    assert_eq!(metadata.name(), NAME.to_string());
    assert_eq!(metadata.description(), DESCRIPTION.to_string());
    assert_eq!(metadata.url(), URL.to_string());

    // Update Name (OwnerCap<Assembly> is on Character; borrow from character)
    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let owner_cap = borrow_assembly_owner_cap(&mut character, &mut ts);
        metadata.update_name(assembly_key, &owner_cap, NEW_NAME.to_string());
        assert_eq!(metadata.name(), NEW_NAME.to_string());
        character.return_owner_cap(owner_cap);
        ts::return_shared(character);
    };

    // Update Description
    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let owner_cap = borrow_assembly_owner_cap(&mut character, &mut ts);
        metadata.update_description(assembly_key, &owner_cap, NEW_DESC.to_string());
        assert_eq!(metadata.description(), NEW_DESC.to_string());
        character.return_owner_cap(owner_cap);
        ts::return_shared(character);
    };

    // Update URL
    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let owner_cap = borrow_assembly_owner_cap(&mut character, &mut ts);
        metadata.update_url(assembly_key, &owner_cap, NEW_URL.to_string());
        assert_eq!(metadata.url(), NEW_URL.to_string());
        character.return_owner_cap(owner_cap);
        ts::return_shared(character);
    };

    // Delete : Ideally the calling function is admin capped
    metadata.delete();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = metadata::ENotAuthorized)]
fun test_update_name_unauthorized() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let nwn_id = create_network_node(&mut ts);
    let (assembly_id, _) = create_assembly(&mut ts, nwn_id, user_a(), ITEM_ID);
    let assembly_key = in_game_id::create_key(ITEM_ID, tenant());

    let mut metadata = metadata::create_metadata(
        assembly_id,
        assembly_key,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    // Create a second assembly for user_b (their OwnerCap<Assembly> is on their character)
    let (_, user_b_character_id) = create_assembly(&mut ts, nwn_id, user_b(), USER_B_ITEM_ID);

    // Try to update with wrong owner cap (user_b's cap is for a different assembly)
    ts::next_tx(&mut ts, user_b());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, user_b_character_id);
        let owner_cap = borrow_assembly_owner_cap(&mut character, &mut ts);
        metadata.update_name(assembly_key, &owner_cap, NEW_NAME.to_string());
        character.return_owner_cap(owner_cap);
        ts::return_shared(character);
    };

    metadata.delete();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = metadata::ENotAuthorized)]
fun test_update_description_unauthorized() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let nwn_id = create_network_node(&mut ts);
    let (assembly_id, _) = create_assembly(&mut ts, nwn_id, user_a(), ITEM_ID);
    let assembly_key = in_game_id::create_key(ITEM_ID, tenant());

    let mut metadata = metadata::create_metadata(
        assembly_id,
        assembly_key,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    let (_, user_b_character_id) = create_assembly(&mut ts, nwn_id, user_b(), USER_B_ITEM_ID);

    ts::next_tx(&mut ts, user_b());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, user_b_character_id);
        let owner_cap = borrow_assembly_owner_cap(&mut character, &mut ts);
        metadata.update_description(assembly_key, &owner_cap, NEW_DESC.to_string());
        character.return_owner_cap(owner_cap);
        ts::return_shared(character);
    };

    metadata.delete();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = metadata::ENotAuthorized)]
fun test_update_url_unauthorized() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let nwn_id = create_network_node(&mut ts);
    let (assembly_id, _) = create_assembly(&mut ts, nwn_id, user_a(), ITEM_ID);
    let assembly_key = in_game_id::create_key(ITEM_ID, tenant());

    let mut metadata = metadata::create_metadata(
        assembly_id,
        assembly_key,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    let (_, user_b_character_id) = create_assembly(&mut ts, nwn_id, user_b(), USER_B_ITEM_ID);

    ts::next_tx(&mut ts, user_b());
    {
        let mut character = ts::take_shared_by_id<Character>(&ts, user_b_character_id);
        let owner_cap = borrow_assembly_owner_cap(&mut character, &mut ts);
        metadata.update_url(assembly_key, &owner_cap, NEW_URL.to_string());
        character.return_owner_cap(owner_cap);
        ts::return_shared(character);
    };

    metadata.delete();
    ts::end(ts);
}
