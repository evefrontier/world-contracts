/// This module implements the logic of inventory operations like depositing items, withdrawing items and transferring items between inventories
///
/// Bridging items from game to chain and back
/// - The game is the “trusted bridge” for bringing items from the game to the chain
/// - To bridge an item from game to chain, the game server will call an authenticated onchain function to mint the item into an onchain inventory
/// - To bridge an item from chain to game, the chain emits an event and burns the onchain item. The game server listens to the event to create the item in the game.
/// - `game to chain`(mint) action is restricted by admin capability and `chain to game`(burn) action is restricted by a proximity proof
module world::inventory;

use sui::{event, vec_map::{Self, VecMap}};
use world::{
    authority::{Self, AdminCap, OwnerCap},
    location::{Self, Location},
    status::{Self, AssemblyStatus}
};

// === Errors ===
#[error(code = 0)]
const ETypeIdEmpty: vector<u8> = b"Type ID cannot be empty";
#[error(code = 1)]
const EItemIdEmpty: vector<u8> = b"Item ID cannot be empty";
#[error(code = 2)]
const EInventoryInvalidCapacity: vector<u8> = b"Inventory Capacity cannot be 0";
#[error(code = 3)]
const EInventoryInSufficientCapacity: vector<u8> = b"No sufficient capacity in the inventory";
#[error(code = 4)]
const EInventoryAccessNotAuthorized: vector<u8> = b"Inventory access not authorized";
#[error(code = 5)]
const EItemDoesNotExist: vector<u8> = b"Item is not created on-chain";
#[error(code = 6)]
const ENotOnline: vector<u8> = b"Inventory attached source is not online";
#[error(code = 7)]
const EInsufficientQuantity: vector<u8> = b"Insufficient quantity in inventory";

// === Structs ===

// The inventory struct takes the same id as it assembly which its attached to, so it does not have a key
// Note: Gas cost is high, lookup and insert complexity for VecMap is o(n). alternative is to use Table and seperate Vector
// But Ideal for this use case
public struct Inventory has store {
    id: ID,
    max_capacity: u64,
    used_capacity: u64,
    items: VecMap<u64, Item>,
}

// TODO: Use Sui's `Coin<T>` and `Balance<T>` for stackability

// Item has a key as its minted on-chain and can be transferred from one inventory to another
// It has store ability as it needs to wrapped in a parent. Item should always have a parent eg: Inventory , ship etc
public struct Item has key, store {
    id: UID,
    type_id: u64,
    item_id: u64,
    volume: u64,
    quantity: u64,
    location: Location,
}

// === Events ===
public struct ItemMintedEvent has copy, drop {
    inventory_id: ID,
    item_uid: ID,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u64,
}

public struct ItemBurnedEvent has copy, drop {
    inventory_id: ID,
    item_id: u64,
    quantity: u64,
}

public struct ItemAmountChangedEvent has copy, drop {
    inventory_id: ID,
    item_id: u64,
    old_quantity: u64,
    new_quantity: u64,
}

public struct ItemDepositedEvent has copy, drop {
    inventory_id: ID,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u64,
}

public struct ItemWithdrawnEvent has copy, drop {
    inventory_id: ID,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u64,
}

// === Public Functions ===
// TODO: Transfer items between two inventories by providing proximity proofs

/// Burns items from on-chain inventory (Chain → Game bridge)
/// Emits ItemBurnedEvent for game server to create item in-game
/// Deletes Item object if param quantity = existing quantity, otherwise reduces quantity
public fun burn_items_from_inventory(
    assembly_status: &AssemblyStatus,
    inventory: &mut Inventory,
    item_id: u64,
    quantity: u64,
    owner_cap: &OwnerCap,
    location_hash: vector<u8>,
    proximity_proof: vector<u8>,
) {
    assert!(authority::is_authorized(owner_cap, inventory.id), EInventoryAccessNotAuthorized);
    assert!(vec_map::contains(&inventory.items, &item_id), EItemDoesNotExist);
    assert!(assembly_status.is_online(), ENotOnline);

    //TODO: Verify proximity

    let item_ref = vec_map::get(&inventory.items, &item_id);
    assert!(item_ref.quantity >= quantity, EInsufficientQuantity);
    let current_amount = item_ref.quantity;

    // If burning all items, remove and delete the Item object
    if (current_amount == quantity) {
        let (_, removed_item) = vec_map::remove(&mut inventory.items, &item_id);
        let volume_freed = calculate_volume(removed_item.volume, removed_item.quantity);
        inventory.used_capacity = inventory.used_capacity - volume_freed;

        let Item { id, type_id: _, item_id: _, volume: _, quantity: _, location } = removed_item;
        location.remove_location();
        object::delete(id);
    } else {
        reduce_item_amount(inventory, item_id, quantity);
    };

    // Emit event for game bridge to listen
    event::emit(ItemBurnedEvent {
        inventory_id: inventory.id,
        item_id,
        quantity,
    });
}

// === Admin Functions ===

