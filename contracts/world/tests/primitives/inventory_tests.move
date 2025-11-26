#[test_only]
module world::inventory_tests;

use std::{bcs, unit_test::assert_eq};
use sui::test_scenario as ts;
use world::{
    authority::{OwnerCap, AdminCap, ServerAddressRegistry},
    inventory::{Self, Inventory},
    location::{Self, Location},
    status::{Self, AssemblyStatus},
    test_helpers::{Self, governor, admin, user_a, user_b, server_admin}
};

const LOCATION_A_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
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

/// Tests creating an assembly with inventory
/// Scenario: Admin creates a storage unit with inventory, status, and location
/// Expected: Storage unit is created successfully with correct initial state
#[test]
fun create_assembly_with_inventory() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        assert_eq!(storage_unit.status.status_to_u8(), 0);
        assert_eq!(storage_unit.location.hash(), LOCATION_A_HASH);
        assert_eq!(storage_unit.inventory.max_capacity(), MAX_CAPACITY);
        assert_eq!(storage_unit.inventory.used_capacity(), 0);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests minting items into inventory
/// Scenario: Admin mints ammo items into an online storage unit
/// Expected: Items are minted successfully, capacity is used correctly, and item quantity is correct
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
        assert_eq!(storage_unit.inventory.item_quantity(AMMO_ITEM_ID), 10);
        assert_eq!(storage_unit.inventory.inventory_item_length(), 1);
        assert_eq!(storage_unit.location.hash(), LOCATION_A_HASH);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests that minting items increases quantity when item already exists
/// Scenario: Admin mints 5 items, then mints 5 more of the same item
/// Expected: Second mint increases quantity to 10 instead of creating a new item
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
        assert_eq!(inv_ref.item_quantity(AMMO_ITEM_ID), 5);
        assert_eq!(inv_ref.inventory_item_length(), 1);
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
        assert_eq!(inv_ref.item_quantity(AMMO_ITEM_ID), 10);
        assert_eq!(inv_ref.inventory_item_length(), 1);
        assert_eq!(inv_ref.item_location(AMMO_ITEM_ID), LOCATION_A_HASH);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

// todo: check location is not being removed
/// Tests burning all items from inventory
/// Scenario: Owner burns all ammo items from an online storage unit
/// Expected: All items are burned, capacity is freed, and inventory is empty
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
            .burn_items_test(
                status_ref,
                &owner_cap,
                AMMO_ITEM_ID,
                AMMO_QUANTITY,
            );

        let inv_ref = &storage_unit.inventory;
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.inventory_item_length(), 0);

        let location_ref = &storage_unit.location;
        assert_eq!(location_ref.hash(), LOCATION_A_HASH);

        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Tests burning partial quantity of items
/// Scenario: Owner burns 5 out of 10 ammo items from inventory
/// Expected: Quantity is reduced to 5, capacity is partially freed, item still exists
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
            .burn_items_test(
                status_ref,
                &owner_cap,
                AMMO_ITEM_ID,
                5u32, //diff quantity
            );

        let inv_ref = &storage_unit.inventory;
        let used_capacity = 5 * AMMO_VOLUME;
        assert_eq!(inv_ref.used_capacity(), used_capacity);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(inv_ref.inventory_item_length(), 1);

        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Should it change the location ?
/// Tests depositing items from one inventory to another
/// Scenario: Withdraw item from storage unit and deposit into ephemeral storage unit
/// Expected: Item is successfully transferred, capacity updated in both inventories
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
        assert_eq!(inv_ref.inventory_item_length(), 0);

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
        assert_eq!(inv_ref.inventory_item_length(), 0);

        let mut ephemeral_storage_unit = ts::take_shared_by_id<StorageUnit>(
            &ts,
            ephemeral_storage_unit_id,
        );
        ephemeral_storage_unit.inventory.deposit_item(item);

        let eph_inv_ref = &ephemeral_storage_unit.inventory;
        let used_capacity = (AMMO_QUANTITY as u64) * AMMO_VOLUME;
        assert_eq!(eph_inv_ref.used_capacity(), used_capacity);
        assert_eq!(eph_inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(eph_inv_ref.inventory_item_length(), 1);

        ts::return_shared(storage_unit);
        ts::return_shared(ephemeral_storage_unit);
    };
    ts::end(ts);
}

