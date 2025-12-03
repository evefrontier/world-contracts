#[test_only]
module world::inventory_tests;

use std::{bcs, unit_test::assert_eq};
use sui::{dynamic_field as df, test_scenario as ts};
use world::{
    authority::ServerAddressRegistry,
    inventory::{Self, Inventory},
    location::{Self, Location},
    status::{Self, AssemblyStatus},
    test_helpers::{
        Self,
        governor,
        admin,
        user_a,
        user_b,
        server_admin,
        user_a_character_id,
        user_b_character_id
    }
};

const STORAGE_TYPE_ID: u64 = 77069;
const STORAGE_ITEM_ID: u64 = 5500004145107;
const LOCATION_A_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const MAX_CAPACITY: u64 = 1000;
const AMMO_TYPE_ID: u64 = 88069;
const AMMO_ITEM_ID: u64 = 1000004145107;
const AMMO_VOLUME: u64 = 100;
const AMMO_QUANTITY: u32 = 10;
const STATUS_ONLINE: u8 = 1;
const STATUS_OFFLINE: u8 = 2;

public struct StorageUnit has key {
    id: UID,
    status: AssemblyStatus,
    location: Location,
    inventory_keys: vector<ID>,
}

// Helper Functions
fun create_storage_unit(ts: &mut ts::Scenario): ID {
    ts::next_tx(ts, admin());
    let assembly_id = {
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let character_id = user_a_character_id();
        let mut storage_unit = StorageUnit {
            id: uid,
            status: status::anchor(assembly_id, STORAGE_TYPE_ID, STORAGE_ITEM_ID),
            location: location::attach(assembly_id, LOCATION_A_HASH),
            inventory_keys: vector[],
        };
        let inv = inventory::create(assembly_id, character_id, MAX_CAPACITY);
        storage_unit.inventory_keys.push_back(character_id);
        df::add(&mut storage_unit.id, character_id, inv);
        transfer::share_object(storage_unit);
        assembly_id
    };
    assembly_id
}

fun online(ts: &mut ts::Scenario) {
    ts::next_tx(ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(ts);
        storage_unit.status.online();
        assert_eq!(storage_unit.status.status_to_u8(), STATUS_ONLINE);

        ts::return_shared(storage_unit);
    }
}

