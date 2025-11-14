#[test_only]
module world::inventory_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    authority::{OwnerCap, AdminCap},
    inventory::{Self, Inventory},
    location::{Self, Location},
    status::{Self, AssemblyStatus},
    test_helpers::{Self, governor, admin, user_a, user_b}
};

const LOCATION_A_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const PROOF: vector<u8> = x"5a2f1b0e7c4d1a6f5e8b2d9c3f7a1e5b";
const MAX_CAPACITY: u64 = 1000;
const AMMO_TYPE_ID: u64 = 88069;
const AMMO_ITEM_ID: u64 = 1000004145107;
const AMMO_VOLUME: u64 = 100;
const AMMO_QUANTITY: u32 = 10;

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
        let used_capacity = (AMMO_QUANTITY as u64) * AMMO_VOLUME;

        assert_eq!(storage_unit.inventory.used_capacity(), used_capacity);
        assert_eq!(storage_unit.inventory.remaining_capacity(), 0);
        assert_eq!(storage_unit.inventory.get_item_quantity(AMMO_ITEM_ID), 10);
        assert_eq!(storage_unit.inventory.get_inventory_item_length(), 1);
        assert_eq!(storage_unit.location.get_hash(), LOCATION_A_HASH);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

#[test]
fun mint_items_increases_quantity_when_exists() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let status_ref = &storage_unit.status;
        storage_unit
            .inventory
            .mint_items(
                status_ref,
                &admin_cap,
                AMMO_ITEM_ID,
                AMMO_TYPE_ID,
                AMMO_VOLUME,
                5u32,
                LOCATION_A_HASH,
                ts.ctx(),
            );

        let inv_ref = &storage_unit.inventory;
        let used_capacity = 5 * AMMO_VOLUME;

        assert_eq!(inv_ref.used_capacity(), used_capacity);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(inv_ref.get_item_quantity(AMMO_ITEM_ID), 5);
        assert_eq!(inv_ref.get_inventory_item_length(), 1);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let status_ref = &storage_unit.status;
        storage_unit
            .inventory
            .mint_items(
                status_ref,
                &admin_cap,
                AMMO_ITEM_ID,
                AMMO_TYPE_ID,
                AMMO_VOLUME,
                5u32,
                LOCATION_A_HASH,
                ts.ctx(),
            );

        let inv_ref = &storage_unit.inventory;
        assert_eq!(inv_ref.used_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.remaining_capacity(), 0);
        assert_eq!(inv_ref.get_item_quantity(AMMO_ITEM_ID), 10);
        assert_eq!(inv_ref.get_inventory_item_length(), 1);
        assert_eq!(inv_ref.get_item_location(AMMO_ITEM_ID), LOCATION_A_HASH);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, admin_cap);
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
        assert_eq!(location_ref.get_hash(), LOCATION_A_HASH);

        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

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
                5u32, //diff quantity
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

// Should it change the location ?
#[test]
public fun deposit_items() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    // Create a storage unit
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    // Mint some ammo into a storage unit
    mint_ammo(&mut ts);

    // Create a ephemeral storage unit or a ship storage unit
    let ephemeral_storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap(&mut ts, user_b(), ephemeral_storage_unit_id);

    ts::next_tx(&mut ts, user_b());
    {
        let mut ephemeral_storage_unit = ts::take_shared_by_id<StorageUnit>(
            &ts,
            ephemeral_storage_unit_id,
        );
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        ephemeral_storage_unit.status.online(&owner_cap);

        //Make sure its empty
        let inv_ref = &ephemeral_storage_unit.inventory;
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.get_inventory_item_length(), 0);

        ts::return_shared(ephemeral_storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    // This is only possible in the tests as its package scoped.
    // Ideally the builders can only invoke these functions using registered extensions via assembly
    ts::next_tx(&mut ts, user_a());
    {
        // It needs to be withdrawn first to deposit
        // Withdraw from storage unit and deposit in ephemeral storage
        // Do the same in reverse for implementing swap functions and item transfer between inventories on-chain
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id);
        let item = storage_unit.inventory.withdraw_item(AMMO_ITEM_ID);

        let inv_ref = &storage_unit.inventory;
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.get_inventory_item_length(), 0);

        let mut ephemeral_storage_unit = ts::take_shared_by_id<StorageUnit>(
            &ts,
            ephemeral_storage_unit_id,
        );
        ephemeral_storage_unit.inventory.deposit_item(item);

        let eph_inv_ref = &ephemeral_storage_unit.inventory;
        let used_capacity = (AMMO_QUANTITY as u64) * AMMO_VOLUME;
        assert_eq!(eph_inv_ref.used_capacity(), used_capacity);
        assert_eq!(eph_inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(eph_inv_ref.get_inventory_item_length(), 1);

        ts::return_shared(storage_unit);
        ts::return_shared(ephemeral_storage_unit);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::EInventoryInvalidCapacity)]
fun create_assembly_fail_on_empty_capacity() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let storage_unit = StorageUnit {
            id: uid,
            status: status::anchor(&admin_cap, assembly_id),
            location: location::attach_location(&admin_cap, assembly_id, LOCATION_A_HASH),
            inventory: inventory::create(&admin_cap, 0, assembly_id),
        };
        transfer::share_object(storage_unit);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::EItemIdEmpty)]