/// Tests that creating inventory with zero capacity fails
/// Scenario: Attempt to create inventory with max_capacity = 0
/// Expected: Transaction aborts with EInventoryInvalidCapacity error
#[test]
fun burn_items_with_proof() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    let verified_location_hash = test_helpers::get_verified_location_hash();

    // create storage unit
    ts::next_tx(&mut ts, server_admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let uid = object::new(ts.ctx());
        let assembly_id = test_helpers::get_storage_unit_id();
        let storage_unit = StorageUnit {
            id: uid,
            status: status::anchor(&admin_cap, assembly_id),
            location: location::attach_location(&admin_cap, assembly_id, verified_location_hash),
            inventory: inventory::create(&admin_cap, MAX_CAPACITY, assembly_id),
        };
        transfer::share_object(storage_unit);
        ts::return_to_sender(&ts, admin_cap);
    };

    test_helpers::setup_owner_cap(&mut ts, user_a(), test_helpers::get_storage_unit_id());

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        storage_unit.status.online(&owner_cap);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
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
                x"16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049",
                ts.ctx(),
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let status_ref = &storage_unit.status;
        let location_ref = &storage_unit.location;
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let proof = test_helpers::construct_location_proof(verified_location_hash);
        let location_proof = bcs::to_bytes(&proof);

        storage_unit
            .inventory
            .burn_items_with_proof_test(
                status_ref,
                location_ref,
                &owner_cap,
                AMMO_ITEM_ID,
                AMMO_QUANTITY,
                &server_registry,
                location_proof,
                ts.ctx(),
            );

        let inv_ref = &storage_unit.inventory;
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.inventory_item_length(), 0);

        let location_ref = &storage_unit.location;
        assert_eq!(location_ref.hash(), test_helpers::get_verified_location_hash());

        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
        ts::return_shared(server_registry);
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

/// Tests that minting items with empty item_id fails
/// Scenario: Attempt to mint items with item_id = 0
/// Expected: Transaction aborts with EItemIdEmpty error
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

/// Tests that minting items with empty type_id fails
/// Scenario: Attempt to mint items with type_id = 0
/// Expected: Transaction aborts with ETypeIdEmpty error
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

/// Tests that minting items into offline inventory fails
/// Scenario: Attempt to mint items into storage unit that is not online
/// Expected: Transaction aborts with ENotOnline error
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

/// Tests that minting items exceeding inventory capacity fails
/// Scenario: Attempt to mint 15 items when inventory capacity is 1000 and each item uses 100 volume
/// Expected: Transaction aborts with EInventoryInsufficientCapacity error
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

/// Tests that burning items without proper owner capability fails
/// Scenario: User B attempts to burn items from User A's storage unit using wrong OwnerCap
/// Expected: Transaction aborts with EInventoryAccessNotAuthorized error
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
            .burn_items_test(
                status_ref,
                &owner_cap,
                AMMO_ITEM_ID,
                AMMO_QUANTITY,
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Tests that burning items that don't exist fails
/// Scenario: Attempt to burn items from empty inventory
/// Expected: Transaction aborts with EItemDoesNotExist error
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
            .burn_items_test(
                status_ref,
                &owner_cap,
                AMMO_ITEM_ID,
                AMMO_QUANTITY,
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Tests that burning more items than available fails
/// Scenario: Attempt to burn 15 items when only 10 exist in inventory
/// Expected: Transaction aborts with EInventoryInsufficientQuantity error
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
            .burn_items_test(
                status_ref,
                &owner_cap,
                AMMO_ITEM_ID,
                15u32,
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Tests that depositing items into inventory with insufficient capacity fails
/// Scenario: Attempt to deposit item requiring 1000 volume into inventory with only 10 capacity
/// Expected: Transaction aborts with EInventoryInsufficientCapacity error
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

/// Tests that withdrawing items that don't exist fails
/// Scenario: Attempt to withdraw item with non-existent item_id
/// Expected: Transaction aborts with EItemDoesNotExist error
#[test]
#[expected_failure(abort_code = inventory::EItemDoesNotExist)]
fun withdraw_item_fail_item_not_found() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id);
        // This should abort with EItemDoesNotExist
        let item = storage_unit.inventory.withdraw_item(1222);
        // Unreachable code below - needed to satisfy Move's type checker
        storage_unit.inventory.deposit_item(item);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests that minting items with mismatched assembly status fails
/// Scenario: Attempt to mint items using status from a different assembly than the inventory
/// Expected: Transaction aborts with EInventoryAssemblyMismatch error
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
