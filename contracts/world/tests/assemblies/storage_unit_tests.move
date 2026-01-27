module world::storage_unit_tests;

use std::{bcs, string::{utf8, String}, unit_test::assert_eq};
use sui::{clock, derived_object, test_scenario as ts};
use world::{
    access::{OwnerCap, AdminCap, ServerAddressRegistry, AdminACL},
    character::{Self, Character},
    energy::EnergyConfig,
    fuel::FuelConfig,
    in_game_id,
    inventory::Item,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    storage_unit::{Self, StorageUnit},
    test_helpers::{Self, governor, admin, user_a, user_b, tenant}
};

const CHARACTER_A_ITEM_ID: u32 = 1234u32;
const CHARACTER_B_ITEM_ID: u32 = 5678u32;

const LOCATION_A_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const MAX_CAPACITY: u64 = 100000;
const STORAGE_A_TYPE_ID: u64 = 5555;
const STORAGE_A_ITEM_ID: u64 = 90002;
const DUMMY_ITEM_ID: u64 = 002;

// Item constants
const AMMO_TYPE_ID: u64 = 88069;
const AMMO_ITEM_ID: u64 = 1000004145107;
const AMMO_VOLUME: u64 = 100;
const AMMO_QUANTITY: u32 = 10;

const LENS_TYPE_ID: u64 = 88070;
const LENS_ITEM_ID: u64 = 1000004145108;
const LENS_VOLUME: u64 = 50;
const LENS_QUANTITY: u32 = 5;

const STATUS_ONLINE: u8 = 1;

const DIFFERENT_TENANT: vector<u8> = b"DIFFERENT";

// Network node constants
const MS_PER_SECOND: u64 = 1000;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 100;
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

// Mock 3rd Party Extension Witness Types
/// Authorized extension witness type
public struct SwapAuth has drop {}

/// mock of a an external marketplace or swap contract
public fun swap_ammo_for_lens_extension<T: key>(
    storage_unit: &mut StorageUnit,
    owner_cap: &OwnerCap<T>,
    character: &Character,
    server_registry: &ServerAddressRegistry,
    proof_bytes: vector<u8>,
    clock: &sui::clock::Clock,
    ctx: &mut TxContext,
) {
    // Step 1: withdraws lens from storage unit (extension access)
    let lens = storage_unit.withdraw_item<SwapAuth>(
        character,
        SwapAuth {},
        LENS_TYPE_ID,
        ctx,
    );

    // Step 2: deposits lens to ephemeral storage (owner access)
    storage_unit.deposit_by_owner(
        lens,
        server_registry,
        owner_cap,
        character,
        proof_bytes,
        clock,
        ctx,
    );

    // Step 3: withdraws item owned by the interactor from their storage (owner access)
    let ammo = storage_unit.withdraw_by_owner(
        server_registry,
        owner_cap,
        character,
        AMMO_TYPE_ID,
        proof_bytes,
        clock,
        ctx,
    );

    // Step 4: deposits the item from Step 3 to storage unit (extension access)
    storage_unit.deposit_item<SwapAuth>(
        character,
        ammo,
        SwapAuth {},
        ctx,
    );
}

// === Helper Functions ===
fun setup_nwn(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
    test_helpers::configure_assembly_energy(ts);
    test_helpers::register_server_address(ts);
}

fun create_network_node(ts: &mut ts::Scenario, character_id: ID): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    // Check if network node already exists
    let tenant = character.tenant();
    let nwn_key = in_game_id::create_key(NWN_ITEM_ID, tenant);
    let id = if (registry.object_exists(nwn_key)) {
        // Network node exists, derive its ID
        let nwn_addr = derived_object::derive_address(
            object::id(&registry),
            nwn_key,
        );
        object::id_from_address(nwn_addr)
    } else {
        // Network node doesn't exist, create it
        let nwn = network_node::anchor(
            &mut registry,
            &character,
            &admin_cap,
            NWN_ITEM_ID,
            NWN_TYPE_ID,
            LOCATION_A_HASH,
            FUEL_MAX_CAPACITY,
            FUEL_BURN_RATE_IN_MS,
            MAX_PRODUCTION,
            ts.ctx(),
        );
        let id = object::id(&nwn);
        network_node::share_network_node(nwn, &admin_cap);
        id
    };

    ts::return_shared(character);
    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(registry);
    id
}

fun create_storage_unit(
    ts: &mut ts::Scenario,
    character_id: ID,
    location: vector<u8>,
    item_id: u64,
    type_id: u64,
): (ID, ID) {
    let nwn_id = create_network_node(ts, character_id);
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let storage_unit_id = {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let storage_unit = storage_unit::anchor(
            &mut registry,
            &mut nwn,
            &character,
            &admin_cap,
            item_id,
            type_id,
            MAX_CAPACITY,
            location,
            ts.ctx(),
        );
        let storage_unit_id = object::id(&storage_unit);
        storage_unit.share_storage_unit(&admin_cap);
        ts::return_to_sender(ts, admin_cap);
        storage_unit_id
    };
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(nwn);
    (storage_unit_id, nwn_id)
}

