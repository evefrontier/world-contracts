#[test_only]
module world::inventory_tests;

use std::unit_test::assert_eq;
use sui::{event, test_scenario as ts, vec_map::{Self, VecMap}};
use world::{
    authority::{Self, OwnerCap, AdminCap},
    inventory::{Self, Inventory},
    location::{Self, Location},
    status::{Self, AssemblyStatus},
    test_helpers::{Self, governor, admin, user_a, user_b}
};

const LOCATION_A_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const LOCATION_B_HASH: vector<u8> =
    x"5a7f1b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const PROOF: vector<u8> = x"5a2f1b0e7c4d1a6f5e8b2d9c3f7a1e5b";
const MAX_CAPACITY: u64 = 1000;
const AMMO_TYPE_ID: u64 = 88069;
const AMMO_ITEM_ID: u64 = 1000004145107;
const AMMO_VOLUME: u64 = 100;
const AMMO_QUANTITY: u64 = 10;

public struct StorageUnit has key {
    id: UID,
    status: AssemblyStatus,
    location: Location,
    inventory: Inventory,
}

// Helper Functions
fun create_storage_unit(ts: &mut ts::Scenario): ID {
    ts::next_tx(ts, admin());
    let assembly_id = {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let storage_unit = StorageUnit {
            id: uid,
            status: status::anchor(&admin_cap, assembly_id),
            location: location::attach_location(&admin_cap, assembly_id, LOCATION_A_HASH),
            inventory: inventory::create(&admin_cap, MAX_CAPACITY, assembly_id),
        };
        transfer::share_object(storage_unit);
        ts::return_to_sender(ts, admin_cap);
        assembly_id
    };
    assembly_id
}

fun online(ts: &mut ts::Scenario) {
    ts::next_tx(ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(ts);
        let owner_cap = ts::take_from_sender<OwnerCap>(ts);
        storage_unit.status.online(&owner_cap);
        assert_eq!(storage_unit.status.status_to_u8(), 1);

        ts::return_shared(storage_unit);
        ts::return_to_sender(ts, owner_cap);
    }
}

fun mint_ammo(ts: &mut ts::Scenario) {
    ts::next_tx(ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(ts);
        let status_ref = &storage_unit.status;
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        storage_unit
            .inventory
            .mint_items(
                status_ref,
                &admin_cap,
                AMMO_ITEM_ID,
                AMMO_TYPE_ID,
                AMMO_VOLUME,
                AMMO_QUANTITY,
                LOCATION_A_HASH,
                ts.ctx(),
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(ts, admin_cap);
    };
}

#[test]
fun create_assembly_with_inventory() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        assert_eq!(storage_unit.status.status_to_u8(), 0);
        assert_eq!(storage_unit.location.get_hash(), LOCATION_A_HASH);
        assert_eq!(storage_unit.inventory.max_capacity(), MAX_CAPACITY);
        assert_eq!(storage_unit.inventory.used_capacity(), 0);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

#[test]
fun mint_items() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    mint_ammo(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        let used_capacity = AMMO_QUANTITY * AMMO_VOLUME;

        assert_eq!(storage_unit.inventory.used_capacity(), used_capacity);
        assert_eq!(storage_unit.inventory.remaining_capacity(), 0);
        assert_eq!(storage_unit.inventory.get_item_quantity(AMMO_ITEM_ID), 10);
        assert_eq!(storage_unit.inventory.get_inventory_item_length(), 1);
        assert_eq!(storage_unit.location.get_hash(), LOCATION_A_HASH);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

// todo: check location is not being removed
#[test]
public fun burn_items() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    mint_ammo(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let status_ref = &storage_unit.status;
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        storage_unit
            .inventory
            .burn_items(
                status_ref,
                &owner_cap,
                AMMO_ITEM_ID,
                AMMO_QUANTITY,
                LOCATION_A_HASH,
                PROOF,
            );

        let inv_ref = &storage_unit.inventory;
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.get_inventory_item_length(), 0);

        let location_ref = &storage_unit.location;
        assert_eq!(location_ref.get_hash(), LOCATION_A_HASH); // This should not be possible
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

// burn partial amount, only reduces quantity and capacity
#[test]
public fun burn_partial_items() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    mint_ammo(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let status_ref = &storage_unit.status;
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        storage_unit
            .inventory
            .burn_items(
                status_ref,
                &owner_cap,
                AMMO_ITEM_ID,
                5, //diff quantity
                LOCATION_A_HASH,
                PROOF,
            );

        let inv_ref = &storage_unit.inventory;
        let used_capacity = 5 * AMMO_VOLUME;
        assert_eq!(inv_ref.used_capacity(), used_capacity);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(inv_ref.get_inventory_item_length(), 1);

        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

// withdraw returns the entire item, increases capacity
// and then deposit reduces the capcity
// it should change location

// negtive : ETypeIdEmpty, EItemIdEmpty, EInventoryInvalidCapacity, EInventoryInSufficientCapacity
// EInventoryAccessNotAuthorized, ENotOnline,  EItemDoesNotExist, EInsufficientQuantity
