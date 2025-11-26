module world::storage_unit_tests;

use std::{bcs, unit_test::assert_eq};
use sui::{clock, test_scenario as ts};
use world::{
    authority::{OwnerCap, AdminCap, ServerAddressRegistry},
    inventory::Item,
    storage_unit::{Self, StorageUnit},
    test_helpers::{Self, governor, admin, user_a, user_b}
};

const LOCATION_A_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const MAX_CAPACITY: u64 = 100000;
const STORAGE_TYPE_ID: u64 = 50001;
const STORAGE_ITEM_ID: u64 = 90001;

// Item constants
const AMMO_TYPE_ID: u64 = 88069;
const AMMO_ITEM_ID: u64 = 1000004145107;
const AMMO_VOLUME: u64 = 100;
const AMMO_QUANTITY: u32 = 10;

const LENS_TYPE_ID: u64 = 88070;
const LENS_ITEM_ID: u64 = 1000004145108;
const LENS_VOLUME: u64 = 50;
const LENS_QUANTITY: u32 = 5;

// Mock 3rd Party Extension Witness Types
/// Authorized extension witness type
public struct SwapAuth has drop {}

/// mock of a an external marketplace or swap contract
public fun swap_ammo_for_lens_extension(
    storage_a: &mut StorageUnit, //owned by userA
    ephemeral_storage: &mut StorageUnit, //owned by anyone who interacts with Storage unit
    owner_cap: &OwnerCap,
    server_registry: &ServerAddressRegistry,
    proof_bytes: vector<u8>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    // Step 1: withdraws lens from storage unit (extension access)
    let lens = storage_a.withdraw_item<SwapAuth>(
        SwapAuth {},
        LENS_ITEM_ID,
        ctx,
    );

    // Step 2: deposits lens to ephemeral storage (owner access)
    ephemeral_storage.deposit_by_owner(
        lens,
        owner_cap,
        server_registry,
        proof_bytes,
        clock,
        ctx,
    );

    // Step 3: withdraws item owned by the interactor from their storage (owner access)
    let ammo = ephemeral_storage.withdraw_by_owner(
        owner_cap,
        AMMO_ITEM_ID,
        server_registry,
        proof_bytes,
        clock,
        ctx,
    );

    // Step 4: deposits the item from Step 3 to storage unit (extension access)
    storage_a.deposit_item<SwapAuth>(
        SwapAuth {},
        ammo,
        ctx,
    );
}

// === Helper Functions ===

fun create_storage_unit(ts: &mut ts::Scenario, location: vector<u8>): ID {
    ts::next_tx(ts, admin());
    let storage_unit_id = {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let storage_unit = storage_unit::create_storage_unit(
            &admin_cap,
            STORAGE_TYPE_ID,
            STORAGE_ITEM_ID,
            MAX_CAPACITY,
            location,
            ts.ctx(),
        );
        let storage_unit_id = object::id(&storage_unit);
        storage_unit.share_storage_unit(&admin_cap);
        ts::return_to_sender(ts, admin_cap);
        storage_unit_id
    };
    storage_unit_id
}

fun online_storage_unit(ts: &mut ts::Scenario, user: address, storage_id: ID) {
    ts::next_tx(ts, user);
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(ts);
        storage_unit.online(&owner_cap);

        let status = storage_unit.status();
        assert_eq!(status.status_to_u8(), 1);
        ts::return_shared(storage_unit);
        ts::return_to_sender(ts, owner_cap);
    }
}

fun mint_ammo(ts: &mut ts::Scenario, storage_id: ID) {
    ts::next_tx(ts, admin());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        storage_unit.game_item_to_chain_inventory(
            &admin_cap,
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
        ts::return_to_sender(ts, admin_cap);
    }
}

fun mint_lens(ts: &mut ts::Scenario, storage_id: ID) {
    ts::next_tx(ts, admin());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        storage_unit.game_item_to_chain_inventory(
            &admin_cap,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
        ts::return_to_sender(ts, admin_cap);
    }
}