fun online_storage_unit(ts: &mut ts::Scenario, user: address, storage_id: ID, nwn_id: ID) {
    // Deposit fuel and bring network node online
    let clock = clock::create_for_testing(ts.ctx());
    ts::next_tx(ts, user);
    let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(ts);
    ts::next_tx(ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let admin_acl = ts::take_shared<AdminACL>(ts);
        nwn.deposit_fuel_test(
            &admin_acl,
            &owner_cap,
            FUEL_TYPE_ID,
            FUEL_VOLUME,
            10,
            &clock,
            ts.ctx(),
        );
        ts::return_shared(admin_acl);
        ts::return_shared(nwn);
    };

    ts::next_tx(ts, user);
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
    };
    ts::next_tx(ts, user);
    {
        ts::return_to_sender(ts, owner_cap);
    };

    // Now bring storage unit online
    ts::next_tx(ts, user);
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(ts);
        storage_unit.online(&mut nwn, &energy_config, &owner_cap);

        let status = storage_unit.status();
        assert_eq!(status.status_to_u8(), STATUS_ONLINE);
        ts::return_shared(storage_unit);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_to_sender(ts, owner_cap);
    };
    clock.destroy_for_testing();
}

fun mint_ammo<T: key>(ts: &mut ts::Scenario, storage_id: ID, character_id: ID, user: address) {
    ts::next_tx(ts, user);
    let owner_cap = {
        let owner_cap = ts::take_from_sender<OwnerCap<T>>(ts);
        owner_cap
    };
    ts::next_tx(ts, admin());
    let owner_cap = {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        let character = ts::take_shared_by_id<Character>(ts, character_id);
        let admin_acl = ts::take_shared<AdminACL>(ts);
        storage_unit.game_item_to_chain_inventory_test<T>(
            &admin_acl,
            &owner_cap,
            &character,
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
            ts.ctx(),
        );
        ts::return_shared(admin_acl);
        ts::return_shared(storage_unit);
        ts::return_shared(character);
        owner_cap
    };
    ts::next_tx(ts, user);
    {
        ts::return_to_sender(ts, owner_cap);
    }
}

fun mint_lens<T: key>(ts: &mut ts::Scenario, storage_id: ID, character_id: ID, user: address) {
    ts::next_tx(ts, user);
    let owner_cap = {
        let owner_cap = ts::take_from_sender<OwnerCap<T>>(ts);
        owner_cap
    };
    ts::next_tx(ts, admin());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        let character = ts::take_shared_by_id<Character>(ts, character_id);
        let admin_acl = ts::take_shared<AdminACL>(ts);
        storage_unit.game_item_to_chain_inventory_test<T>(
            &admin_acl,
            &owner_cap,
            &character,
            LENS_ITEM_ID,
            LENS_TYPE_ID,
            LENS_VOLUME,
            LENS_QUANTITY,
            ts.ctx(),
        );
        ts::return_shared(admin_acl);
        ts::return_shared(storage_unit);
        ts::return_shared(character);
    };
    ts::next_tx(ts, user);
    {
        ts::return_to_sender(ts, owner_cap);
    }
}

fun create_character(ts: &mut ts::Scenario, user: address, item_id: u32): ID {
    create_character_with_tenant(ts, user, item_id, tenant())
}

fun create_character_with_tenant(
    ts: &mut ts::Scenario,
    user: address,
    item_id: u32,
    tenant: String,
): ID {
    ts::next_tx(ts, admin());
    let character_id = {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            item_id,
            tenant,
            100,
            user,
            utf8(b"name"),
            ts::ctx(ts),
        );
        let character_id = object::id(&character);
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(ts, admin_cap);
        character_id
    };
    character_id
}

// Character Owner Caps for Ephemeral Inventory interaction
fun character_owner_cap_id(ts: &mut ts::Scenario, user: address): ID {
    ts::next_tx(ts, user);
    let owner_cap_id = {
        let owner_cap = ts::take_from_sender<OwnerCap<Character>>(ts);
        let owner_cap_id = object::id(&owner_cap);
        ts::return_to_sender(ts, owner_cap);
        owner_cap_id
    };
    owner_cap_id
}

fun storage_owner_cap_id(ts: &mut ts::Scenario, storage_id: ID): ID {
    ts::next_tx(ts, admin());
    let owner_cap_id = {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(ts, storage_id);
        let owner_cap_id = storage_unit.owner_cap_id();
        ts::return_shared(storage_unit);
        owner_cap_id
    };
    owner_cap_id
}

