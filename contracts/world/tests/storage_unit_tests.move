module world::storage_unit_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    authority::{OwnerCap, AdminCap},
    inventory::Item,
    storage_unit::{Self, StorageUnit},
    test_helpers::{Self, governor, admin, user_a, user_b}
};

const LOCATION_A_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const PROOF: vector<u8> = x"5a2f1b0e7c4d1a6f5e8b2d9c3f7a1e5b";
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
        ctx,
    );

    // Step 3: withdraws item owned by the interactor from their storage (owner access)
    let ammo = ephemeral_storage.withdraw_by_owner(
        owner_cap,
        AMMO_ITEM_ID,
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

        let status = storage_unit.get_status();
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
        storage_unit.game_to_chain_inventory(
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
        storage_unit.game_to_chain_inventory(
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

#[test]
fun test_create_storage_unit() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inv_ref = storage_unit.get_inventory();
        let location_ref = storage_unit.get_location();

        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.get_inventory_item_length(), 0);
        assert_eq!(location_ref.get_hash(), LOCATION_A_HASH);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

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
        let inv_ref = storage_unit.get_inventory();

        let used_capacity = (AMMO_QUANTITY as u64 * AMMO_VOLUME);
        assert_eq!(inv_ref.used_capacity(), used_capacity);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(inv_ref.get_item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);
        assert_eq!(inv_ref.get_inventory_item_length(), 1);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

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
        assert_eq!(storage_unit.get_item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

#[test]
fun test_deposit_and_withdraw_by_owner() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_id);

    online_storage_unit(&mut ts, user_a(), storage_id);
    mint_ammo(&mut ts, storage_id);

    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        item =
            storage_unit.withdraw_by_owner(
                &owner_cap,
                AMMO_ITEM_ID,
                ts.ctx(),
            );
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        storage_unit.deposit_by_owner(
            item,
            &owner_cap,
            ts.ctx(),
        );
        assert_eq!(storage_unit.get_item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// This test simulates a 3rd party swap contract (like a marketplace)
/// User A owner of the Storage Unit has lens in their storage (authorized with SwapAuth)
/// User B has ammo in their storage (ephemeral storage attached to the SSU)
/// User B interacts with Storage Unit with Swap logic
/// Swap logic withdraws item owned by User B and deposits to User A storage
/// Then it withdraws item owned by User A via auth logic and deposits to User B storage
#[test]
fun test_swap_ammo_for_lens() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    // Create User A's storage unit with lens
    let storage_a_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap(&mut ts, user_a(), storage_a_id);
    online_storage_unit(&mut ts, user_a(), storage_a_id);
    mint_lens(&mut ts, storage_a_id);

    // Create User B's storage_b storage unit with ammo
    let storage_b_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap(&mut ts, user_b(), storage_b_id);
    online_storage_unit(&mut ts, user_b(), storage_b_id);
    mint_ammo(&mut ts, storage_b_id);

    // User A authorizes the swap extension for their storage to swap lens for ammo
    ts::next_tx(&mut ts, user_a());
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
        let inv_ref_a = storage_a.get_inventory();
        let inv_ref_b = storage_b.get_inventory();

        assert_eq!(inv_ref_a.used_capacity(), used_capacity_a);
        assert_eq!(inv_ref_a.remaining_capacity(), MAX_CAPACITY - used_capacity_a);
        assert_eq!(inv_ref_b.used_capacity(), used_capacity_b);
        assert_eq!(inv_ref_b.remaining_capacity(), MAX_CAPACITY - used_capacity_b);

        assert_eq!(storage_a.get_item_quantity(LENS_ITEM_ID), LENS_QUANTITY);
        assert!(!storage_a.get_inventory().contains_item(AMMO_ITEM_ID));
        assert_eq!(storage_b.get_item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);
        assert!(!storage_b.get_inventory().contains_item(LENS_ITEM_ID));

        ts::return_shared(storage_a);
        ts::return_shared(storage_b);
    };

    // User B interacts with swap
    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let mut storage_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);
        let owner_cap_b = ts::take_from_sender<OwnerCap>(&ts);

        swap_ammo_for_lens_extension(
            &mut storage_a,
            &mut storage_b,
            &owner_cap_b,
            ts.ctx(),
        );

        ts::return_shared(storage_a);
        ts::return_shared(storage_b);
        ts::return_to_sender(&ts, owner_cap_b);
    };

    // Verify swap
    ts::next_tx(&mut ts, admin());
    {
        let storage_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let storage_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);

        assert_eq!(storage_a.get_item_quantity(AMMO_ITEM_ID), AMMO_QUANTITY);
        assert!(!storage_a.get_inventory().contains_item(LENS_ITEM_ID));
        assert_eq!(storage_b.get_item_quantity(LENS_ITEM_ID), LENS_QUANTITY);
        assert!(!storage_b.get_inventory().contains_item(AMMO_ITEM_ID));

        ts::return_shared(storage_a);
        ts::return_shared(storage_b);
    };

    ts::end(ts);
}

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

#[test]
#[expected_failure(abort_code = storage_unit::EExtensionNotAuthorized)]
fun test_deposit_via_extension_fail_not_authorized() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap_for_user_a(&mut ts, storage_id);

    online_storage_unit(&mut ts, user_a(), storage_id);
    mint_ammo(&mut ts, storage_id);

    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        item = storage_unit.withdraw_by_owner(&owner_cap, AMMO_ITEM_ID, ts.ctx());
        ts::return_shared(storage_unit);
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

#[test]
#[expected_failure(abort_code = storage_unit::EAccessNotAuthorized)]
fun test_withdraw_by_owner_fail_wrong_owner() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let storage_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
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
        let item = storage_unit.withdraw_by_owner(
            &owner_cap,
            AMMO_ITEM_ID,
            ts.ctx(),
        );
        storage_unit.deposit_by_owner(item, &owner_cap, ts.ctx());
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = storage_unit::EExtensionNotAuthorized)]
fun test_swap_fail_extension_not_authorized() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let storage_a_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap(&mut ts, user_a(), storage_a_id);
    online_storage_unit(&mut ts, user_a(), storage_a_id);
    mint_lens(&mut ts, storage_a_id);

    let storage_b_id = create_storage_unit(&mut ts, LOCATION_A_HASH);
    test_helpers::setup_owner_cap(&mut ts, user_b(), storage_b_id);
    online_storage_unit(&mut ts, user_b(), storage_b_id);
    mint_ammo(&mut ts, storage_b_id);

    //Skipped authorisation

    // call swap
    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_a = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let mut storage_b = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);
        let owner_cap_b = ts::take_from_sender<OwnerCap>(&ts);

        swap_ammo_for_lens_extension(
            &mut storage_a,
            &mut storage_b,
            &owner_cap_b,
            ts.ctx(),
        );

        ts::return_shared(storage_a);
        ts::return_shared(storage_b);
        ts::return_to_sender(&ts, owner_cap_b);
    };
    ts::end(ts);
}
