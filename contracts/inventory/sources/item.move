/// Fungible item foundation for the inventory module.
///
/// `Item` is a standalone object created on withdraw and consumed on deposit;
/// `ItemBag` is at-rest balances keyed by `type_id`. Items are fungible: balances
/// stack exactly by `type_id`.
///
/// TODO: volume (and mass) are per-type metadata, not per-balance. Move them to
/// an admin-registered item type (source of truth) and read volume from there
/// instead of carrying it on the bag. Pending team discussion.
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
#[error(code = 3)]
const EVolumeMismatch: vector<u8> = b"Item volume does not match the stored volume for this type";
#[error(code = 4)]
const ESourceMismatch: vector<u8> = b"Items withdrawn from different entities cannot merge";

// === Structs ===

/// Standalone item: created on withdraw, destroyed on deposit. No `store`: a
/// withdrawn `Item` can only move via functions this package defines (i.e.
/// `inventory::deposit`), never by a bare `public_transfer` that would let it
/// leave the Entity/Requirement system ungated. `volume` is the per-unit
/// volume (see module TODO).
public struct Item has key {
    id: UID,
    type_id: u64,
    quantity: u64,
    volume: u64,
    source: ID,
}

/// One at-rest balance: quantity plus the per-unit volume shared by the type.
public struct Balance has drop, store {
    quantity: u64,
    volume: u64,
}

/// At-rest balances inside an inventory: `type_id -> Balance`.
public struct ItemBag has store {
    balances: LinkedTable<u64, Balance>,
}

// === Events ===
//
// `(entity_id, component_id)` is the inventory moved through; `balance_after`
// and `used_after` are its state after the movement. Emitted by
// `inventory::inventory` via the `emit_*` helpers.

/// Game to chain bridge.
public struct ItemMinted has copy, drop {
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    balance_after: u64,
    used_after: u64,
}

/// Chain to game bridge, or one per type on `uninstall`.
public struct ItemBurned has copy, drop {
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    balance_after: u64,
    used_after: u64,
}

/// `transit_id` matches the `ItemWithdrawn` that produced the `Item`.
public struct ItemDeposited has copy, drop {
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    transit_id: ID,
    balance_after: u64,
    used_after: u64,
}

