#[test_only]
module world::authority_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    authority::{Self, AdminCap, OwnerCap},
    test_helpers::{Self, TestObject, governor, admin, user_a, user_b},
    world::{Self, GovernorCap}
};

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
        authority::create_admin_cap(&gov_cap, admin, ts::ctx(&mut ts));

        ts::return_to_sender(&ts, gov_cap);
    };

    ts::next_tx(&mut ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(&ts);
        let admin_cap = ts::take_from_address<AdminCap>(&ts, admin);

        authority::delete_admin_cap(admin_cap, &gov_cap);

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
        authority::delete_owner_cap(owner_cap, &admin_cap);

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
        assert_eq!(authority::is_authorized<TestObject>(&owner_cap, target_object_id), true);
        // Should NOT be authorized for a different object
        assert_eq!(authority::is_authorized<TestObject>(&owner_cap, wrong_object_id), false);

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
        assert_eq!(authority::is_authorized<TestObject>(&owner_cap, target_object_id), true);

        ts::return_to_sender(&ts, owner_cap);
    };

    // User A transfers OwnerCap to User B,
    // Now authorisation should fail
    // User verifies authorization
    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap<TestObject>>(&ts);
        authority::transfer_owner_cap<TestObject>(owner_cap, user_b(), ts.ctx());
    };

    ts::next_tx(&mut ts, user_a());
    {
        // fail here
        let owner_cap = ts::take_from_sender<OwnerCap<TestObject>>(&ts);
        ts::return_to_sender(&ts, owner_cap);
    };

    abort
}
