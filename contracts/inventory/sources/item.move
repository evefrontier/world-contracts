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
// `balance_after` and `used_after` are the inventory's state after the movement.

/// Game to chain bridge.
public struct ItemMinted has copy, drop {
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    balance_after: u64,
    used_after: u64,
}

/// Chain to game bridge.
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

/// One balance `uninstall` destroyed: `quantity` of `type_id` at per-unit `volume`.
public struct DestroyedBalance has copy, drop {
    type_id: u64,
    quantity: u64,
    volume: u64,
}

/// One batch of the balances `uninstall` destroyed. `batch_index` runs
/// `0..batch_count` of the preceding `InventoryUninstalled`.
public struct ItemsDestroyed has copy, drop {
    entity_id: ID,
    component_id: u64,
    batch_index: u64,
    balances: vector<DestroyedBalance>,
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

/// Number of types held in `bag`.
public fun balance_count(bag: &ItemBag): u64 {
    bag.balances.length()
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
public(package) fun mint(
    bag: &mut ItemBag,
    game_id: EntityKey,
    quantity: u64,
    volume: u64,
    entity_id: ID,
    component_id: u64,
    used: &mut u64,
) {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    let balance_after = add_balance(bag, type_id, quantity, volume);
    *used = *used + quantity * volume;
    event::emit(ItemMinted {
        game_id,
        quantity,
        entity_id,
        component_id,
        balance_after,
        used_after: *used,
    });
}

/// Burn `quantity` of `game_id` from `bag`, removing it from existence.
public(package) fun burn(
    bag: &mut ItemBag,
    game_id: EntityKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    used: &mut u64,
) {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    let (balance_after, volume) = subtract_balance(bag, type_id, quantity);
    *used = *used - quantity * volume;
    event::emit(ItemBurned {
        game_id,
        quantity,
        entity_id,
        component_id,
        balance_after,
        used_after: *used,
    });
}

/// Remove every balance from `bag`, listing them in `ItemsDestroyed` events of
/// at most `batch_size` each, then destroy it.
public(package) fun drain_and_destroy(
    bag: ItemBag,
    entity_id: ID,
    component_id: u64,
    batch_size: u64,
) {
    let ItemBag { mut balances } = bag;
    let mut batch_index = 0;
    while (!balances.is_empty()) {
        let mut batch = vector[];
        while (!balances.is_empty() && batch.length() < batch_size) {
            let (type_id, Balance { quantity, volume }) = balances.pop_front();
            batch.push_back(DestroyedBalance { type_id, quantity, volume });
        };
        event::emit(ItemsDestroyed { entity_id, component_id, batch_index, balances: batch });
        batch_index = batch_index + 1;
    };
    balances.destroy_empty();
}

/// Deposit `item` into `bag`, merging into the existing balance for its type.
public(package) fun deposit(
    bag: &mut ItemBag,
    item: Item,
    tenant: String,
    entity_id: ID,
    component_id: u64,
    used: &mut u64,
) {
    let Item { id, type_id, quantity, volume, .. } = item;
    let transit_id = id.to_inner();
    id.delete();
    let balance_after = add_balance(bag, type_id, quantity, volume);
    *used = *used + quantity * volume;
    event::emit(ItemDeposited {
        game_id: entity_key::new(type_id, tenant),
        quantity,
        entity_id,
        component_id,
        transit_id,
        balance_after,
        used_after: *used,
    });
}

/// Withdraw `quantity` of `game_id` from `bag` as a fresh `Item`.
public(package) fun withdraw(
    bag: &mut ItemBag,
    game_id: EntityKey,
    quantity: u64,
    source: ID,
    component_id: u64,
    used: &mut u64,
    ctx: &mut TxContext,
): Item {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    let (balance_after, volume) = subtract_balance(bag, type_id, quantity);
    *used = *used - quantity * volume;
    let item = Item { id: object::new(ctx), type_id, quantity, volume, source };
    event::emit(ItemWithdrawn {
        game_id,
        quantity,
        entity_id: source,
        component_id,
        transit_id: object::id(&item),
        balance_after,
        used_after: *used,
    });
    item
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

// === Private Functions ===

/// Returns the new quantity.
fun add_balance(bag: &mut ItemBag, type_id: u64, quantity: u64, volume: u64): u64 {
    if (bag.balances.contains(type_id)) {
        let bal = &mut bag.balances[type_id];
        assert!(bal.volume == volume, EVolumeMismatch);
        bal.quantity = bal.quantity + quantity;
        bal.quantity
    } else {
        bag.balances.push_back(type_id, Balance { quantity, volume });
        quantity
    }
}

/// Returns the remaining quantity and the type's per-unit volume.
fun subtract_balance(bag: &mut ItemBag, type_id: u64, quantity: u64): (u64, u64) {
    assert!(bag.balances.contains(type_id), EInsufficientQuantity);
    let bal = &mut bag.balances[type_id];
    assert!(bal.quantity >= quantity, EInsufficientQuantity);
    bal.quantity = bal.quantity - quantity;
    let (remaining, volume) = (bal.quantity, bal.volume);
    if (remaining == 0) {
        bag.balances.remove(type_id);
    };
    (remaining, volume)
}

// === Test Functions ===

#[test_only]
public fun destroy(item: Item) {
    let Item { id, .. } = item;
    id.delete();
}

#[test_only]
public fun minted_fields(e: &ItemMinted): (EntityKey, u64, ID, u64, u64, u64) {
    (e.game_id, e.quantity, e.entity_id, e.component_id, e.balance_after, e.used_after)
}

#[test_only]
public fun burned_fields(e: &ItemBurned): (EntityKey, u64, ID, u64, u64, u64) {
    (e.game_id, e.quantity, e.entity_id, e.component_id, e.balance_after, e.used_after)
}

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

#[test_only]
public fun items_destroyed_fields(e: &ItemsDestroyed): (ID, u64, u64, vector<DestroyedBalance>) {
    (e.entity_id, e.component_id, e.batch_index, e.balances)
}

#[test_only]
public fun destroyed_balance_fields(b: &DestroyedBalance): (u64, u64, u64) {
    (b.type_id, b.quantity, b.volume)
}

/// BCS size of an `ItemsDestroyed` holding `batch_size` balances, every field at
/// its widest.
#[test_only]
public fun full_batch_bcs_size(batch_size: u64): u64 {
    let max = std::u64::max_value!();
    let mut balances = vector[];
    batch_size.do!(
        |_| balances.push_back(DestroyedBalance { type_id: max, quantity: max, volume: max }),
    );
    let batch = ItemsDestroyed {
        entity_id: object::id_from_address(@0x0),
        component_id: max,
        batch_index: max,
        balances,
    };
    sui::bcs::to_bytes(&batch).length()
}