/// Test Anchoring a storage unit
/// Scenario: Admin anchors a storage unit with location hash
/// Expected: Storage unit is created successfully with correct initial state
#[test]
fun test_anchor_storage_unit() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let (storage_id, _) = create_storage_unit(
        &mut ts,
        character_id,
        LOCATION_A_HASH,
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    let owner_cap_id = storage_owner_cap_id(&mut ts, storage_id);

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inventory_keys = storage_unit.inventory_keys();
        assert!(storage_unit.has_inventory(owner_cap_id));
        assert_eq!(inventory_keys.length(), 1);
        assert_eq!(*inventory_keys.borrow(0), owner_cap_id);

        let inv_ref = storage_unit.inventory(owner_cap_id);
        let location_ref = storage_unit.location();

        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.inventory_item_length(), 0);
        assert_eq!(location_ref.hash(), LOCATION_A_HASH);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Test minting items into storage unit inventory
/// Scenario: Admin mints ammo items into an online storage unit
/// Expected: Items are minted successfully and inventory state is correct
#[test]
fun test_create_items_on_chain() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    // Create a storage unit for user_a
    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        LOCATION_A_HASH,
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    let owner_cap_id = storage_owner_cap_id(&mut ts, storage_id);
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);
    mint_ammo<StorageUnit>(&mut ts, storage_id, character_id, user_a());

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inv_ref = storage_unit.inventory(owner_cap_id);
        let used_capacity = (AMMO_QUANTITY as u64 * AMMO_VOLUME);
        assert_eq!(inv_ref.used_capacity(), used_capacity);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(inv_ref.item_quantity(AMMO_TYPE_ID), AMMO_QUANTITY);
        assert_eq!(inv_ref.inventory_item_length(), 1);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

/// Test burning items from storage unit inventory
/// Scenario: Admin moves ammo on-chain by game_item_to_chain_inventory()
/// User moves ammo from on-chain to game by chain_item_to_game_inventory()
/// Excpected: moving items back and forth is successfull
#[test]
fun test_game_item_to_chain_and_chain_item_to_game_inventory() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    let owner_cap_id = storage_owner_cap_id(&mut ts, storage_id);
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);
    mint_ammo<StorageUnit>(&mut ts, storage_id, character_id, user_a());

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inv_ref = storage_unit.inventory(owner_cap_id);

        let used_capacity = (AMMO_QUANTITY as u64 * AMMO_VOLUME);
        assert_eq!(inv_ref.used_capacity(), used_capacity);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY - used_capacity);
        assert_eq!(inv_ref.item_quantity(AMMO_TYPE_ID), AMMO_QUANTITY);
        assert_eq!(inv_ref.inventory_item_length(), 1);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);
        storage_unit.chain_item_to_game_inventory_test(
            &server_registry,
            &owner_cap,
            &character,
            AMMO_TYPE_ID,
            AMMO_QUANTITY,
            proof_bytes,
            ts.ctx(),
        );
        ts::return_shared(character);

        let inv_ref = storage_unit.inventory(owner_cap_id);
        assert_eq!(inv_ref.used_capacity(), 0);
        assert_eq!(inv_ref.remaining_capacity(), MAX_CAPACITY);
        assert_eq!(inv_ref.inventory_item_length(), 0);

        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::end(ts);
}

/// Test adding items twice in the ephemeral inventory
/// Scenario: User A mints lens on-chain by game_item_to_chain_inventory()
/// User B mints lens on-chain by game_item_to_chain_inventory()
/// User B mints ammo on-chain
/// Expected: ephemeral inventory should only created once
#[test]
fun test_mint_multiple_items_in_ephemeral_inventory() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_a_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let character_b_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);

    // Create storage unit for User A
    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_a_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    let owner_cap_id = storage_owner_cap_id(&mut ts, storage_id);
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);

    // Mint lens for user A
    mint_lens<StorageUnit>(&mut ts, storage_id, character_a_id, user_a());
    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inventory_keys = storage_unit.inventory_keys();
        assert!(storage_unit.has_inventory(owner_cap_id));
        assert_eq!(inventory_keys.length(), 1);
        assert_eq!(*inventory_keys.borrow(0), owner_cap_id);
        ts::return_shared(storage_unit);
    };

    // Create a character owner cap as a biometric to mint items in ephemeral inventory
    let character_owner_cap_id = character_owner_cap_id(&mut ts, user_b());

    // Mint lens for user B
    mint_lens<Character>(&mut ts, storage_id, character_b_id, user_b());
    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inventory_keys = storage_unit.inventory_keys();
        assert!(storage_unit.has_inventory(character_owner_cap_id));
        assert_eq!(inventory_keys.length(), 2);
        assert_eq!(*inventory_keys.borrow(1), character_owner_cap_id);
        ts::return_shared(storage_unit);
    };

    // Mint Ammo for user B
    mint_ammo<Character>(&mut ts, storage_id, character_b_id, user_b());
    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inventory_keys = storage_unit.inventory_keys();
        assert!(storage_unit.has_inventory(character_owner_cap_id));
        assert_eq!(inventory_keys.length(), 2);
        assert_eq!(*inventory_keys.borrow(1), character_owner_cap_id);
        ts::return_shared(storage_unit);
    };

    ts::end(ts);
}

