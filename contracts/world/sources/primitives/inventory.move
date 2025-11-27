/// This module implements the logic of inventory operations such as depositing, withdrawing and transferring items between inventories.
///
/// Bridging items from game to chain and back:
/// - The game is the “trusted bridge” for bringing items from the game to the chain.
/// - To bridge an item from game to chain, the game server will call an authenticated on-chain function to mint the item into an on-chain inventory.
/// - To bridge an item from chain to game, the chain emits an event and burns the on-chain item. The game server listens to the event to create the item in the game.
/// - The `game to chain`(mint) action is restricted by an admin capability and the `chain to game`(burn) action is restricted by a proximity proof.
module world::inventory;

use sui::{clock::Clock, event, vec_map::{Self, VecMap}};
use world::{
    authority::{Self, AdminCap, OwnerCap, ServerAddressRegistry},
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
const EInventoryInsufficientCapacity: vector<u8> = b"Insufficient capacity in the inventory";
#[error(code = 4)]
const EInventoryAccessNotAuthorized: vector<u8> = b"Inventory access not authorized";
#[error(code = 5)]
const EItemDoesNotExist: vector<u8> = b"Item not found";
#[error(code = 6)]
const ENotOnline: vector<u8> = b"Inventory attached source is not online";
#[error(code = 7)]
const EInventoryInsufficientQuantity: vector<u8> = b"Insufficient quantity in inventory";
#[error(code = 8)]
const EInventoryAssemblyMismatch: vector<u8> =
    b"Inventory and assembly status do not belong to the same assembly";

// === Structs ===

// The inventory struct uses the id of the assembly it is attached to, so it does not have a key.
// Note: Gas cost is high, lookup and insert complexity for VecMap is o(n). The alternative is to use a Table and a separate Vector.
// However it is ideal for this use case.
public struct Inventory has store {
    id: ID,
    max_capacity: u64,
    used_capacity: u64,
    items: VecMap<u64, Item>,
}

// TODO: Use Sui's `Coin<T>` and `Balance<T>` for stackability

// Item has a key as its minted on-chain and can be transferred from one inventory to another.
// It has store ability as it needs to be wrapped in a parent. Item should always have a parent eg: Inventory, ship etc.
public struct Item has key, store {
    id: UID,
    type_id: u64,
    item_id: u64,
    volume: u64,
    quantity: u32,
    location: Location,
}

// === Events ===
public struct ItemMintedEvent has copy, drop {
    inventory_id: ID,
    item_uid: ID,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
}

public struct ItemBurnedEvent has copy, drop {
    inventory_id: ID,
    item_id: u64,
    quantity: u32,
}

public struct ItemQuantityChangedEvent has copy, drop {
    inventory_id: ID,
    item_id: u64,
    old_quantity: u32,
    new_quantity: u32,
}

public struct ItemDepositedEvent has copy, drop {
    inventory_id: ID,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
}

public struct ItemWithdrawnEvent has copy, drop {
    inventory_id: ID,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
}

// === Public Functions ===

public fun burn_items_with_proof(
    inventory: &mut Inventory,
    assembly_status: &AssemblyStatus,
    location: &Location,
    owner_cap: &OwnerCap,
    item_id: u64,
    quantity: u32,
    server_registry: &ServerAddressRegistry,
    location_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    location::verify_proximity_proof_from_bytes(
        location,
        location_proof,
        server_registry,
        clock,
        ctx,
    );
    burn_items(inventory, assembly_status, owner_cap, item_id, quantity);
}

// === View Functions ===

public fun contains_item(inventory: &Inventory, item_id: u64): bool {
    inventory.items.contains(&item_id)
}

public fun get_item_location_hash(item: &Item): vector<u8> {
    item.location.hash()
}

// === Admin Functions ===

/// Mints items into inventory (Game → Chain bridge)
/// Admin-only function for trusted game server
/// Creates new item or adds to existing if item_id already exists
public fun mint_items(
    inventory: &mut Inventory,
    assembly_status: &AssemblyStatus,
    admin_cap: &AdminCap,
    item_id: u64,
    type_id: u64,
    volume: u64,
    quantity: u32,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(inventory.id == status::assembly_id(assembly_status), EInventoryAssemblyMismatch);
    assert!(item_id != 0, EItemIdEmpty);
    assert!(type_id != 0, ETypeIdEmpty);
    assert!(assembly_status.is_online(), ENotOnline);

    if (inventory.items.contains(&item_id)) {
        increase_item_quantity(inventory, item_id, quantity);
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
        assert!(req_capacity <= remaining_capacity, EInventoryInsufficientCapacity);

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
    assert!(req_capacity <= remaining_capacity, EInventoryInsufficientCapacity);

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
/// Withdraws the item with the specified item_id and returns the whole Item.
public(package) fun withdraw_item(inventory: &mut Inventory, item_id: u64): Item {
    assert!(inventory.items.contains(&item_id), EItemDoesNotExist);

    let (_, item) = inventory.items.remove(&item_id);
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

// FUTURE: transfer items between inventory, eg: inventory to inventory on-chain.
// This needs location proof and distance to enforce digital physics.
// public fun transfer_items() {}

// === Private Functions ===

// Note: Shouldn't this be admin capped ?
// Will it by default mint to ship/character inventory ?
/// Burns items from on-chain inventory (Chain → Game bridge)
/// Emits ItemBurnedEvent for game server to create item in-game
/// Deletes Item object if param quantity = existing quantity, otherwise reduces quantity
fun burn_items(
    inventory: &mut Inventory,
    assembly_status: &AssemblyStatus,
    owner_cap: &OwnerCap,
    item_id: u64,
    quantity: u32,
) {
    assert!(inventory.id == status::assembly_id(assembly_status), EInventoryAssemblyMismatch);
    assert!(authority::is_authorized(owner_cap, inventory.id), EInventoryAccessNotAuthorized);
    assert!(vec_map::contains(&inventory.items, &item_id), EItemDoesNotExist);
    assert!(assembly_status.is_online(), ENotOnline);

    let item_ref = vec_map::get(&inventory.items, &item_id);
    assert!(item_ref.quantity >= quantity, EInventoryInsufficientQuantity);
    let current_quantity = item_ref.quantity;

    // If burning all items, remove and delete the Item object
    if (current_quantity == quantity) {
        let (_, removed_item) = vec_map::remove(&mut inventory.items, &item_id);
        let volume_freed = calculate_volume(removed_item.volume, removed_item.quantity);
        inventory.used_capacity = inventory.used_capacity - volume_freed;

        let Item { id, type_id: _, item_id: _, volume: _, quantity: _, location } = removed_item;
        location.remove_location();
        object::delete(id);

        // Emit event for game bridge to listen
        event::emit(ItemBurnedEvent {
            inventory_id: inventory.id,
            item_id,
            quantity,
        });
    } else {
        reduce_item_quantity(inventory, item_id, quantity);
    };
}

/// Increases the quantity value of an existing item in the specified inventory.
fun increase_item_quantity(inventory: &mut Inventory, item_id: u64, quantity: u32) {
    let item = &mut inventory.items[&item_id];
    let req_capacity = calculate_volume(item.volume, quantity);

    let remaining_capacity = inventory.max_capacity - inventory.used_capacity;
    assert!(req_capacity <= remaining_capacity, EInventoryInsufficientCapacity);

    event::emit(ItemQuantityChangedEvent {
        inventory_id: inventory.id,
        item_id: item_id,
        old_quantity: item.quantity,
        new_quantity: item.quantity + quantity,
    });

    item.quantity = item.quantity + quantity;
    inventory.used_capacity = inventory.used_capacity + req_capacity;
}

/// Reduces item quantity value  of an existing item in the specified inventory.
fun reduce_item_quantity(inventory: &mut Inventory, item_id: u64, quantity: u32) {
    let item = &mut inventory.items[&item_id];
    let volume_freed = calculate_volume(item.volume, quantity);

    let old_quantity = item.quantity;
    item.quantity = item.quantity - quantity;
    inventory.used_capacity = inventory.used_capacity - volume_freed;

    event::emit(ItemQuantityChangedEvent {
        inventory_id: inventory.id,
        item_id,
        old_quantity: old_quantity,
        new_quantity: item.quantity,
    });
}

fun calculate_volume(volume: u64, quantity: u32): u64 {
    volume * (quantity as u64)
}

// === Test Functions ===
#[test_only]
public fun max_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity
}

#[test_only]
public fun remaining_capacity(inventory: &Inventory): u64 {
    inventory.max_capacity - inventory.used_capacity
}

#[test_only]
public fun used_capacity(inventory: &Inventory): u64 {
    inventory.used_capacity
}

#[test_only]
public fun item_quantity(inventory: &Inventory, item_id: u64): u32 {
    inventory.items[&item_id].quantity
}

#[test_only]
public fun item_location(inventory: &Inventory, item_id: u64): vector<u8> {
    let item = &inventory.items[&item_id];
    location::hash(&item.location)
}

#[test_only]
public fun inventory_item_length(inventory: &Inventory): u64 {
    inventory.items.length()
}

#[test_only]
public fun burn_items_test(
    inventory: &mut Inventory,
    assembly_status: &AssemblyStatus,
    owner_cap: &OwnerCap,
    item_id: u64,
    quantity: u32,
) {
    burn_items(inventory, assembly_status, owner_cap, item_id, quantity);
}

// Mocking without deadline
#[test_only]
public fun burn_items_with_proof_test(
    inventory: &mut Inventory,
    assembly_status: &AssemblyStatus,
    location: &Location,
    owner_cap: &OwnerCap,
    item_id: u64,
    quantity: u32,
    server_registry: &ServerAddressRegistry,
    location_proof: vector<u8>,
    ctx: &mut TxContext,
) {
    location::verify_proximity_proof_from_bytes_without_deadline(
        location,
        location_proof,
        server_registry,
        ctx,
    );
    burn_items(inventory, assembly_status, owner_cap, item_id, quantity);
}