/// Tests creating a storage unit
/// Scenario: Admin creates a storage unit with location hash
/// Expected: Storage unit is created successfully with correct initial state
#[test]
fun test_create_storage_unit() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inv_ref = storage_unit.inventory();
        let location_ref = storage_unit.location();

        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.inventory_item_length(), 0);
        assert_eq!(location_ref.hash(), LOCATION_A_HASH);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests minting items into storage unit inventory
/// Scenario: Admin mints ammo items into an online storage unit
/// Expected: Items are minted successfully and inventory state is correct
#[test]
fun test_create_items_on_chain() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_id);

    online_storage_unit(&mut ts, user_a(), storage_id);
    mint_ammo(&mut ts, storage_id);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inv_ref = storage_unit.inventory();

        let used_capacity = (AMMO_QUANTITY as u64 * AMMO_VOLUME);
        assert_eq!(inv_ref.used_capacity(), used_capacity);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(inv_ref.item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);
        assert_eq!(inv_ref.inventory_item_length(), 1);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests authorizing an extension type for storage unit
/// Scenario: Owner authorizes SwapAuth extension type for their storage unit
/// Expected: Extension is successfully authorized
#[test]
fun test_authorize_extension() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_id);

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);

        storage_unit.authorize_extension<SwapAuth>(&owner_cap);

        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Tests depositing and withdrawing items via extension
/// Scenario: Authorize extension, withdraw item, then deposit it back using extension access
/// Expected: Items can be withdrawn and deposited successfully via extension
#[test]
fun test_deposit_and_withdraw_via_extension() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_id);

    online_storage_unit(&mut ts, user_a(), storage_id);
    mint_ammo(&mut ts, storage_id);

    // Authorize extension
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        storage_unit.authorize_extension<SwapAuth>(&owner_cap);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        item =
            storage_unit.withdraw_item<SwapAuth>(
                SwapAuth {},
                AMMO_ITEM_ID,
                ts.ctx(),
            );
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        storage_unit.deposit_item<SwapAuth>(
            SwapAuth {},
            item,
            ts.ctx(),
        );
        assert_eq!(storage_unit.item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests depositing and withdrawing items by owner
/// Scenario: Owner withdraws item and deposits it back using owner access
/// Expected: Items can be withdrawn and deposited successfully by owner
#[test]
fun test_deposit_and_withdraw_by_owner() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    let storage_id = create_storage_unit(&mut ts, test_helpers::get_verified_location_hash());
    test_helpers::setup_owner_cap(&mut ts, user_a(), storage_id);

    online_storage_unit(&mut ts, user_a(), storage_id);
    mint_ammo(&mut ts, storage_id);

    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        item =
            storage_unit.withdraw_by_owner(
                &owner_cap,
                AMMO_ITEM_ID,
                &server_registry,
                proof_bytes,
                &clock,
                ts.ctx(),
            );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        storage_unit.deposit_by_owner(
            item,
            &owner_cap,
            &server_registry,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        assert_eq!(storage_unit.item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// This test simulates a 3rd party swap contract (like a marketplace)
/// User B owner of the Storage Unit has lens in their storage (authorized with SwapAuth)
/// User A has ammo in their storage (ephemeral storage attached to the SSU)
/// User A interacts with Storage Unit with Swap logic
/// Swap logic withdraws item owned by User A and deposits to User B storage
/// Then it withdraws item owned by User B via auth logic and deposits to User A storage
#[test]
fun test_swap_ammo_for_lens() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);

    // Create User A's storage unit with lens
    let storage_a_id = create_storage_unit(&mut ts, test_helpers::get_verified_location_hash());
    test_helpers::setup_owner_cap(&mut ts, user_b(), storage_a_id);
    online_storage_unit(&mut ts, user_b(), storage_a_id);
    mint_lens(&mut ts, storage_a_id);

    // Create User B's storage_b storage unit with ammo
    let storage_b_id = create_storage_unit(&mut ts, test_helpers::get_verified_location_hash());
    test_helpers::setup_owner_cap(&mut ts, user_a(), storage_b_id);
    online_storage_unit(&mut ts, user_a(), storage_b_id);
    mint_ammo(&mut ts, storage_b_id);

    // User A authorizes the swap extension for their storage to swap lens for ammo
    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let owner_cap_a = ts::take_from_sender<OwnerCap>(&ts);
        storage_a.authorize_extension<SwapAuth>(&owner_cap_a);
        ts::return_shared(storage_a);
        ts::return_to_sender(&ts, owner_cap_a);
    };

    // Before swap
    ts::next_tx(&mut ts, admin());
    {
        let storage_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let storage_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);

        let used_capacity_a = (LENS_QUANTITY as u64* LENS_VOLUME);
        let used_capacity_b = (AMMO_QUANTITY as u64* AMMO_VOLUME);
        let inv_ref_a = storage_a.inventory();
        let inv_ref_b = storage_b.inventory();

        assert_eq!(inv_ref_a.used_capacity(), used_capacity_a);
        assert_eq!(inv_ref_a.remaining_capacity(), MAX_CAPACITY - used_capacity_a);
        assert_eq!(inv_ref_b.used_capacity(), used_capacity_b);
        assert_eq!(inv_ref_b.remaining_capacity(), MAX_CAPACITY - used_capacity_b);

        assert_eq!(storage_a.item_quantity(LENS_ITEM_ID), LENS_QUANTITY);
        assert!(!storage_a.inventory().contains_item(AMMO_ITEM_ID));
        assert_eq!(storage_b.item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);
        assert!(!storage_b.inventory().contains_item(LENS_ITEM_ID));

        ts::return_shared(storage_a);
        ts::return_shared(storage_b);
    };

    // user_a interacts with swap
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let mut storage_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);
        let owner_cap_b = ts::take_from_sender<OwnerCap>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        swap_ammo_for_lens_extension(
            &mut storage_a,
            &mut storage_b,
            &owner_cap_b,
            &server_registry,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(storage_a);
        ts::return_shared(storage_b);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap_b);
    };

    // Verify swap
    ts::next_tx(&mut ts, admin());
    {
        let storage_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let storage_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);

        assert_eq!(storage_a.item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);
        assert!(!storage_a.inventory().contains_item(LENS_ITEM_ID));
        assert_eq!(storage_b.item_quantity(LENS_ITEM_ID), LENS_QUANTITY);
        assert!(!storage_b.inventory().contains_item(AMMO_ITEM_ID));

        ts::return_shared(storage_a);
        ts::return_shared(storage_b);
    };

    ts::end(ts);
}