/// Test authorizing an extension type for storage unit
/// Scenario: Owner authorizes SwapAuth extension type for their storage unit
/// Expected: Extension is successfully authorized
#[test]
fun test_authorize_extension() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    let (storage_id, _) = create_storage_unit(
        &mut ts,
        character_id,
        LOCATION_A_HASH,
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);

        storage_unit.authorize_extension<SwapAuth>(&owner_cap);

        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Test depositing and withdrawing items via extension
/// Scenario: Authorize extension, withdraw item, then deposit it back using extension access
/// Expected: Items can be withdrawn and deposited successfully via extension
#[test]
fun test_deposit_and_withdraw_via_extension() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        LOCATION_A_HASH,
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    let owner_cap_id = storage_owner_cap_id(&mut ts, storage_id);
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);
    mint_ammo<StorageUnit>(&mut ts, storage_id, character_id, user_a());

    // Authorize extension
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        storage_unit.authorize_extension<SwapAuth>(&owner_cap);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        item =
            storage_unit.withdraw_item<SwapAuth>(
                &character,
                SwapAuth {},
                AMMO_TYPE_ID,
                ts.ctx(),
            );
        ts::return_shared(storage_unit);
        ts::return_shared(character);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        storage_unit.deposit_item<SwapAuth>(
            &character,
            item,
            SwapAuth {},
            ts.ctx(),
        );
        assert_eq!(storage_unit.item_quantity(owner_cap_id, AMMO_TYPE_ID), AMMO_QUANTITY);
        ts::return_shared(storage_unit);
        ts::return_shared(character);
    };
    ts::end(ts);
}

/// Test depositing and withdrawing items by owner
/// Scenario: Owner withdraws item and deposits it back using owner access
/// Expected: Items can be withdrawn and deposited successfully by owner
#[test]
fun test_deposit_and_withdraw_by_owner() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    let owner_cap_id = storage_owner_cap_id(&mut ts, storage_id);
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);
    mint_ammo<StorageUnit>(&mut ts, storage_id, character_id, user_a());

    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        item =
            storage_unit.withdraw_by_owner(
                &server_registry,
                &owner_cap,
                &character,
                AMMO_TYPE_ID,
                proof_bytes,
                &clock,
                ts.ctx(),
            );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_shared(character);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        storage_unit.deposit_by_owner(
            item,
            &server_registry,
            &owner_cap,
            &character,
            proof_bytes,
            &clock,
            ts.ctx(),
        );
        ts::return_shared(character);

        assert_eq!(storage_unit.item_quantity(owner_cap_id, AMMO_TYPE_ID), AMMO_QUANTITY);

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
    setup_nwn(&mut ts);
    let character_a_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let character_b_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);

    // Create User B's storage unit with lens
    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_b_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    let storage_owner_cap_id = storage_owner_cap_id(&mut ts, storage_id);
    online_storage_unit(&mut ts, user_b(), storage_id, nwn_id);

    // Mint lens for user B
    mint_lens<StorageUnit>(&mut ts, storage_id, character_b_id, user_b());

    // Create a character for user A to mint items into epehemeral inventory
    let character_owner_cap_id = character_owner_cap_id(&mut ts, user_a());

    // Mint Ammo for user A
    // minting ammo automatically creates a epehemeral inventory for user A
    mint_ammo<Character>(&mut ts, storage_id, character_a_id, user_a());

    // User B authorizes the swap extension for their storage to swap lens for ammo
    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap_b = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        storage_unit.authorize_extension<SwapAuth>(&owner_cap_b);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap_b);
    };

    // Before swap
    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);

        let used_capacity_a = (AMMO_QUANTITY as u64* AMMO_VOLUME);
        let used_capacity_b = (LENS_QUANTITY as u64* LENS_VOLUME);
        let inv_ref_a = storage_unit.inventory(character_owner_cap_id);
        let inv_ref_b = storage_unit.inventory(storage_owner_cap_id);

        assert_eq!(inv_ref_a.used_capacity(), used_capacity_a);
        assert_eq!(inv_ref_a.remaining_capacity(), MAX_CAPACITY - used_capacity_a);
        assert_eq!(inv_ref_b.used_capacity(), used_capacity_b);
        assert_eq!(inv_ref_b.remaining_capacity(), MAX_CAPACITY - used_capacity_b);

        assert_eq!(storage_unit.item_quantity(character_owner_cap_id, AMMO_TYPE_ID), AMMO_QUANTITY);
        assert!(!storage_unit.contains_item(character_owner_cap_id, LENS_TYPE_ID));
        assert_eq!(storage_unit.item_quantity(storage_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        assert!(!storage_unit.contains_item(storage_owner_cap_id, AMMO_TYPE_ID));

        ts::return_shared(storage_unit);
    };

    // user_a interacts with swap
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap_a = ts::take_from_sender<OwnerCap<Character>>(&ts);
        let character_a = ts::take_shared_by_id<Character>(&ts, character_a_id);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        swap_ammo_for_lens_extension(
            &mut storage_unit,
            &owner_cap_a,
            &character_a,
            &server_registry,
            proof_bytes,
            &clock,
            ts.ctx(),
        );
        ts::return_shared(character_a);

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap_a);
    };

    // Verify swap
    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        assert_eq!(storage_unit.item_quantity(character_owner_cap_id, LENS_TYPE_ID), LENS_QUANTITY);
        assert!(!storage_unit.contains_item(character_owner_cap_id, AMMO_TYPE_ID));

        assert_eq!(storage_unit.item_quantity(storage_owner_cap_id, AMMO_TYPE_ID), AMMO_QUANTITY);
        assert!(!storage_unit.contains_item(storage_owner_cap_id, LENS_TYPE_ID));

        ts::return_shared(storage_unit);
    };

    ts::end(ts);
}

