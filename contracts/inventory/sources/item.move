/// Fungible item foundation for the inventory module.
///
/// `Item` is a standalone object created on withdraw and consumed on deposit;
/// `ItemBag` is at-rest balances keyed by `type_id`. Items are fungible: balances
/// stack exactly by `type_id`.
///
/// TODO: `volume` (and mass) are entity metadata to be added later. Move them
/// into a dedicated metadata module (admin-maintained) and have capacity math
/// read volume from there instead of carrying it on each `Item`.
module inventory::item;

use core::entity_key::{Self, EntityKey};
use std::string::String;
use sui::{event, linked_table::{Self, LinkedTable}};

// === Errors ===

#[error(code = 0)]
const EWrongType: vector<u8> = b"Item type does not match";
#[error(code = 1)]
const EInsufficientQuantity: vector<u8> = b"Not enough quantity in the bag";
#[error(code = 2)]
const EZeroQuantity: vector<u8> = b"Quantity must be non-zero";

// === Structs ===

/// Standalone item: created on withdraw, destroyed on deposit. `volume` is the
/// per-unit volume (see module TODO).
public struct Item has key, store {
    id: UID,
    type_id: u64,
    quantity: u64,
    volume: u64,
}

/// At-rest balances inside an inventory: `type_id -> quantity`.
public struct ItemBag has store {
    balances: LinkedTable<u64, u64>,
}

// === Events ===

public struct ItemMinted has copy, drop {
    game_id: EntityKey,
    quantity: u64,
}

public struct ItemBurned has copy, drop {
    game_id: EntityKey,
    quantity: u64,
}

public struct ItemDeposited has copy, drop {
    game_id: EntityKey,
    quantity: u64,
}

public struct ItemWithdrawn has copy, drop {
    game_id: EntityKey,
    quantity: u64,
}

// === View Functions ===

public fun type_id(item: &Item): u64 {
    item.type_id
}

public fun quantity(item: &Item): u64 {
    item.quantity
}

public fun volume(item: &Item): u64 {
    item.volume
}

/// Current balance of `type_id` in `bag` (0 if absent).
public fun balance(bag: &ItemBag, type_id: u64): u64 {
    if (bag.balances.contains(type_id)) bag.balances[type_id] else 0
}

// === Package Functions ===

/// Create an empty balance store.
public(package) fun new_bag(ctx: &mut TxContext): ItemBag {
    ItemBag { balances: linked_table::new(ctx) }
}

/// Drop a bag and all its balances without emitting burn events.
public(package) fun destroy_bag(bag: ItemBag) {
    let ItemBag { balances } = bag;
    linked_table::drop(balances);
}

/// Mint `quantity` of `game_id` directly into `bag` (game-to-chain bridge).
public(package) fun mint(bag: &mut ItemBag, game_id: EntityKey, quantity: u64) {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    add_balance(bag, type_id, quantity);
    event::emit(ItemMinted { game_id, quantity });
}

/// Burn `quantity` of `game_id` from `bag`, removing it from existence.
public(package) fun burn(bag: &mut ItemBag, game_id: EntityKey, quantity: u64) {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    subtract_balance(bag, type_id, quantity);
    event::emit(ItemBurned { game_id, quantity });
}

/// Burn every balance in `bag` (one `ItemBurned` event per type), then destroy it.
public(package) fun burn_all_and_destroy(bag: ItemBag, tenant: String) {
    let ItemBag { mut balances } = bag;
    while (!balances.is_empty()) {
        let (type_id, quantity) = balances.pop_front();
        event::emit(ItemBurned { game_id: entity_key::new(type_id, tenant), quantity });
    };
    balances.destroy_empty();
}

/// Destroy an `Item`, removing its quantity from existence.
public(package) fun destroy(item: Item, game_id: EntityKey) {
    let Item { id, type_id, quantity, volume: _ } = item;
    assert!(entity_key::id(&game_id) == type_id, EWrongType);
    event::emit(ItemBurned { game_id, quantity });
    id.delete();
}

/// Deposit `item` into `bag`, merging into the existing balance for its type.
public(package) fun deposit(bag: &mut ItemBag, item: Item, game_id: EntityKey) {
    let type_id = entity_key::id(&game_id);
    let Item { id, type_id: item_type_id, quantity, volume: _ } = item;
    assert!(type_id == item_type_id, EWrongType);
    id.delete();
    add_balance(bag, type_id, quantity);
    event::emit(ItemDeposited { game_id, quantity });
}

/// Withdraw `quantity` of `game_id` from `bag` as a fresh `Item` with `volume`.
public(package) fun withdraw(
    bag: &mut ItemBag,
    game_id: EntityKey,
    quantity: u64,
    volume: u64,
    ctx: &mut TxContext,
): Item {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    subtract_balance(bag, type_id, quantity);
    event::emit(ItemWithdrawn { game_id, quantity });
    Item { id: object::new(ctx), type_id, quantity, volume }
}

/// Split `quantity` off `item` into a new `Item` of the same type.
public(package) fun split(item: &mut Item, quantity: u64, ctx: &mut TxContext): Item {
    assert!(quantity > 0, EZeroQuantity);
    assert!(item.quantity >= quantity, EInsufficientQuantity);
    item.quantity = item.quantity - quantity;
    Item { id: object::new(ctx), type_id: item.type_id, quantity, volume: item.volume }
}

/// Merge `other` into `item`. Both must be the same type.
public(package) fun merge(item: &mut Item, other: Item) {
    let Item { id, type_id, quantity, volume: _ } = other;
    assert!(item.type_id == type_id, EWrongType);
    id.delete();
    item.quantity = item.quantity + quantity;
}

// === Private Functions ===

fun add_balance(bag: &mut ItemBag, type_id: u64, quantity: u64) {
    if (bag.balances.contains(type_id)) {
        *&mut bag.balances[type_id] = bag.balances[type_id] + quantity;
    } else {
        bag.balances.push_back(type_id, quantity);
    };
}

fun subtract_balance(bag: &mut ItemBag, type_id: u64, quantity: u64) {
    assert!(bag.balances.contains(type_id), EInsufficientQuantity);
    let balance = &mut bag.balances[type_id];
    assert!(*balance >= quantity, EInsufficientQuantity);
    *balance = *balance - quantity;
    if (*balance == 0) {
        bag.balances.remove(type_id);
    };
}
