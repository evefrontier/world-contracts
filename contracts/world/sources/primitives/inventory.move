/// This module implements the logic of inventory operations such as depositing, withdrawing and transferring items between inventories.
///
/// Bridging items from game to chain and back:
/// - The game is the “trusted bridge” for bringing items from the game to the chain.
/// - To bridge an item from game to chain, the game server will call an authenticated on-chain function to mint the item into an on-chain inventory.
/// - To bridge an item from chain to game, the chain emits an event and burns the on-chain item. The game server listens to the event to create the item in the game.
/// - The `game to chain`(mint) action is restricted by an admin capability and the `chain to game`(burn) action is restricted by a proximity proof.
module world::inventory;

use std::string::String;
use sui::{clock::Clock, event, vec_map::{Self, VecMap}};
use world::{
    access::ServerAddressRegistry,
    character::Character,
    in_game_id::TenantItemId,
    location::{Self, Location}
};

// === Errors ===
#[error(code = 0)]
const ETypeIdEmpty: vector<u8> = b"Type ID cannot be empty";
#[error(code = 1)]
const EInventoryInvalidCapacity: vector<u8> = b"Inventory Capacity cannot be 0";
#[error(code = 2)]
const EInventoryInsufficientCapacity: vector<u8> = b"Insufficient capacity in the inventory";
#[error(code = 3)]
const EItemDoesNotExist: vector<u8> = b"Item not found";
#[error(code = 4)]
const EInventoryInsufficientQuantity: vector<u8> = b"Insufficient quantity in inventory";

// === Structs ===

// The inventory struct uses the id of the assembly it is attached to, so it does not have a key.
// Note: Gas cost is high, lookup and insert complexity for VecMap is o(n). The alternative is to use a Table and a separate Vector.
// However it is ideal for this use case.
public struct Inventory has store {
    max_capacity: u64,
    used_capacity: u64,
    items: VecMap<u64, Item>,
}

// TODO: Use Sui's `Coin<T>` and `Balance<T>` for stackability
// TODO: Move item as its own module
// Item has a key as its minted on-chain and can be transferred from one inventory to another.
// It has store ability as it needs to be wrapped in a parent. Item should always have a parent eg: Inventory, ship etc.
public struct Item has key, store {
    id: UID,
    tenant: String,
    type_id: u64,
    item_id: u64,
    volume: u64,
    quantity: u32,
    location: Location,
}

// === Events ===
public struct ItemMintedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemBurnedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemDepositedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemWithdrawnEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

public struct ItemDestroyedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    item_id: u64,
    type_id: u64,
    quantity: u32,
}

// === View Functions ===
public fun tenant(item: &Item): String {
    item.tenant
}

public fun contains_item(inventory: &Inventory, type_id: u64): bool {
    inventory.items.contains(&type_id)
}

public fun get_item_location_hash(item: &Item): vector<u8> {
    item.location.hash()
}

public fun max_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity
}

// === Package Functions ===

public(package) fun create(max_capacity: u64): Inventory {
    assert!(max_capacity != 0, EInventoryInvalidCapacity);

    Inventory {
        max_capacity,
        used_capacity: 0,
        items: vec_map::empty(),
    }
}

/// Mints items into inventory (Game → Chain bridge)
/// Admin-only function for trusted game server
/// Creates new item or adds to existing if type_id already exists
public(package) fun mint_items(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    tenant: String,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(type_id != 0, ETypeIdEmpty);

    if (inventory.items.contains(&type_id)) {
        increase_item_quantity(inventory, assembly_id, assembly_key, character, type_id, quantity);
    } else {
        let type_uid = object::new(ctx);
        let item = Item {
            id: type_uid,
            tenant,
            type_id,
            item_id,
            volume,
            quantity,
            location: location::attach(location_hash),
        };

        let req_capacity = calculate_volume(volume, quantity);
        let remaining_capacity = inventory.max_capacity - inventory.used_capacity;
        assert!(req_capacity <= remaining_capacity, EInventoryInsufficientCapacity);

        inventory.used_capacity = inventory.used_capacity + req_capacity;
        inventory.items.insert(type_id, item);

        event::emit(ItemMintedEvent {
            assembly_id,
            assembly_key,
            character_id: character.id(),
            character_key: character.key(),
            item_id,
            type_id,
            quantity,
        });
    }
}

public(package) fun burn_items_with_proof(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    server_registry: &ServerAddressRegistry,
    location: &Location,
    location_proof: vector<u8>,
    type_id: u64,
    quantity: u32,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    location::verify_proximity_proof_from_bytes(
        server_registry,
        location,
        location_proof,
        clock,
        ctx,
    );
    burn_items(inventory, assembly_id, assembly_key, character, type_id, quantity);
}

// A wrapper function to transfer between inventories
public(package) fun deposit_item(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    item: Item,
) {
    let req_capacity = calculate_volume(item.volume, item.quantity);
    let remaining_capacity = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining_capacity, EInventoryInsufficientCapacity);

    inventory.used_capacity = inventory.used_capacity + req_capacity;

    event::emit(ItemDepositedEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id: item.item_id,
        type_id: item.type_id,
        quantity: item.quantity,
    });
    inventory.items.insert(item.type_id, item);
}