/// Mints items into inventory (Game → Chain bridge)
/// Admin-only function for trusted game server
/// Creates new item or adds to existing if item_id already exists
public fun mint_items_in_inventory(
    inventory: &mut Inventory,
    assembly_status: &AssemblyStatus,
    location_hash: vector<u8>,
    admin_cap: &AdminCap,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u64,
    ctx: &mut TxContext,
) {
    assert!(item_id != 0, EItemIdEmpty);
    assert!(type_id != 0, ETypeIdEmpty);
    assert!(assembly_status.is_online(), ENotOnline);

    if (vec_map::contains(&inventory.items, &item_id)) {
        add_items(inventory, item_id, quantity);
    } else {
        let item_uid = object::new(ctx);
        let item_uid_value = object::uid_to_inner(&item_uid);
        let item = Item {
            id: item_uid,
            type_id,
            item_id,
            volume,
            quantity,
            location: location::attach_location(admin_cap, item_uid_value, location_hash),
        };

        let req_capacity = calculate_volume(volume, quantity);
        let remaining_capacity = inventory.max_capacity - inventory.used_capacity;
        assert!(req_capacity <= remaining_capacity, EInventoryInSufficientCapacity);

        inventory.used_capacity = inventory.used_capacity + req_capacity;
        inventory.items.insert(item_id, item);

        event::emit(ItemMintedEvent {
            inventory_id: inventory.id,
            item_uid: item_uid_value,
            item_id: item_id,
            type_id: type_id,
            volume: volume,
            quantity: quantity,
        });
    }
}

// === Package Functions ===
public(package) fun create(_: &AdminCap, max_capacity: u64, inventory_id: ID): Inventory {
    assert!(max_capacity != 0, EInventoryInvalidCapacity);
    Inventory {
        id: inventory_id,
        max_capacity,
        used_capacity: 0,
        items: vec_map::empty(),
    }
}

// Does this need to be online ?
// A wrapper function to transfer between inventories
public(package) fun deposit_item(inventory: &mut Inventory, item: Item) {
    let req_capacity = calculate_volume(item.volume, item.quantity);
    let remaining_capacity = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining_capacity, EInventoryInSufficientCapacity);

    inventory.used_capacity = inventory.used_capacity + req_capacity;

    event::emit(ItemDepositedEvent {
        inventory_id: inventory.id,
        item_id: item.item_id,
        type_id: item.type_id,
        volume: item.volume,
        quantity: item.quantity,
    });
    inventory.items.insert(item.item_id, item);
}

// A wrapper function to transfer between inventories
/// Withdraws item and returns the whole Item
public(package) fun withdraw_item(inventory: &mut Inventory, item_id: u64): Item {
    assert!(vec_map::contains(&inventory.items, &item_id), EItemDoesNotExist);

    let (_, item) = vec_map::remove(&mut inventory.items, &item_id);
    let volume_freed = calculate_volume(item.volume, item.quantity);
    inventory.used_capacity = inventory.used_capacity - volume_freed;

    event::emit(ItemWithdrawnEvent {
        inventory_id: inventory.id,
        item_id: item.item_id,
        type_id: item.type_id,
        volume: item.volume,
        quantity: item.quantity,
    });
    item
}

// FUTURE: transfer items between inventory. eg: inventory to inventory on-chain
// This needs location proof and distance to enforce digital physics
// public fun transfer_items() {}

// === Private Functions ===

/// Adds item quantity to existing item in inventory
fun add_items(inventory: &mut Inventory, item_id: u64, quantity: u64) {
    let item = vec_map::get_mut(&mut inventory.items, &item_id);
    let req_capacity = calculate_volume(item.volume, quantity);

    let remaining_capacity = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining_capacity, EInventoryInSufficientCapacity);

    event::emit(ItemAmountChangedEvent {
        inventory_id: inventory.id,
        item_id: item_id,
        old_quantity: item.quantity,
        new_quantity: item.quantity + quantity,
    });

    item.quantity = item.quantity + quantity;
    inventory.used_capacity = inventory.used_capacity + req_capacity;
}

/// Reduces item quantity in inventory
fun reduce_item_amount(inventory: &mut Inventory, item_id: u64, quantity: u64) {
    let item = vec_map::get_mut(&mut inventory.items, &item_id);
    let volume_freed = calculate_volume(item.volume, quantity);

    let old_amount = item.quantity;
    item.quantity = item.quantity - quantity;
    inventory.used_capacity = inventory.used_capacity - volume_freed;

    event::emit(ItemAmountChangedEvent {
        inventory_id: inventory.id,
        item_id,
        old_quantity: old_amount,
        new_quantity: item.quantity,
    });
}

fun calculate_volume(volume: u64, quantity: u64): u64 {
    volume * quantity
}

// === Test Functions ===
#[test_only]
public fun max_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity
}

#[test_only]
public fun used_capacity(inventory: &Inventory): u64 {
    inventory.used_capacity
}

#[test_only]
public fun get_item_amount(inventory: &Inventory, item_id: u64): u64 {
    vec_map::get(&inventory.items, &item_id).quantity
}
