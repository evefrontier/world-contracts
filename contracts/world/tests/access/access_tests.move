#[test_only]
module world::access_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::test_scenario as ts;
use world::{
    access::{Self, AdminACL, OwnerCap},
    assembly::{Self, Assembly},
    character::{Self, Character},
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    test_helpers::{Self, TestObject, governor, admin, user_a, user_b, tenant}
};

const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const ASSEMBLY_TYPE_ID: u64 = 8888;
const ASSEMBLY_ITEM_ID: u64 = 1001;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * 1000;
const MAX_PRODUCTION: u64 = 100;

fun setup_character_with_assembly(ts: &mut ts::Scenario): ID {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);

    let character_id = {
        ts::next_tx(ts, admin());
        let admin_acl = ts::take_shared<AdminACL>(ts);
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let character = character::create_character(
            &mut registry,
            &admin_acl,
            2000,
            tenant(),
            100,
            user_a(),
            utf8(b"name"),
            ts.ctx(),
        );
        let id = object::id(&character);
        character.share_character(&admin_acl, ts.ctx());
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
        id
    };

    let nwn_id = {
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
    };

    ts::next_tx(ts, admin());
    {
        let character = ts::take_shared_by_id<Character>(ts, character_id);
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let admin_acl = ts::take_shared<AdminACL>(ts);
        let assembly = assembly::anchor(
            &mut registry,
            &mut nwn,
            &character,
            &admin_acl,
            ASSEMBLY_ITEM_ID,
            ASSEMBLY_TYPE_ID,
            LOCATION_HASH,
            ts.ctx(),
        );
        assembly.share_assembly(&admin_acl, ts.ctx());
        ts::return_shared(character);
        ts::return_shared(admin_acl);
        ts::return_shared(registry);
        ts::return_shared(nwn);
    };
    character_id
}

/// Tests creating, transferring, and deleting an owner cap
/// Scenario: Admin creates an owner cap, transfers it to a user, then deletes it
/// Expected: Owner cap is created, transferred successfully, and can be deleted by admin
#[test]
fun create_transfer_and_delete_owner_cap() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::create_test_object(&mut ts, user_a());

    ts::next_tx(&mut ts, admin());
    {
        let owner_cap = ts::take_from_address<OwnerCap<TestObject>>(&ts, user_a());
        let admin_acl = ts::take_shared<AdminACL>(&ts);

        // Only possible in tests
        access::delete_owner_cap(owner_cap, &admin_acl, ts.ctx());

        ts::return_shared(admin_acl);
    };
    ts::end(ts);
}

/// Tests that owner cap authorization works correctly after transfer
/// Scenario: Admin creates owner cap, transfers it, then verifies authorization
/// Expected: Authorization check returns true for correct object ID
#[test]
fun owner_cap_authorization_after_transfer() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let target_object_id = test_helpers::create_test_object(&mut ts, user_a());
    let wrong_object_id = object::id_from_address(@0x5678);

    // User verifies authorization
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<TestObject>>(&ts);

        // Should be authorized for the correct object
        assert_eq!(access::is_authorized<TestObject>(&owner_cap, target_object_id), true);
        // Should NOT be authorized for a different object
        assert_eq!(access::is_authorized<TestObject>(&owner_cap, wrong_object_id), false);

        ts::return_to_sender(&ts, owner_cap);
    };

    ts::end(ts);
}

/// Tests that owner cap authorization works correctly after transfer
/// Scenario: Admin creates owner cap, transfers it, then verifies authorization
/// The owner then transfers the OwnerCap
/// Expected: Authorization should fail for the old owner
#[test]
#[expected_failure]
fun owner_cap_authorisation_fail_after_transfer() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let target_object_id = test_helpers::create_test_object(&mut ts, user_a());

    // User verifies authorization
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<TestObject>>(&ts);
        // Should be authorized for the correct object
        assert_eq!(access::is_authorized<TestObject>(&owner_cap, target_object_id), true);

        ts::return_to_sender(&ts, owner_cap);
    };

    // User A transfers OwnerCap to User B,
    // Now authorisation should fail
    // User verifies authorization
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<TestObject>>(&ts);
        access::transfer_owner_cap<TestObject>(owner_cap, user_b());
    };

    ts::next_tx(&mut ts, user_a());
    {
        // fail here
        let owner_cap = ts::take_from_sender<OwnerCap<TestObject>>(&ts);
        ts::return_to_sender(&ts, owner_cap);
    };

    abort
}