/// `transit_id` is the withdrawn `Item`'s id, matching its `ItemDeposited`.
public struct ItemWithdrawn has copy, drop {
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    transit_id: ID,
    balance_after: u64,
    used_after: u64,
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

public fun source(item: &Item): ID {
    item.source
}

/// Current quantity of `type_id` in `bag` (0 if absent).
public fun balance(bag: &ItemBag, type_id: u64): u64 {
    if (bag.balances.contains(type_id)) bag.balances[type_id].quantity else 0
}

/// Per-unit volume stored for `type_id` in `bag` (0 if absent).
public fun volume_of(bag: &ItemBag, type_id: u64): u64 {
    if (bag.balances.contains(type_id)) bag.balances[type_id].volume else 0
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

/// Mint `quantity` of `game_id` into `bag` at `volume` (game-to-chain bridge).
public(package) fun mint(bag: &mut ItemBag, game_id: EntityKey, quantity: u64, volume: u64) {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    add_balance(bag, type_id, quantity, volume);
}

/// Burn `quantity` of `game_id` from `bag`, removing it from existence.
public(package) fun burn(bag: &mut ItemBag, game_id: EntityKey, quantity: u64) {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    subtract_balance(bag, type_id, quantity);
}

/// Burn every balance in `bag` (one `ItemBurned` event per type), then destroy it.
public(package) fun burn_all_and_destroy(
    bag: ItemBag,
    tenant: String,
    entity_id: ID,
    component_id: u64,
    mut used: u64,
) {
    let ItemBag { mut balances } = bag;
    while (!balances.is_empty()) {
        let (type_id, Balance { quantity, volume }) = balances.pop_front();
        used = used - quantity * volume;
        event::emit(ItemBurned {
            game_id: entity_key::new(type_id, tenant),
            quantity,
            entity_id,
            component_id,
            balance_after: 0,
            used_after: used,
        });
    };
    balances.destroy_empty();
}

/// Deposit `item` into `bag`, merging into the existing balance for its type.
public(package) fun deposit(bag: &mut ItemBag, item: Item) {
    let Item { id, type_id, quantity, volume, .. } = item;
    id.delete();
    add_balance(bag, type_id, quantity, volume);
}

/// Withdraw `quantity` of `game_id` from `bag` as a fresh `Item` with `volume`
public(package) fun withdraw(
    bag: &mut ItemBag,
    game_id: EntityKey,
    quantity: u64,
    source: ID,
    ctx: &mut TxContext,
): Item {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    assert!(bag.balances.contains(type_id), EInsufficientQuantity);
    let volume = bag.balances[type_id].volume;
    subtract_balance(bag, type_id, quantity);
    Item { id: object::new(ctx), type_id, quantity, volume, source }
}

/// Split `quantity` off `item` into a new `Item` of the same type.
public(package) fun split(item: &mut Item, quantity: u64, ctx: &mut TxContext): Item {
    assert!(quantity > 0, EZeroQuantity);
    assert!(item.quantity >= quantity, EInsufficientQuantity);
    item.quantity = item.quantity - quantity;
    Item {
        id: object::new(ctx),
        type_id: item.type_id,
        quantity,
        volume: item.volume,
        source: item.source,
    }
}

/// Merge `other` into `item`. Both must be the same type.
public(package) fun merge(item: &mut Item, other: Item) {
    let Item { id, type_id, quantity, source, .. } = other;
    assert!(item.type_id == type_id, EWrongType);
    assert!(item.source == source, ESourceMismatch);
    id.delete();
    item.quantity = item.quantity + quantity;
}

public(package) fun emit_minted(
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    balance_after: u64,
    used_after: u64,
) {
    event::emit(ItemMinted {
        game_id,
        quantity,
        entity_id,
        component_id,
        balance_after,
        used_after,
    });
}

public(package) fun emit_burned(
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    balance_after: u64,
    used_after: u64,
) {
    event::emit(ItemBurned {
        game_id,
        quantity,
        entity_id,
        component_id,
        balance_after,
        used_after,
    });
}

public(package) fun emit_deposited(
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    transit_id: ID,
    balance_after: u64,
    used_after: u64,
) {
    event::emit(ItemDeposited {
        game_id,
        quantity,
        entity_id,
        component_id,
        transit_id,
        balance_after,
        used_after,
    });
}

public(package) fun emit_withdrawn(
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    transit_id: ID,
    balance_after: u64,
    used_after: u64,
) {
    event::emit(ItemWithdrawn {
        game_id,
        quantity,
        entity_id,
        component_id,
        transit_id,
        balance_after,
        used_after,
    });
}

// === Private Functions ===

fun add_balance(bag: &mut ItemBag, type_id: u64, quantity: u64, volume: u64) {
    if (bag.balances.contains(type_id)) {
        let bal = &mut bag.balances[type_id];
        assert!(bal.volume == volume, EVolumeMismatch);
        bal.quantity = bal.quantity + quantity;
    } else {
        bag.balances.push_back(type_id, Balance { quantity, volume });
    };
}

fun subtract_balance(bag: &mut ItemBag, type_id: u64, quantity: u64) {
    assert!(bag.balances.contains(type_id), EInsufficientQuantity);
    let bal = &mut bag.balances[type_id];
    assert!(bal.quantity >= quantity, EInsufficientQuantity);
    bal.quantity = bal.quantity - quantity;
    let empty = bal.quantity == 0;
    if (empty) {
        bag.balances.remove(type_id);
    };
}

// === Test Functions ===

#[test_only]
public fun destroy(item: Item) {
    let Item { id, .. } = item;
    id.delete();
}

/// `(game_id, quantity, entity_id, component_id, balance_after, used_after)`.
#[test_only]
public fun minted_fields(e: &ItemMinted): (EntityKey, u64, ID, u64, u64, u64) {
    (e.game_id, e.quantity, e.entity_id, e.component_id, e.balance_after, e.used_after)
}

/// `(game_id, quantity, entity_id, component_id, balance_after, used_after)`.
#[test_only]
public fun burned_fields(e: &ItemBurned): (EntityKey, u64, ID, u64, u64, u64) {
    (e.game_id, e.quantity, e.entity_id, e.component_id, e.balance_after, e.used_after)
}

/// `(game_id, quantity, entity_id, component_id, transit_id, balance_after, used_after)`.
#[test_only]
public fun deposited_fields(e: &ItemDeposited): (EntityKey, u64, ID, u64, ID, u64, u64) {
    (
        e.game_id,
        e.quantity,
        e.entity_id,
        e.component_id,
        e.transit_id,
        e.balance_after,
        e.used_after,
    )
}

/// `(game_id, quantity, entity_id, component_id, transit_id, balance_after, used_after)`.
#[test_only]
public fun withdrawn_fields(e: &ItemWithdrawn): (EntityKey, u64, ID, u64, ID, u64, u64) {
    (
        e.game_id,
        e.quantity,
        e.entity_id,
        e.component_id,
        e.transit_id,
        e.balance_after,
        e.used_after,
    )
}