/// Test unanchoring a storage unit
/// Scenario: User A anchors a storage unit, deposits items, unanchors
/// Exepected: On Unanchor, the attached inventories should be removed
/// items should be burned and the location should not be available
#[test]
fun test_unachor_storage_unit() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);

    // Create storage unit for User A
    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_b(), storage_id, nwn_id);

    mint_lens<StorageUnit>(&mut ts, storage_id, character_id, user_b());
    mint_lens<StorageUnit>(&mut ts, storage_id, character_id, user_b());
    mint_ammo<StorageUnit>(&mut ts, storage_id, character_id, user_b());
    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let inventory_keys = storage_unit.inventory_keys();
        assert_eq!(inventory_keys.length(), 1);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        storage_unit::unanchor(storage_unit, &mut nwn, &energy_config, &admin_cap);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

/// Test that authorizing extension without proper owner capability fails
/// Scenario: User B attempts to authorize extension for User A's storage unit using wrong OwnerCap
/// Expected: Transaction aborts with EAssemblyNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EAssemblyNotAuthorized)]
fun test_authorize_extension_fail_wrong_owner() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let character_id = create_character(&mut ts, user_b(), CHARACTER_A_ITEM_ID);

    let (storage_id, _) = create_storage_unit(
        &mut ts,
        character_id,
        LOCATION_A_HASH,
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );

    create_storage_unit(
        &mut ts,
        character_id,
        LOCATION_A_HASH,
        DUMMY_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );

    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);

        storage_unit.authorize_extension<SwapAuth>(&owner_cap);

        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Test that withdrawing via extension without authorization fails
/// Scenario: Attempt to withdraw item via extension without authorizing the extension type
/// Expected: Transaction aborts with EExtensionNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EExtensionNotAuthorized)]
fun test_withdraw_via_extension_fail_not_authorized() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        LOCATION_A_HASH,
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);
    mint_ammo<StorageUnit>(&mut ts, storage_id, character_id, user_a());

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let item = storage_unit.withdraw_item<SwapAuth>(
            &character,
            SwapAuth {},
            AMMO_TYPE_ID,
            ts.ctx(),
        );

        storage_unit.deposit_item<SwapAuth>(
            &character,
            item,
            SwapAuth {},
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
        ts::return_shared(character);
    };
    ts::end(ts);
}

/// Test that depositing via extension without authorization fails
/// Scenario: Attempt to deposit item via extension without authorizing the extension type
/// Expected: Transaction aborts with EExtensionNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EExtensionNotAuthorized)]
fun test_deposit_via_extension_fail_not_authorized() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);
    mint_ammo<StorageUnit>(&mut ts, storage_id, character_id, user_a());

    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        item =
            storage_unit.withdraw_by_owner(
                &server_registry,
                &owner_cap,
                &character,
                AMMO_TYPE_ID,
                proof_bytes,
                &clock,
                ts.ctx(),
            );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_shared(character);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        storage_unit.deposit_item<SwapAuth>(
            &character,
            item,
            SwapAuth {},
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
        ts::return_shared(character);
    };
    ts::end(ts);
}