fun mint_ammo(ts: &mut ts::Scenario) {
    ts::next_tx(ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(ts);
        let character_id = user_a_character_id();
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        inventory.mint_items(
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
            LOCATION_A_HASH,
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
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
        let character_id = user_a_character_id();
        let inventory = df::borrow<ID, Inventory>(&storage_unit.id, character_id);
        assert_eq!(storage_unit.status.status_to_u8(), STATUS_OFFLINE);
        assert_eq!(storage_unit.location.hash(), LOCATION_A_HASH);
        assert_eq!(inventory.max_capacity(), MAX_CAPACITY);
        assert_eq!(inventory.used_capacity(), 0);
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
        let character_id = user_a_character_id();
        let inventory = df::borrow<ID, Inventory>(&storage_unit.id, character_id);
        let used_capacity = (AMMO_QUANTITY as u64) * AMMO_VOLUME;

        assert_eq!(inventory.used_capacity(), used_capacity);
        assert_eq!(inventory.remaining_capacity(), 0);
        assert_eq!(inventory.item_quantity(AMMO_ITEM_ID), 10);
        assert_eq!(inventory.inventory_item_length(), 1);
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
    let character_id = user_a_character_id();
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        inventory.mint_items(
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            5u32,
            LOCATION_A_HASH,
            ts.ctx(),
        );

        let inv_ref = df::borrow<ID, Inventory>(&storage_unit.id, character_id);
        let used_capacity = 5 * AMMO_VOLUME;

        assert_eq!(inv_ref.used_capacity(), used_capacity);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(inv_ref.item_quantity(AMMO_ITEM_ID), 5);
        assert_eq!(inv_ref.inventory_item_length(), 1);
        ts::return_shared(storage_unit);
    };
    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        inventory.mint_items(
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            5u32,
            LOCATION_A_HASH,
            ts.ctx(),
        );

        let inv_ref = df::borrow<ID, Inventory>(&storage_unit.id, character_id);
        assert_eq!(inv_ref.used_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.remaining_capacity(), 0);
        assert_eq!(inv_ref.item_quantity(AMMO_ITEM_ID), 10);
        assert_eq!(inv_ref.inventory_item_length(), 1);
        assert_eq!(inv_ref.item_location(AMMO_ITEM_ID), LOCATION_A_HASH);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

// todo: check location is not being removed
/// Tests burning all items from inventory
/// Scenario: Owner burns all ammo items from an online storage unit
/// Expected: All items are burned, capacity is freed, and inventory is empty
#[test]
public fun burn_items() {
    let character_id = user_a_character_id();
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    mint_ammo(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        test_helpers::setup_owner_cap_for_user_a(&mut ts, inventory.id());
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        inventory.burn_items_test(
            AMMO_ITEM_ID,
            AMMO_QUANTITY,
        );

        let inv_ref = df::borrow<ID, Inventory>(&storage_unit.id, character_id);
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.inventory_item_length(), 0);

        let location_ref = &storage_unit.location;
        assert_eq!(location_ref.hash(), LOCATION_A_HASH);

        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests burning partial quantity of items
/// Scenario: Owner burns 5 out of 10 ammo items from inventory
/// Expected: Quantity is reduced to 5, capacity is partially freed, item still exists
#[test]
public fun burn_partial_items() {
    let character_id = user_a_character_id();
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    mint_ammo(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        inventory.burn_items_test(
            AMMO_ITEM_ID,
            5u32, //diff quantity
        );

        let inv_ref = df::borrow<ID, Inventory>(&storage_unit.id, character_id);
        let used_capacity = 5 * AMMO_VOLUME;
        assert_eq!(inv_ref.used_capacity(), used_capacity);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(inv_ref.inventory_item_length(), 1);

        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Should it change the location ?
/// Tests depositing items from one inventory to another
/// Scenario: Withdraw item from storage unit and deposit into ephemeral storage unit
/// Expected: Item is successfully transferred, capacity updated in both inventories
#[test]
public fun deposit_items() {
    let character_a_id = user_a_character_id();
    let character_b_id = user_b_character_id();

    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    // Creating a storage unit creates a inventory by default for the owner
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    mint_ammo(&mut ts);

    // Setup inventory owner cap for user_a
    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(
            &ts,
            storage_unit_id,
        );
        let inventory = df::borrow<ID, Inventory>(&storage_unit.id, character_a_id);
        test_helpers::setup_owner_cap(&mut ts, user_a(), inventory.id());
        ts::return_shared(storage_unit);
    };

    // Create a ephemeral inventory for user b
    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id);
        let inventory = inventory::create(
            storage_unit_id,
            character_a_id,
            MAX_CAPACITY,
        );
        df::add(&mut storage_unit.id, character_b_id, inventory);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, user_b());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(
            &ts,
            storage_unit_id,
        );

        let inv_ref = df::borrow<ID, Inventory>(&storage_unit.id, character_b_id);
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.inventory_item_length(), 0);
        ts::return_shared(storage_unit);
    };

    // This is only possible in the tests as its package scoped.
    // Ideally the builders can only invoke these functions using registered extensions via assembly
    ts::next_tx(&mut ts, user_a());
    {
        // It needs to be withdrawn first to deposit
        // Withdraw from storage unit and deposit in ephemeral storage
        // Do the same in reverse for implementing swap functions and item transfer between inventories on-chain
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_unit_id);
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_a_id);
        let item = inventory.withdraw_item(AMMO_ITEM_ID);

        let inv_ref = df::borrow<ID, Inventory>(&storage_unit.id, character_a_id);
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.inventory_item_length(), 0);

        let eph_inventory = df::borrow_mut<ID, Inventory>(
            &mut storage_unit.id,
            character_b_id,
        );
        eph_inventory.deposit_item(item);

        let eph_inv_ref = df::borrow<ID, Inventory>(&storage_unit.id, character_b_id);
        let used_capacity = (AMMO_QUANTITY as u64) * AMMO_VOLUME;
        assert_eq!(eph_inv_ref.used_capacity(), used_capacity);
        assert_eq!(eph_inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(eph_inv_ref.inventory_item_length(), 1);

        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

#[test]
fun burn_items_with_proof() {
    let character_id = user_a_character_id();
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    let verified_location_hash = test_helpers::get_verified_location_hash();

    // create storage unit
    ts::next_tx(&mut ts, server_admin());
    {
        let uid = object::new(ts.ctx());
        let assembly_id = test_helpers::get_storage_unit_id();
        let mut storage_unit = StorageUnit {
            id: uid,
            status: status::anchor(assembly_id, STORAGE_TYPE_ID, STORAGE_ITEM_ID),
            location: location::attach(assembly_id, verified_location_hash),
            inventory_keys: vector[],
        };
        let inv = inventory::create(assembly_id, character_id, MAX_CAPACITY);
        storage_unit.inventory_keys.push_back(character_id);
        df::add(&mut storage_unit.id, character_id, inv);
        transfer::share_object(storage_unit);
    };

    test_helpers::setup_owner_cap(&mut ts, user_a(), test_helpers::get_storage_unit_id());
    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        inventory.mint_items(
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
            x"16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049",
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let location_ref = &storage_unit.location;
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let proof = test_helpers::construct_location_proof(verified_location_hash);
        let location_proof = bcs::to_bytes(&proof);

        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        inventory.burn_items_with_proof_test(
            &server_registry,
            location_ref,
            location_proof,
            AMMO_ITEM_ID,
            AMMO_QUANTITY,
            ts.ctx(),
        );

        let inv_ref = df::borrow<ID, Inventory>(&storage_unit.id, character_id);
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.inventory_item_length(), 0);

        let location_ref = &storage_unit.location;
        assert_eq!(location_ref.hash(), test_helpers::get_verified_location_hash());

        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
    };
    ts::end(ts);
}

