#[test_only]
module world::metadata_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::test_scenario as ts;
use world::{
    access::{AdminCap, OwnerCap},
    assembly::{Self, Assembly, AssemblyRegistry},
    character::{Self, Character, CharacterRegistry},
    metadata,
    network_node::{Self, NetworkNode, NetworkNodeRegistry},
    test_helpers::{Self, admin, governor, user_a, user_b, tenant}
};

const ITEM_ID: u64 = 1001;
const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const TYPE_ID: u64 = 1;
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
            let mut registry = ts::take_shared<CharacterRegistry>(ts);
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
    let mut nwn_registry = ts::take_shared<NetworkNodeRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    let nwn = network_node::anchor(
        &mut nwn_registry,
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
    ts::return_shared(nwn_registry);
    id
}

fun create_assembly(ts: &mut ts::Scenario, nwn_id: ID, owner: address, item_id: u64): ID {
    let character_id = create_character(ts, owner, (item_id as u32));
    ts::next_tx(ts, admin());
    let mut assembly_registry = ts::take_shared<AssemblyRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    let assembly = assembly::anchor(
        &mut assembly_registry,
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
    ts::return_shared(assembly_registry);
    ts::return_shared(nwn);
    assembly_id
}

#[test]
fun test_metadata_lifecycle() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let nwn_id = create_network_node(&mut ts);
    let assembly_id = create_assembly(&mut ts, nwn_id, user_a(), ITEM_ID);

    // Create
    let mut metadata = metadata::create_metadata(
        assembly_id,
        ITEM_ID,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    assert_eq!(metadata::name(&metadata), NAME.to_string());
    assert_eq!(metadata::description(&metadata), DESCRIPTION.to_string());
    assert_eq!(metadata::url(&metadata), URL.to_string());

    // Update Name
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<Assembly>>(&ts);
        metadata::update_name(&mut metadata, &owner_cap, NEW_NAME.to_string());
        assert_eq!(metadata::name(&metadata), NEW_NAME.to_string());
        ts::return_to_sender(&ts, owner_cap);
    };

    // Update Description
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<Assembly>>(&ts);
        metadata::update_description(&mut metadata, &owner_cap, NEW_DESC.to_string());
        assert_eq!(metadata::description(&metadata), NEW_DESC.to_string());
        ts::return_to_sender(&ts, owner_cap);
    };

    // Update URL
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<Assembly>>(&ts);
        metadata::update_url(&mut metadata, &owner_cap, NEW_URL.to_string());
        assert_eq!(metadata::url(&metadata), NEW_URL.to_string());
        ts::return_to_sender(&ts, owner_cap);
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
    let assembly_id = create_assembly(&mut ts, nwn_id, user_a(), ITEM_ID);
    let mut metadata = metadata::create_metadata(
        assembly_id,
        ITEM_ID,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    // Create a second assembly for user_b to get an OwnerCap for a different assembly
    create_assembly(&mut ts, nwn_id, user_b(), USER_B_ITEM_ID);

    // Try to update with wrong owner cap (user_b)
    ts::next_tx(&mut ts, user_b());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<Assembly>>(&ts);
        metadata::update_name(&mut metadata, &owner_cap, NEW_NAME.to_string());
        ts::return_to_sender(&ts, owner_cap);
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
    let assembly_id = create_assembly(&mut ts, nwn_id, user_a(), ITEM_ID);

    let mut metadata = metadata::create_metadata(
        assembly_id,
        ITEM_ID,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    // Create a second assembly for user_b to get an OwnerCap for a different assembly
    create_assembly(&mut ts, nwn_id, user_b(), USER_B_ITEM_ID);

    // Try to update with wrong owner cap
    ts::next_tx(&mut ts, user_b());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<Assembly>>(&ts);
        metadata::update_description(&mut metadata, &owner_cap, NEW_DESC.to_string());
        ts::return_to_sender(&ts, owner_cap);
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
    let assembly_id = create_assembly(&mut ts, nwn_id, user_a(), ITEM_ID);

    let mut metadata = metadata::create_metadata(
        assembly_id,
        ITEM_ID,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    // Create a second assembly for user_b to get an OwnerCap for a different assembly
    create_assembly(&mut ts, nwn_id, user_b(), USER_B_ITEM_ID);

    // Try to update with wrong owner cap
    ts::next_tx(&mut ts, user_b());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<Assembly>>(&ts);
        metadata::update_url(&mut metadata, &owner_cap, NEW_URL.to_string());
        ts::return_to_sender(&ts, owner_cap);
    };

    metadata.delete();
    ts::end(ts);
}
