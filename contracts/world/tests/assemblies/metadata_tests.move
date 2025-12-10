#[test_only]
module world::metadata_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{authority::OwnerCap, metadata, test_helpers::{Self, governor, user_a, user_b}};

const ITEM_ID: u64 = 1001;
const NAME: vector<u8> = b"Candy Machine";
const DESCRIPTION: vector<u8> = b"I sell candy for kindness";
const URL: vector<u8> = b"https://example.com/item.png";

const NEW_NAME: vector<u8> = b"Christmas Cookies";
const NEW_DESC: vector<u8> = b"cookies for kindness";
const NEW_URL: vector<u8> = b"https://example.com/updated.png";

#[test]
fun test_metadata_lifecycle() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let assembly_id = object::id_from_address(@0x2);
    test_helpers::setup_owner_cap(&mut ts, user_a(), assembly_id);

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
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        metadata::update_name(&mut metadata, &owner_cap, NEW_NAME.to_string());
        assert_eq!(metadata::name(&metadata), NEW_NAME.to_string());
        ts::return_to_sender(&ts, owner_cap);
    };

    // Update Description
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        metadata::update_description(&mut metadata, &owner_cap, NEW_DESC.to_string());
        assert_eq!(metadata::description(&metadata), NEW_DESC.to_string());
        ts::return_to_sender(&ts, owner_cap);
    };

    // Update URL
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
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

    let assembly_id = object::id_from_address(@0x2);
    test_helpers::setup_owner_cap(&mut ts, user_a(), assembly_id);

    let mut metadata = metadata::create_metadata(
        assembly_id,
        ITEM_ID,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    // Try to update with wrong owner cap (user_b)
    let dummy_id = object::id_from_address(@0x3);
    test_helpers::setup_owner_cap(&mut ts, user_b(), dummy_id);

    ts::next_tx(&mut ts, user_b());
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
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

    let assembly_id = object::id_from_address(@0x2);
    test_helpers::setup_owner_cap(&mut ts, user_a(), assembly_id);

    let mut metadata = metadata::create_metadata(
        assembly_id,
        ITEM_ID,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    // Try to update with wrong owner cap
    let dummy_id = object::id_from_address(@0x3);
    test_helpers::setup_owner_cap(&mut ts, user_b(), dummy_id);

    ts::next_tx(&mut ts, user_b());
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
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

    let assembly_id = object::id_from_address(@0x2);
    test_helpers::setup_owner_cap(&mut ts, user_a(), assembly_id);

    let mut metadata = metadata::create_metadata(
        assembly_id,
        ITEM_ID,
        NAME.to_string(),
        DESCRIPTION.to_string(),
        URL.to_string(),
    );

    // Try to update with wrong owner cap
    let dummy_id = object::id_from_address(@0x3);
    test_helpers::setup_owner_cap(&mut ts, user_b(), dummy_id);

    ts::next_tx(&mut ts, user_b());
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        metadata::update_url(&mut metadata, &owner_cap, NEW_URL.to_string());
        ts::return_to_sender(&ts, owner_cap);
    };

    metadata.delete();
    ts::end(ts);
}