#[test]
#[expected_failure(abort_code = access::ECharacterTransfer)]
fun character_owner_cap_transfer_fail() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    // Create a character which also creates a OwnerCap to mutate the Character object
    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_acl,
            1005,
            b"TEST".to_string(),
            100,
            user_a(),
            b"name".to_string(),
            ts.ctx(),
        );
        character.share_character(&admin_acl, ts.ctx());
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
    };

    // Character OwnerCap is wallet-owned (user_a); transferring it to an address must fail
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_address<OwnerCap<Character>>(&ts, user_a());
        access::transfer_owner_cap_to_address<Character>(owner_cap, user_b(), ts.ctx());
    };
    abort
}

/// Mismatched receipt (wrong owner_cap_id) for transfer_owner_cap_with_receipt aborts with EOwnerCapIdMismatch.
#[test]
#[expected_failure(abort_code = access::EOwnerCapIdMismatch)]
fun transfer_owner_cap_with_receipt_mismatched_cap_id_fails() {
    let mut ts = ts::begin(governor());
    let character_id = setup_character_with_assembly(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared<Character>(&ts);
        let character_addr = object::id_address(&character);
        let ticket = ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id);
        let (owner_cap, real_receipt) = character.borrow_owner_cap<Assembly>(ticket, ts.ctx());
        ts::return_shared(character);

        access::destroy_receipt_for_testing(real_receipt);
        let wrong_cap_id = object::id_from_address(@0x1);
        let fake_receipt = access::create_return_receipt(wrong_cap_id, character_addr);
        access::transfer_owner_cap_with_receipt<Assembly>(
            owner_cap,
            fake_receipt,
            user_b(),
            ts.ctx(),
        );
    };
    abort
}

/// Mismatched receipt (wrong owner_id) for return_owner_cap_to_object aborts with EOwnerIdMismatch.
#[test]
#[expected_failure(abort_code = access::EOwnerIdMismatch)]
fun return_owner_cap_to_object_mismatched_owner_id_fails() {
    let mut ts = ts::begin(governor());
    let character_id = setup_character_with_assembly(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared<Character>(&ts);
        let character_addr = object::id_address(&character);
        let ticket = ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id);
        let (owner_cap, real_receipt) = character.borrow_owner_cap<Assembly>(ticket, ts.ctx());
        ts::return_shared(character);

        access::destroy_receipt_for_testing(real_receipt);
        let fake_receipt = access::create_return_receipt(object::id(&owner_cap), @0x1);
        access::return_owner_cap_to_object(owner_cap, fake_receipt, character_addr);
    };
    abort
}

/// Mismatched receipt (wrong owner_cap_id) for return_owner_cap_to_object aborts with EOwnerCapIdMismatch.
#[test]
#[expected_failure(abort_code = access::EOwnerCapIdMismatch)]
fun return_owner_cap_to_object_mismatched_cap_id_fails() {
    let mut ts = ts::begin(governor());
    let character_id = setup_character_with_assembly(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared<Character>(&ts);
        let character_addr = object::id_address(&character);
        let ticket = ts::most_recent_receiving_ticket<OwnerCap<Assembly>>(&character_id);
        let (owner_cap, real_receipt) = character.borrow_owner_cap<Assembly>(ticket, ts.ctx());
        ts::return_shared(character);

        access::destroy_receipt_for_testing(real_receipt);
        let fake_receipt = access::create_return_receipt(
            object::id_from_address(@0x1),
            character_addr,
        );
        access::return_owner_cap_to_object(owner_cap, fake_receipt, character_addr);
    };
    abort
}
