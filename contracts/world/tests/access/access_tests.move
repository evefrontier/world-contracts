#[test_only]
module world::access_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    access::{Self, AdminCap, OwnerCap},
    character::{Self, Character},
    object_registry::ObjectRegistry,
    test_helpers::{Self, TestObject, governor, admin, user_a, user_b},
    world::{Self, GovernorCap}
};

fun setup_character_for_receipt_tests(ts: &mut ts::Scenario) {
    ts::next_tx(ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            2000,
            b"TEST".to_string(),
            100,
            user_a(),
            b"name".to_string(),
            ts.ctx(),
        );
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(ts, admin_cap);
    };
}

/// Tests creating and deleting an admin cap
/// Scenario: Governor creates an admin cap for an admin, then deletes it
/// Expected: Admin cap is created successfully and can be deleted by governor
#[test]
fun create_and_delete_admin_cap() {
    let admin = @0xB;

    let mut ts = ts::begin(governor());
    {
        world::init_for_testing(ts::ctx(&mut ts));
    };

    ts::next_tx(&mut ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(&ts);
        access::create_admin_cap(&gov_cap, admin, ts::ctx(&mut ts));

        ts::return_to_sender(&ts, gov_cap);
    };

    ts::next_tx(&mut ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(&ts);
        let admin_cap = ts::take_from_address<AdminCap>(&ts, admin);

        access::delete_admin_cap(admin_cap, &gov_cap);

        ts::return_to_sender(&ts, gov_cap);
    };

    ts::end(ts);
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
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);

        // Only possible in tests
        access::delete_owner_cap(owner_cap, &admin_cap);

        ts::return_to_sender(&ts, admin_cap);
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
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            1005,
            b"TEST".to_string(),
            100,
            user_a(),
            b"name".to_string(),
            ts.ctx(),
        );
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Transfer Character OwnerCap should fail
    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared<Character>(&ts);
        let character_id = object::id(&character);
        let access_cap_ticket = ts::most_recent_receiving_ticket<OwnerCap<Character>>(
            &character_id,
        );
        let (owner_cap, receipt) = character.borrow_owner_cap<Character>(
            access_cap_ticket,
            ts.ctx(),
        );
        access::transfer_owner_cap_with_receipt<Character>(
            owner_cap,
            receipt,
            user_b(),
            ts.ctx(),
        );
    };
    abort
}

/// Mismatched receipt (wrong owner_cap_id) for transfer_owner_cap_with_receipt aborts with EOwnerCapIdMismatch.
#[test]
#[expected_failure(abort_code = access::EOwnerCapIdMismatch)]
fun transfer_owner_cap_with_receipt_mismatched_cap_id_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    setup_character_for_receipt_tests(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared<Character>(&ts);
        let character_addr = object::id_address(&character);
        let ticket = ts::most_recent_receiving_ticket<OwnerCap<Character>>(&object::id(&character));
        let (owner_cap, real_receipt) = character.borrow_owner_cap<Character>(ticket, ts.ctx());
        ts::return_shared(character);

        access::destroy_receipt_for_testing(real_receipt);
        let wrong_cap_id = object::id_from_address(@0x1);
        let fake_receipt = access::create_return_receipt(wrong_cap_id, character_addr);
        access::transfer_owner_cap_with_receipt<Character>(
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
    test_helpers::setup_world(&mut ts);
    setup_character_for_receipt_tests(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared<Character>(&ts);
        let character_addr = object::id_address(&character);
        let ticket = ts::most_recent_receiving_ticket<OwnerCap<Character>>(&object::id(&character));
        let (owner_cap, real_receipt) = character.borrow_owner_cap<Character>(ticket, ts.ctx());
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
    test_helpers::setup_world(&mut ts);
    setup_character_for_receipt_tests(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut character = ts::take_shared<Character>(&ts);
        let character_addr = object::id_address(&character);
        let ticket = ts::most_recent_receiving_ticket<OwnerCap<Character>>(&object::id(&character));
        let (owner_cap, real_receipt) = character.borrow_owner_cap<Character>(ticket, ts.ctx());
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
