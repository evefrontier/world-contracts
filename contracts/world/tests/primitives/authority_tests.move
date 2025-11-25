#[test_only]
module world::authority_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    authority::{Self, AdminCap, OwnerCap},
    test_helpers::{governor, admin},
    world::{Self, GovernorCap}
};

/// Tests creating and deleting an admin cap
/// Scenario: Governor creates an admin cap for an admin, then deletes it
/// Expected: Admin cap is created successfully and can be deleted by governor
#[test]
fun create_and_delete_admin_cap() {
    let _admin = @0xB;

    let mut ts = ts::begin(governor());
    {
        world::init_for_testing(ts::ctx(&mut ts));
    };

    ts::next_tx(&mut ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(&ts);
        authority::create_admin_cap(&gov_cap, _admin, ts::ctx(&mut ts));

        ts::return_to_sender(&ts, gov_cap);
    };

    ts::next_tx(&mut ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(&ts);
        let admin_cap = ts::take_from_address<AdminCap>(&ts, _admin);

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
    let _userA = @0xC;

    let mut ts = ts::begin(governor());
    {
        world::init_for_testing(ts::ctx(&mut ts));
    };

    ts::next_tx(&mut ts, governor());
    {
        let gov_cap = ts::take_from_sender<world::GovernorCap>(&ts);
        authority::create_admin_cap(&gov_cap, admin(), ts::ctx(&mut ts));

        ts::return_to_sender(&ts, gov_cap);
    };

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<authority::AdminCap>(&ts);

        let dummy_character_object_id = object::id_from_address(@0x1234);
        let owner_cap = authority::create_owner_cap(
            &admin_cap,
            dummy_character_object_id,
            ts::ctx(&mut ts),
        );
        authority::transfer_owner_cap(owner_cap, &admin_cap, _userA);

        ts::return_to_sender(&ts, admin_cap);
    };

    ts::next_tx(&mut ts, admin());
    {
        let owner_cap = ts::take_from_address<authority::OwnerCap>(&ts, _userA);
        let admin_cap = ts::take_from_sender<authority::AdminCap>(&ts);

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
fun test_owner_cap_authorization_after_transfer() {
    let _user = @0xC;

    let mut ts = ts::begin(governor());
    {
        world::init_for_testing(ts::ctx(&mut ts));
    };

    ts::next_tx(&mut ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(&ts);
        authority::create_admin_cap(&gov_cap, admin(), ts::ctx(&mut ts));
        ts::return_to_sender(&ts, gov_cap);
    };

    let target_object_id = object::id_from_address(@0x1234);
    let wrong_object_id = object::id_from_address(@0x5678);

    // Admin creates owner cap
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let owner_cap = authority::create_owner_cap(&admin_cap, target_object_id, ts::ctx(&mut ts));
        authority::transfer_owner_cap(owner_cap, &admin_cap, _user);
        ts::return_to_sender(&ts, admin_cap);
    };

    // User verifies authorization
    ts::next_tx(&mut ts, _user);
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);

        // Should be authorized for the correct object
        assert_eq!(authority::is_authorized(&owner_cap, target_object_id), true);

        // Should NOT be authorized for a different object
        assert_eq!(authority::is_authorized(&owner_cap, wrong_object_id), false);

        ts::return_to_sender(&ts, owner_cap);
    };

    ts::end(ts);
}
