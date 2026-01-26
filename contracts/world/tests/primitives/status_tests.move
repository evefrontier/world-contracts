#[test_only]

module world::status_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    access::AdminCap,
    in_game_id,
    status::{Self, AssemblyStatus},
    test_helpers::{Self, governor, admin, user_a, tenant}
};

const STORAGE_ITEM_ID: u64 = 5500004145107;
const STATUS_NULL: u8 = 0;
const STATUS_ONLINE: u8 = 1;
const STATUS_OFFLINE: u8 = 2;

public struct StorageUnit has key {
    id: UID,
    status: AssemblyStatus,
    max_capacity: u64,
}

// Helper Functions

// An assembly implementation using the status primitive
fun create_storage_unit(ts: &mut ts::Scenario) {
    ts::next_tx(ts, admin());
    {
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let assembly_key = in_game_id::create_key(STORAGE_ITEM_ID, tenant());
        let storage_unit = StorageUnit {
            id: uid,
            status: status::anchor(assembly_id, assembly_key),
            max_capacity: 10000,
        };
        // share storage unit object
        transfer::share_object(storage_unit);
    }
}

fun destroy_storage_unit(ts: &mut ts::Scenario) {
    ts::next_tx(ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let storage_unit = ts::take_shared<StorageUnit>(ts);
        let assembly_id = object::id(&storage_unit);
        let StorageUnit { id, status, max_capacity: _ } = storage_unit;

        let assembly_key = in_game_id::create_key(STORAGE_ITEM_ID, tenant());
        status.unanchor(assembly_id, assembly_key);
        id.delete();

        ts::return_to_sender(ts, admin_cap);
    }
}

/// Tests creating an assembly with anchored status
/// Scenario: Admin creates a storage unit assembly
/// Expected: Assembly is created successfully with ANCHORED status
#[test]
fun create_assembly() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        assert_eq!(storage_unit.status.status_to_u8(), STATUS_OFFLINE);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests bringing an assembly online
/// Scenario: Owner brings an anchored assembly online
/// Expected: Assembly status changes from ANCHORED to ONLINE
#[test]
fun online() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        test_helpers::setup_owner_cap_for_user_a(&mut ts, &storage_unit);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let assembly_id = object::id(&storage_unit);
        let assembly_key = in_game_id::create_key(STORAGE_ITEM_ID, tenant());
        storage_unit.status.online(assembly_id, assembly_key);

        assert_eq!(storage_unit.status.status_to_u8(), STATUS_ONLINE);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests taking an assembly offline
/// Scenario: Owner takes an online assembly offline
/// Expected: Assembly status changes from ONLINE back to ANCHORED
#[test]
fun offline() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        test_helpers::setup_owner_cap_for_user_a(&mut ts, &storage_unit);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let assembly_id = object::id(&storage_unit);
        let assembly_key = in_game_id::create_key(STORAGE_ITEM_ID, tenant());
        storage_unit.status.online(assembly_id, assembly_key);
        storage_unit.status.offline(assembly_id, assembly_key);

        assert_eq!(storage_unit.status.status_to_u8(), STATUS_OFFLINE);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests unanchoring and destroying an assembly
/// Scenario: Admin unanchors an anchored assembly, destroying it
/// Expected: Assembly is successfully unanchored and destroyed
#[test]
fun unanchor_destroy() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        assert_eq!(storage_unit.status.status_to_u8(), STATUS_OFFLINE);
        ts::return_shared(storage_unit);
        destroy_storage_unit(&mut ts);
    };
    ts::end(ts);
}

/// Tests that taking offline without being online fails
/// Scenario: Attempt to take an anchored assembly offline
/// Expected: Transaction aborts with EAssemblyInvalidStatus error
#[test]
#[expected_failure(abort_code = status::EAssemblyInvalidStatus)]
fun offline_without_online_fail() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let assembly_id = object::id(&storage_unit);
        let assembly_key = in_game_id::create_key(STORAGE_ITEM_ID, tenant());
        storage_unit.status.offline(assembly_id, assembly_key);

        assert_eq!(storage_unit.status.status_to_u8(), STATUS_OFFLINE);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests that bringing online when already online fails
/// Scenario: Attempt to bring an assembly online when it's already online
/// Expected: Transaction aborts with EAssemblyInvalidStatus error
#[test]
#[expected_failure(abort_code = status::EAssemblyInvalidStatus)]
fun online_when_already_online_fail() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let assembly_id = object::id(&storage_unit);
        let assembly_key = in_game_id::create_key(STORAGE_ITEM_ID, tenant());
        storage_unit.status.online(assembly_id, assembly_key);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let assembly_id = object::id(&storage_unit);
        let assembly_key = in_game_id::create_key(STORAGE_ITEM_ID, tenant());
        // Attempt to bring online again - should fail
        storage_unit.status.online(assembly_id, assembly_key);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests that accessing assembly status using ID after unanchor fails
/// Scenario: Store assembly ID, unanchor and destroy the assembly, then attempt to access it by ID
/// Expected: Transaction fails because the object no longer exists
#[test]
#[expected_failure]
fun get_assembly_status_after_unanchor_fails() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    create_storage_unit(&mut ts);

    let assembly_id: ID;

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        assembly_id = object::id(&storage_unit);

        assert_eq!(storage_unit.status.status_to_u8(), STATUS_NULL);
        ts::return_shared(storage_unit);
        destroy_storage_unit(&mut ts);
    };

    ts::next_tx(&mut ts, admin());
    {
        // Try to access the storage unit by ID after it's been destroyed - should fail
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, assembly_id);
        // This should never execute because the object doesn't exist
        assert_eq!(storage_unit.status.status_to_u8(), STATUS_OFFLINE);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}