/// Test that withdrawing by owner without proper owner capability fails
/// Scenario: User B attempts to withdraw items from User A's storage unit using wrong OwnerCap
/// Expected: Transaction aborts with EInventoryNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EInventoryNotAuthorized)]
fun test_withdraw_by_owner_fail_wrong_owner() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_a_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let character_b_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);

    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_a_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);
    mint_ammo<StorageUnit>(&mut ts, storage_id, character_a_id, user_a());

    create_storage_unit(
        &mut ts,
        character_b_id,
        LOCATION_A_HASH,
        DUMMY_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );

    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        let character_a = ts::take_shared_by_id<Character>(&ts, character_a_id);
        let item = storage_unit.withdraw_by_owner(
            &server_registry,
            &owner_cap,
            &character_a,
            AMMO_TYPE_ID,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        storage_unit.deposit_by_owner(
            item,
            &server_registry,
            &owner_cap,
            &character_a,
            proof_bytes,
            &clock,
            ts.ctx(),
        );
        ts::return_shared(character_a);

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Test that depositing by owner without proper owner capability fails
/// Scenario: User A withdraws item, then User B attempts to deposit it back using wrong OwnerCap
/// Expected: Transaction aborts with EInventoryNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EInventoryNotAuthorized)]
fun test_deposit_by_owner_fail_wrong_owner() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_a_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let character_b_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);

    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_a_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);
    mint_ammo<StorageUnit>(&mut ts, storage_id, character_a_id, user_a());

    // user_a withdraws item
    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        let character_a = ts::take_shared_by_id<Character>(&ts, character_a_id);
        item =
            storage_unit.withdraw_by_owner(
                &server_registry,
                &owner_cap,
                &character_a,
                AMMO_TYPE_ID,
                proof_bytes,
                &clock,
                ts.ctx(),
            );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_shared(character_a);
        ts::return_to_sender(&ts, owner_cap);
    };

    create_storage_unit(
        &mut ts,
        character_b_id,
        LOCATION_A_HASH,
        DUMMY_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );

    // User B attempts to deposit using wrong OwnerCap - should fail
    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let character_a = ts::take_shared_by_id<Character>(&ts, character_a_id);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        // This should fail with EAssemblyNotAuthorized
        storage_unit.deposit_by_owner(
            item,
            &server_registry,
            &owner_cap,
            &character_a,
            proof_bytes,
            &clock,
            ts.ctx(),
        );
        ts::return_shared(character_a);

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Test that swap fails when extension is not authorized
/// Scenario: Attempt to swap items via extension without authorizing the extension type
/// Expected: Transaction aborts with EExtensionNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EExtensionNotAuthorized)]
fun test_swap_fail_extension_not_authorized() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let character_b_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);

    // Create storage unit with lens
    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_id, nwn_id);
    mint_lens<StorageUnit>(&mut ts, storage_id, character_id, user_a());

    let _character_owner_cap_id = character_owner_cap_id(&mut ts, user_b());
    mint_ammo<Character>(&mut ts, storage_id, character_b_id, user_b());

    //Skipped authorisation

    // call swap
    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let owner_cap_b = ts::take_from_sender<OwnerCap<Character>>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        let character_b = ts::take_shared_by_id<Character>(&ts, character_b_id);
        swap_ammo_for_lens_extension(
            &mut storage_unit,
            &owner_cap_b,
            &character_b,
            &server_registry,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_shared(character_b);
        ts::return_to_sender(&ts, owner_cap_b);
    };
    ts::end(ts);
}

/// Test moving item from chain to game without proper owner capability fails
/// Scenario: User B attempts to move items chain to game from User A's storage unit using wrong OwnerCap
/// Expected: Transaction aborts with EInventoryNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EInventoryNotAuthorized)]
public fun chain_item_to_game_inventory_fail_unauthorized_owner() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_a_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let character_b_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);

    // Create User B's storage unit with lens
    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_b_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_b(), storage_id, nwn_id);

    // Mint lens for user B
    mint_lens<StorageUnit>(&mut ts, storage_id, character_b_id, user_b());

    let (user_a_storage_id, _) = create_storage_unit(
        &mut ts,
        character_a_id,
        LOCATION_A_HASH,
        DUMMY_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );

    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, user_a_storage_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);
        let character_b = ts::take_shared_by_id<Character>(&ts, character_b_id);
        storage_unit.chain_item_to_game_inventory_test(
            &server_registry,
            &owner_cap,
            &character_b,
            LENS_TYPE_ID,
            LENS_QUANTITY,
            proof_bytes,
            ts.ctx(),
        );
        ts::return_shared(character_b);

        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Test that minting items into offline inventory fails
/// Scenario: Attempt to mint items into storage unit that is not online
/// Expected: Transaction aborts with ENotOnline error
#[test]
#[expected_failure(abort_code = storage_unit::ENotOnline)]
fun mint_items_fail_inventory_offline() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    let (storage_unit_id, _) = create_storage_unit(
        &mut ts,
        character_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    mint_ammo<StorageUnit>(&mut ts, storage_unit_id, character_id, user_a());
    ts::end(ts);
}