/// Tests that authorizing extension without proper owner capability fails
/// Scenario: User B attempts to authorize extension for User A's storage unit using wrong OwnerCap
/// Expected: Transaction aborts with EAccessNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EAccessNotAuthorized)]
fun test_authorize_extension_fail_wrong_owner() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_id);

    let dummy_id = object::id_from_bytes(
        x"0000000000000000000000000000000000000000000000000000000000000001",
    );
    test_helpers::setup_owner_cap(&mut ts, user_b(), dummy_id);

    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);

        storage_unit.authorize_extension<SwapAuth>(&owner_cap);

        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Tests that withdrawing via extension without authorization fails
/// Scenario: Attempt to withdraw item via extension without authorizing the extension type
/// Expected: Transaction aborts with EExtensionNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EExtensionNotAuthorized)]
fun test_withdraw_via_extension_fail_not_authorized() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_id);

    online_storage_unit(&mut ts, user_a(), storage_id);
    mint_ammo(&mut ts, storage_id);

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let item = storage_unit.withdraw_item<SwapAuth>(
            SwapAuth {},
            AMMO_ITEM_ID,
            ts.ctx(),
        );

        storage_unit.deposit_item<SwapAuth>(
            SwapAuth {},
            item,
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests that depositing via extension without authorization fails
/// Scenario: Attempt to deposit item via extension without authorizing the extension type
/// Expected: Transaction aborts with EExtensionNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EExtensionNotAuthorized)]
fun test_deposit_via_extension_fail_not_authorized() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    let storage_id = create_storage_unit(&mut ts, test_helpers::get_verified_location_hash());
    test_helpers::setup_owner_cap(&mut ts, user_a(), storage_id);

    online_storage_unit(&mut ts, user_a(), storage_id);
    mint_ammo(&mut ts, storage_id);

    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        item =
            storage_unit.withdraw_by_owner(
                &owner_cap,
                AMMO_ITEM_ID,
                &server_registry,
                proof_bytes,
                &clock,
                ts.ctx(),
            );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        storage_unit.deposit_item<SwapAuth>(
            SwapAuth {},
            item,
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Tests that withdrawing by owner without proper owner capability fails
/// Scenario: User B attempts to withdraw items from User A's storage unit using wrong OwnerCap
/// Expected: Transaction aborts with EAccessNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EAccessNotAuthorized)]
fun test_withdraw_by_owner_fail_wrong_owner() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    let storage_id = create_storage_unit(&mut ts, test_helpers::get_verified_location_hash());
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_id);

    online_storage_unit(&mut ts, user_a(), storage_id);
    mint_ammo(&mut ts, storage_id);

    let dummy_id = object::id_from_bytes(
        x"0000000000000000000000000000000000000000000000000000000000000001",
    );
    test_helpers::setup_owner_cap(&mut ts, user_b(), dummy_id);

    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        let item = storage_unit.withdraw_by_owner(
            &owner_cap,
            AMMO_ITEM_ID,
            &server_registry,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        storage_unit.deposit_by_owner(
            item,
            &owner_cap,
            &server_registry,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Tests that depositing by owner without proper owner capability fails
/// Scenario: User A withdraws item, then User B attempts to deposit it back using wrong OwnerCap
/// Expected: Transaction aborts with EAccessNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EAccessNotAuthorized)]
fun test_deposit_by_owner_fail_wrong_owner() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    let storage_id = create_storage_unit(&mut ts, test_helpers::get_verified_location_hash());
    test_helpers::setup_owner_cap(&mut ts, user_a(), storage_id);

    online_storage_unit(&mut ts, user_a(), storage_id);
    mint_ammo(&mut ts, storage_id);

    let dummy_id = object::id_from_bytes(
        x"0000000000000000000000000000000000000000000000000000000000000001",
    );
    test_helpers::setup_owner_cap(&mut ts, user_b(), dummy_id);

    // user_a withdraws item
    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        item =
            storage_unit.withdraw_by_owner(
                &owner_cap,
                AMMO_ITEM_ID,
                &server_registry,
                proof_bytes,
                &clock,
                ts.ctx(),
            );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };

    // User B attempts to deposit using wrong OwnerCap - should fail
    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        // This should fail with EAccessNotAuthorized
        storage_unit.deposit_by_owner(
            item,
            &owner_cap,
            &server_registry,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Tests that swap fails when extension is not authorized
/// Scenario: Attempt to swap items via extension without authorizing the extension type
/// Expected: Transaction aborts with EExtensionNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EExtensionNotAuthorized)]
fun test_swap_fail_extension_not_authorized() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);

    let storage_a_id = create_storage_unit(&mut ts, test_helpers::get_verified_location_hash());
    test_helpers::setup_owner_cap(&mut ts, user_a(), storage_a_id);
    online_storage_unit(&mut ts, user_a(), storage_a_id);
    mint_lens(&mut ts, storage_a_id);

    let storage_b_id = create_storage_unit(&mut ts, test_helpers::get_verified_location_hash());
    test_helpers::setup_owner_cap(&mut ts, test_helpers::server_admin(), storage_b_id);
    online_storage_unit(&mut ts, test_helpers::server_admin(), storage_b_id);
    mint_ammo(&mut ts, storage_b_id);

    //Skipped authorisation

    // call swap
    ts::next_tx(&mut ts, test_helpers::server_admin());
    {
        let mut storage_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let mut storage_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);
        let owner_cap_b = ts::take_from_sender<OwnerCap>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        swap_ammo_for_lens_extension(
            &mut storage_a,
            &mut storage_b,
            &owner_cap_b,
            &server_registry,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(storage_a);
        ts::return_shared(storage_b);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap_b);
    };
    ts::end(ts);
}