// A wrapper function to transfer between inventories
/// Withdraws the item with the specified type_id and returns the whole Item.
public(package) fun withdraw_item(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
): Item {
    assert!(inventory.items.contains(&type_id), EItemDoesNotExist);

    let (_, item) = inventory.items.remove(&type_id);
    let volume_freed = calculate_volume(item.volume, item.quantity);
    inventory.used_capacity = inventory.used_capacity - volume_freed;

    event::emit(ItemWithdrawnEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id: item.item_id,
        type_id: item.type_id,
        quantity: item.quantity,
    });
    item
}

public(package) fun delete(inventory: Inventory, assembly_id: ID, assembly_key: TenantItemId) {
    let Inventory {
        mut items,
        ..,
    } = inventory;

    // Burn the items one by one
    while (!items.is_empty()) {
        let (_, item) = items.pop();
        let Item { id, item_id, type_id, quantity, location, .. } = item;

        event::emit(ItemDestroyedEvent {
            assembly_id,
            assembly_key,
            item_id,
            type_id,
            quantity,
        });

        location.remove();
        id.delete();
    };
    items.destroy_empty();
}

// FUTURE: transfer items between inventory, eg: inventory to inventory on-chain.
// This needs location proof and distance to enforce digital physics.
// public fun transfer_items() {}

// === Private Functions ===

/// Burns items from on-chain inventory (Chain → Game bridge)
/// Emits ItemBurnedEvent for game server to create item in-game
/// Deletes Item object if param quantity = existing quantity, otherwise reduces quantity
fun burn_items(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
    quantity: u32,
) {
    assert!(inventory.items.contains(&type_id), EItemDoesNotExist);

    let should_remove = {
        let item = &mut inventory.items[&type_id];
        assert!(item.quantity >= quantity, EInventoryInsufficientQuantity);

        if (item.quantity == quantity) {
            true
        } else {
            // Optimization: Handle partial burn here directly to avoid another lookup
            let volume_freed = calculate_volume(item.volume, quantity);

            item.quantity = item.quantity - quantity;
            inventory.used_capacity = inventory.used_capacity - volume_freed;

            event::emit(ItemBurnedEvent {
                assembly_id,
                assembly_key,
                character_id: character.id(),
                character_key: character.key(),
                item_id: item.item_id,
                type_id,
                quantity: quantity,
            });
            false
        }
    };

    if (should_remove) {
        let (_, removed_item) = inventory.items.remove(&type_id);
        let volume_freed = calculate_volume(removed_item.volume, removed_item.quantity);
        inventory.used_capacity = inventory.used_capacity - volume_freed;

        destroy_item(removed_item, character, assembly_id, assembly_key);
    };
}

fun destroy_item(
    item: Item,
    character: &Character,
    inventory_assembly_id: ID,
    inventory_assembly_key: TenantItemId,
) {
    let Item { id, item_id, type_id, quantity, location, .. } = item;

    event::emit(ItemBurnedEvent {
        assembly_id: inventory_assembly_id,
        assembly_key: inventory_assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id,
        type_id,
        quantity,
    });

    location.remove();
    id.delete();
}

/// Increases the quantity value of an existing item in the specified inventory.
fun increase_item_quantity(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
    quantity: u32,
) {
    let item = &mut inventory.items[&type_id];
    let req_capacity = calculate_volume(item.volume, quantity);

    let remaining_capacity = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining_capacity, EInventoryInsufficientCapacity);

    event::emit(ItemMintedEvent {
        assembly_id,
        assembly_key,
        character_id: character.id(),
        character_key: character.key(),
        item_id: item.item_id,
        type_id,
        quantity,
    });

    item.quantity = item.quantity + quantity;
    inventory.used_capacity = inventory.used_capacity + req_capacity;
}

fun calculate_volume(volume: u64, quantity: u32): u64 {
    volume * (quantity as u64)
}

// === Test Functions ===
#[test_only]
public fun remaining_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity - inventory.used_capacity
}

#[test_only]
public fun used_capacity(inventory: &Inventory): u64 {
    inventory.used_capacity
}

#[test_only]
public fun item_quantity(inventory: &Inventory, type_id: u64): u32 {
    inventory.items[&type_id].quantity
}

#[test_only]
public fun item_location(inventory: &Inventory, type_id: u64): vector<u8> {
    let item = &inventory.items[&type_id];
    location::hash(&item.location)
}

#[test_only]
public fun inventory_item_length(inventory: &Inventory): u64 {
    inventory.items.length()
}

#[test_only]
public fun burn_items_test(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    type_id: u64,
    quantity: u32,
) {
    burn_items(inventory, assembly_id, assembly_key, character, type_id, quantity);
}

// Mocking without deadline
#[test_only]
public fun burn_items_with_proof_test(
    inventory: &mut Inventory,
    assembly_id: ID,
    assembly_key: TenantItemId,
    character: &Character,
    server_registry: &ServerAddressRegistry,
    location: &Location,
    location_proof: vector<u8>,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
) {
    location::verify_proximity_proof_from_bytes_without_deadline(
        server_registry,
        location,
        location_proof,
        ctx,
    );
    burn_items(inventory, assembly_id, assembly_key, character, type_id, quantity);
}