/// Tests that bringing online without proper owner capability fails
/// Scenario: User B attempts to bring User A's assembly online using wrong OwnerCap
/// Expected: Transaction aborts with EAssemblyNotAuthorized error
#[test]
#[expected_failure(abort_code = storage_unit::EAssemblyNotAuthorized)]
fun online_fail_by_unauthorized_owner() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_a_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let character_b_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);

    // Create User A Storage unit
    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_a_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );

    // Bring NWN online using user_a (the owner)
    let clock = clock::create_for_testing(ts.ctx());
    ts::next_tx(&mut ts, user_a());
    let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        nwn.deposit_fuel_test(
            &admin_acl,
            &owner_cap,
            FUEL_TYPE_ID,
            FUEL_VOLUME,
            10,
            &clock,
            ts.ctx(),
        );
        ts::return_shared(admin_acl);
        ts::return_shared(nwn);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
    };
    ts::next_tx(&mut ts, user_a());
    {
        ts::return_to_sender(&ts, owner_cap);
    };

    // Create User B Storage unit (so user_b has their own OwnerCap<StorageUnit>)
    create_storage_unit(
        &mut ts,
        character_b_id,
        LOCATION_A_HASH,
        DUMMY_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );

    // User B tries to bring User A's storage unit online using their own OwnerCap
    // This should fail with EAssemblyNotAuthorized
    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        storage_unit::online(&mut storage_unit, &mut nwn, &energy_config, &owner_cap);
        ts::return_shared(storage_unit);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, owner_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}

/// Test taking offline without proper owner capability fails
/// Scenario: User B attempts to take User A's assembly offline using wrong OwnerCap
/// Expected: Transaction aborts with EAssemblyNotAuthorized error
#[test]
#[expected_failure]
fun offline_fail_by_unauthorized_owner() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_a_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let character_b_id = create_character(&mut ts, user_b(), CHARACTER_B_ITEM_ID);

    // Create User A Storage unit
    let (storage_a_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_a_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_a_id, nwn_id);

    // Create User B Storage unit
    create_storage_unit(
        &mut ts,
        character_b_id,
        test_helpers::get_verified_location_hash(),
        2343432432,
        5676576576,
    );

    // B tries to offline A's storage unit — this should fail due to missing authorization
    ts::next_tx(&mut ts, user_b());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        storage_unit.offline(&mut nwn, &energy_config, &owner_cap);
        ts::return_shared(storage_unit);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Test that depositing an item with a different tenant fails
/// Scenario: Create two storage units with different tenants, mint item in one, try to deposit in the other
/// Expected: Transaction aborts with ETenantMismatch error
#[test]
#[expected_failure(abort_code = storage_unit::ETenantMismatch)]
fun test_deposit_by_owner_fail_tenant_mismatch() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    let different_tenant = DIFFERENT_TENANT.to_string();
    let character_id_diff_tenant = create_character_with_tenant(
        &mut ts,
        user_a(),
        CHARACTER_A_ITEM_ID,
        different_tenant,
    );

    // Create storage unit B with different tenant
    let (storage_b_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id_diff_tenant,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID + 1,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_b_id, nwn_id);

    // Mint ammo in storage unit B tenant test
    mint_ammo<StorageUnit>(&mut ts, storage_b_id, character_id, user_a());

    // Withdraw item from storage unit B and deposit in different tenant
    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        item =
            storage_unit.withdraw_by_owner(
                &server_registry,
                &owner_cap,
                &character,
                AMMO_TYPE_ID,
                proof_bytes,
                &clock,
                ts.ctx(),
            );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_shared(character);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Create storage unit A with default tenant "TEST"
    let (storage_a_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_a_id, nwn_id);

    // Try to deposit item from storage unit B into storage unit A
    // This should fail with ETenantMismatch
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        storage_unit.deposit_by_owner(
            item,
            &server_registry,
            &owner_cap,
            &character,
            proof_bytes,
            &clock,
            ts.ctx(),
        );
        ts::return_shared(character);

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