/// Tests that creating inventory with zero capacity fails
/// Scenario: Attempt to create inventory with max_capacity = 0
/// Expected: Transaction aborts with EInventoryInvalidCapacity error
#[test]
#[expected_failure(abort_code = inventory::EInventoryInvalidCapacity)]
fun create_assembly_fail_on_empty_capacity() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let character_id = user_a_character_id();
        let mut storage_unit = StorageUnit {
            id: uid,
            status: status::anchor(assembly_id, STORAGE_TYPE_ID, STORAGE_ITEM_ID),
            location: location::attach(assembly_id, LOCATION_A_HASH),
            inventory_keys: vector[],
        };
        // This should fail with EInventoryInvalidCapacity
        let inv = inventory::create(assembly_id, character_id, 0);
        storage_unit.inventory_keys.push_back(character_id);
        df::add(&mut storage_unit.id, character_id, inv);
        transfer::share_object(storage_unit);
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
        let character_id = user_a_character_id();
        let inventory = df::borrow_mut<ID, Inventory>(
            &mut storage_unit.id,
            character_id,
        );

        inventory.mint_items(
            0,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
            LOCATION_A_HASH,
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
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
        let character_id = user_a_character_id();
        let inventory = df::borrow_mut<ID, Inventory>(
            &mut storage_unit.id,
            character_id,
        );

        inventory.mint_items(
            AMMO_ITEM_ID,
            0,
            AMMO_VOLUME,
            AMMO_QUANTITY,
            LOCATION_A_HASH,
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
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
        let character_id = user_a_character_id();
        let inventory = df::borrow_mut<ID, Inventory>(
            &mut storage_unit.id,
            character_id,
        );

        inventory.mint_items(
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            15u32,
            LOCATION_A_HASH,
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
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
        let character_id = user_a_character_id();
        let inventory = df::borrow_mut<ID, Inventory>(
            &mut storage_unit.id,
            character_id,
        );

        inventory.burn_items_test(
            AMMO_ITEM_ID,
            AMMO_QUANTITY,
        );
        ts::return_shared(storage_unit);
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
        let character_id = user_a_character_id();
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        inventory.burn_items_test(
            AMMO_ITEM_ID,
            15u32,
        );
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests that depositing items into inventory with insufficient capacity fails
/// Scenario: Attempt to deposit item requiring 1000 volume into inventory with only 10 capacity
/// Expected: Transaction aborts with EInventoryInsufficientCapacity error
#[test]
#[expected_failure(abort_code = inventory::EInventoryInsufficientCapacity)]
fun deposit_item_fail_insufficient_capacity() {
    let character_a_id = user_a_character_id();
    let character_b_id = user_b_character_id();

    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_unit_id = create_storage_unit(&mut ts);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_unit_id);

    online(&mut ts);
    mint_ammo(&mut ts);

    // Create a ephemeral inventory for user b with capacity  10
    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let inventory = inventory::create(
            storage_unit_id,
            character_a_id,
            10,
        );
        df::add(&mut storage_unit.id, character_b_id, inventory);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        let inventory_a = df::borrow<ID, Inventory>(&storage_unit.id, character_a_id);
        let inventory_b = df::borrow<ID, Inventory>(&storage_unit.id, character_b_id);
        test_helpers::setup_owner_cap(&mut ts, user_a(), inventory_a.id());
        test_helpers::setup_owner_cap(&mut ts, user_b(), inventory_b.id());
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, user_a());
    let item = {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_a_id);
        let item = inventory.withdraw_item(AMMO_ITEM_ID);
        ts::return_shared(storage_unit);
        item
    };

    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let eph_inventory = df::borrow_mut<ID, Inventory>(
            &mut storage_unit.id,
            character_b_id,
        );
        eph_inventory.deposit_item(item);
        ts::return_shared(storage_unit);
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
        let character_id = user_a_character_id();
        let inventory = df::borrow_mut<ID, Inventory>(&mut storage_unit.id, character_id);
        // This should abort with EItemDoesNotExist
        let item = inventory.withdraw_item(1222);
        // Unreachable code below - needed to satisfy Move's type checker
        inventory.deposit_item(item);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}