fun mint_items_fail_empty_item_id() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);
    online(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let status_ref = &storage_unit.status;
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        storage_unit
            .inventory
            .mint_items(
                status_ref,
                &admin_cap,
                0,
                AMMO_TYPE_ID,
                AMMO_VOLUME,
                AMMO_QUANTITY,
                LOCATION_A_HASH,
                ts.ctx(),
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::ETypeIdEmpty)]
fun mint_items_fail_empty_type_id() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);
    online(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let status_ref = &storage_unit.status;
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        storage_unit
            .inventory
            .mint_items(
                status_ref,
                &admin_cap,
                AMMO_ITEM_ID,
                0,
                AMMO_VOLUME,
                AMMO_QUANTITY,
                LOCATION_A_HASH,
                ts.ctx(),
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::ENotOnline)]
fun mint_items_fail_inventory_offline() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let status_ref = &storage_unit.status;
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
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
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::EInventoryInsufficientCapacity)]
fun mint_fail_inventory_insufficient_capacity() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);
    online(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let status_ref = &storage_unit.status;
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        storage_unit
            .inventory
            .mint_items(
                status_ref,
                &admin_cap,
                AMMO_ITEM_ID,
                AMMO_TYPE_ID,
                AMMO_VOLUME,
                15u32,
                LOCATION_A_HASH,
                ts.ctx(),
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::EInventoryAccessNotAuthorized)]
public fun burn_items_fail_unauthorized_owner() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);
    let dummy_id = object::id_from_bytes(
        x"0000000000000000000000000000000000000000000000000000000000000001",
    );
    test_helpers::setup_owner_cap(&mut ts, user_b(), dummy_id);

    online(&mut ts);
    mint_ammo(&mut ts);

    ts::next_tx(&mut ts, user_b());
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
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::EItemDoesNotExist)]
public fun burn_items_fail_item_not_found() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);
    online(&mut ts);

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
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::EInventoryInsufficientQuantity)]
public fun burn_items_fail_insufficient_quantity() {
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
                15u32,
                LOCATION_A_HASH,
                PROOF,
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::EInventoryInsufficientCapacity)]
fun deposit_item_fail_insufficient_capacity() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    mint_ammo(&mut ts);

    let ephemeral_storage_unit_id;

    // Create a ephemeral storage unit or a ship storage unit
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let uid = object::new(ts.ctx());
        ephemeral_storage_unit_id = object::uid_to_inner(&uid);
        let ephemeral_storage_unit = StorageUnit {
            id: uid,
            status: status::anchor(&admin_cap, ephemeral_storage_unit_id),
            location: location::attach_location(
                &admin_cap,
                ephemeral_storage_unit_id,
                LOCATION_A_HASH,
            ),
            inventory: inventory::create(&admin_cap, 10, ephemeral_storage_unit_id),
        };
        transfer::share_object(ephemeral_storage_unit);
        ts::return_to_sender(&ts, admin_cap);
    };
    test_helpers::setup_owner_cap(&mut ts, user_b(), ephemeral_storage_unit_id);
    ts::next_tx(&mut ts, user_b());
    {
        let mut ephemeral_storage_unit = ts::take_shared_by_id<StorageUnit>(
            &ts,
            ephemeral_storage_unit_id,
        );
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        ephemeral_storage_unit.status.online(&owner_cap);
        ts::return_shared(ephemeral_storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id);
        let item = storage_unit.inventory.withdraw_item(AMMO_ITEM_ID);
        let mut ephemeral_storage_unit = ts::take_shared_by_id<StorageUnit>(
            &ts,
            ephemeral_storage_unit_id,
        );
        ephemeral_storage_unit.inventory.deposit_item(item);
        ts::return_shared(storage_unit);
        ts::return_shared(ephemeral_storage_unit);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::EItemDoesNotExist)]
fun withdraw_item_fail_item_not_found() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    mint_ammo(&mut ts);
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id);
        let item = storage_unit.inventory.withdraw_item(1222);

        storage_unit.inventory.deposit_item(item);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = inventory::EInventoryAssemblyMismatch)]
fun mint_items_fail_inventory_assembly_mismatch() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let storage_unit_id_1 = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id_1);

    let storage_unit_id_2 = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap(&mut ts, user_b(), storage_unit_id_2);

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id_1);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        storage_unit.status.online(&owner_cap);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id_2);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        storage_unit.status.online(&owner_cap);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit_1 = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id_1);
        let storage_unit_2 = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id_2);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);

        // This should fail with EInventoryAssemblyMismatch
        storage_unit_1
            .inventory
            .mint_items(
                &storage_unit_2.status, // status from different assembly
                &admin_cap,
                AMMO_ITEM_ID,
                AMMO_TYPE_ID,
                AMMO_VOLUME,
                AMMO_QUANTITY,
                LOCATION_A_HASH,
                ts.ctx(),
            );

        ts::return_shared(storage_unit_1);
        ts::return_shared(storage_unit_2);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}