/// Test that depositing an item via extension with a different tenant fails
/// Scenario: Create two storage units with different tenants, mint item in one, authorize extension, try to deposit via extension in the other
/// Expected: Transaction aborts with ETenantMismatch error
#[test]
#[expected_failure(abort_code = storage_unit::ETenantMismatch)]
fun test_deposit_via_extension_fail_tenant_mismatch() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);
    let different_tenant = DIFFERENT_TENANT.to_string();

    let character_id_diff_tenant = create_character_with_tenant(
        &mut ts,
        user_a(),
        CHARACTER_A_ITEM_ID,
        different_tenant,
    );

    // Create storage unit B with different tenant
    let (storage_b_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id_diff_tenant,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID + 1,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_b_id, nwn_id);

    // Mint ammo in storage unit B
    mint_ammo<StorageUnit>(&mut ts, storage_b_id, character_id, user_a());

    // Withdraw item from storage unit B
    ts::next_tx(&mut ts, user_a());
    let item: Item;
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_b_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let clock = clock::create_for_testing(ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);

        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        item =
            storage_unit.withdraw_by_owner(
                &server_registry,
                &owner_cap,
                &character,
                AMMO_TYPE_ID,
                proof_bytes,
                &clock,
                ts.ctx(),
            );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
        ts::return_shared(character);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Create storage unit A with default tenant
    let (storage_a_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );
    online_storage_unit(&mut ts, user_a(), storage_a_id, nwn_id);

    // Authorize extension for storage unit A
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        storage_unit.authorize_extension<SwapAuth>(&owner_cap);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Try to deposit item from storage unit B into storage unit A via extension
    // This should fail with ETenantMismatch
    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_a_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        storage_unit.deposit_item<SwapAuth>(
            &character,
            item,
            SwapAuth {},
            ts.ctx(),
        );
        ts::return_shared(storage_unit);
        ts::return_shared(character);
    };
    ts::end(ts);
}

/// Test that game_to_chain operation fails when network node is not burning and not online
/// Scenario: Network node goes offline (not burning, not online), which brings storage unit offline
/// Expected: Transaction aborts with ENotOnline error when trying to mint items
#[test]
#[expected_failure(abort_code = storage_unit::ENotOnline)]
fun test_game_to_chain_fail_network_node_offline() {
    let mut ts = ts::begin(governor());
    setup_nwn(&mut ts);
    let character_id = create_character(&mut ts, user_a(), CHARACTER_A_ITEM_ID);

    let (storage_id, nwn_id) = create_storage_unit(
        &mut ts,
        character_id,
        test_helpers::get_verified_location_hash(),
        STORAGE_A_ITEM_ID,
        STORAGE_A_TYPE_ID,
    );

    let clock = clock::create_for_testing(ts.ctx());
    ts::next_tx(&mut ts, user_a());
    let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        nwn.deposit_fuel_test(
            &admin_acl,
            &owner_cap,
            FUEL_TYPE_ID,
            FUEL_VOLUME,
            10,
            &clock,
            ts.ctx(),
        );
        ts::return_shared(admin_acl);
        ts::return_shared(nwn);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.online(&owner_cap, &clock);
        ts::return_shared(nwn);
    };
    ts::next_tx(&mut ts, user_a());
    {
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        storage_unit.online(&mut nwn, &energy_config, &owner_cap);
        ts::return_shared(storage_unit);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Take network node offline (stops burning, not online)
    // This also brings the storage unit offline through the hot potato mechanism
    ts::next_tx(&mut ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let owner_cap = ts::take_from_sender<OwnerCap<NetworkNode>>(&ts);
        let fuel_config = ts::take_shared<FuelConfig>(&ts);
        let mut offline_assemblies = nwn.offline(&fuel_config, &owner_cap, &clock);

        // Process the storage unit to bring it offline
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        offline_assemblies =
            storage_unit.offline_connected_storage_unit(
                offline_assemblies,
                &mut nwn,
                &energy_config,
            );
        network_node::destroy_offline_assemblies(offline_assemblies);

        ts::return_shared(storage_unit);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_shared(fuel_config);
        ts::return_to_sender(&ts, owner_cap);
    };

    // Verify network node is offline and not burning
    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert!(!network_node::is_network_node_online(&nwn), 1);
        assert!(!nwn.fuel().is_burning(), 2);
        ts::return_shared(nwn);
    };

    // Try to call game_item_to_chain_inventory_test when network node is offline and not burning
    // This should fail because the storage unit is offline (brought offline when network node went offline)
    ts::next_tx(&mut ts, user_a());
    let owner_cap = {
        let owner_cap = ts::take_from_sender<OwnerCap<StorageUnit>>(&ts);
        owner_cap
    };
    ts::next_tx(&mut ts, admin());
    {
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(&ts, storage_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);

        // This should fail because storage unit is offline (network node is offline and not burning)
        storage_unit.game_item_to_chain_inventory_test<StorageUnit>(
            &admin_acl,
            &owner_cap,
            &character,
            AMMO_ITEM_ID,
            AMMO_TYPE_ID,
            AMMO_VOLUME,
            AMMO_QUANTITY,
            ts.ctx(),
        );
        ts::return_shared(admin_acl);
        ts::return_shared(storage_unit);
        ts::return_shared(character);
        ts::return_to_sender(&ts, owner_cap);
    };

    clock.destroy_for_testing();
    ts::end(ts);
}
