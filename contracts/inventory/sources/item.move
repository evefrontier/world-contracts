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

/// One entry of a batched withdrawal or deposit, with the same meaning as the
/// matching fields on `ItemWithdrawn` / `ItemDeposited`.
public struct MovedBalance has copy, drop {
    type_id: u64,
    quantity: u64,
    transit_id: ID,
    balance_after: u64,
    used_after: u64,
}

/// One batch of a `withdraw_batch`, entries in input order. `batch_index` runs
/// `0..batch_count`.
public struct ItemsWithdrawn has copy, drop {
    entity_id: ID,
    component_id: u64,
    batch_index: u64,
    batch_count: u64,
    items: vector<MovedBalance>,
}

/// One batch of a `deposit_batch`, entries in input order. `batch_index` runs
/// `0..batch_count`.
public struct ItemsDeposited has copy, drop {
    entity_id: ID,
    component_id: u64,
    batch_index: u64,
    batch_count: u64,
    items: vector<MovedBalance>,
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
    let MovedBalance { type_id, quantity, transit_id, balance_after, used_after } = put_item(
        bag,
        item,
        used,
    );
    event::emit(ItemDeposited {
        game_id: entity_key::new(type_id, tenant),
        quantity,
        entity_id,
        component_id,
        transit_id,
        balance_after,
        used_after,
    });
}

/// Deposit every `items` entry as `deposit` would, listing them in
/// `ItemsDeposited` events of at most `batch_size` each.
public(package) fun deposit_batch(
    bag: &mut ItemBag,
    mut items: vector<Item>,
    entity_id: ID,
    component_id: u64,
    used: &mut u64,
    batch_size: u64,
) {
    items.reverse();
    let batch_count = items.length().div_ceil(batch_size);
    let mut batch_index = 0;
    while (!items.is_empty()) {
        let mut entries = vector[];
        while (!items.is_empty() && entries.length() < batch_size) {
            entries.push_back(put_item(bag, items.pop_back(), used));
        };
        event::emit(ItemsDeposited {
            entity_id,
            component_id,
            batch_index,
            batch_count,
            items: entries,
        });
        batch_index = batch_index + 1;
    };
    items.destroy_empty();
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
    let (item, entry) = take_item(bag, entity_key::id(&game_id), quantity, source, used, ctx);
    let MovedBalance { type_id: _, quantity, transit_id, balance_after, used_after } = entry;
    event::emit(ItemWithdrawn {
        game_id,
        quantity,
        entity_id: source,
        component_id,
        transit_id,
        balance_after,
        used_after,
    });
    item
}

/// Withdraw `quantities[i]` of `type_ids[i]` for each `i` as `withdraw` would,
/// returning the `Item`s in input order and listing them in `ItemsWithdrawn`
/// events of at most `batch_size` each. The vectors must be the same length.
public(package) fun withdraw_batch(
    bag: &mut ItemBag,
    type_ids: vector<u64>,
    quantities: vector<u64>,
    source: ID,
    component_id: u64,
    used: &mut u64,
    batch_size: u64,
    ctx: &mut TxContext,
): vector<Item> {
    let count = type_ids.length();
    let batch_count = count.div_ceil(batch_size);
    let mut items = vector[];
    let mut entries = vector[];
    let mut batch_index = 0;
    count.do!(|i| {
        let (item, entry) = take_item(bag, type_ids[i], quantities[i], source, used, ctx);
        items.push_back(item);
        entries.push_back(entry);
        if (entries.length() == batch_size || i + 1 == count) {
            event::emit(ItemsWithdrawn {
                entity_id: source,
                component_id,
                batch_index,
                batch_count,
                items: entries,
            });
            entries = vector[];
            batch_index = batch_index + 1;
        };
    });
    items
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

/// Merge `item` into `bag` and account its volume; the shared core of
/// `deposit` and `deposit_batch`.
fun put_item(bag: &mut ItemBag, item: Item, used: &mut u64): MovedBalance {
    let Item { id, type_id, quantity, volume, .. } = item;
    let transit_id = id.to_inner();
    id.delete();
    let balance_after = add_balance(bag, type_id, quantity, volume);
    *used = *used + quantity * volume;
    MovedBalance { type_id, quantity, transit_id, balance_after, used_after: *used }
}

/// Split a fresh `Item` off `bag` and account its volume; the shared core of
/// `withdraw` and `withdraw_batch`.
fun take_item(
    bag: &mut ItemBag,
    type_id: u64,
    quantity: u64,
    source: ID,
    used: &mut u64,
    ctx: &mut TxContext,
): (Item, MovedBalance) {
    assert!(quantity > 0, EZeroQuantity);
    let (balance_after, volume) = subtract_balance(bag, type_id, quantity);
    *used = *used - quantity * volume;
    let item = Item { id: object::new(ctx), type_id, quantity, volume, source };
    let transit_id = object::id(&item);
    (item, MovedBalance { type_id, quantity, transit_id, balance_after, used_after: *used })
}

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

#[test_only]
public fun items_withdrawn_fields(e: &ItemsWithdrawn): (ID, u64, u64, u64, vector<MovedBalance>) {
    (e.entity_id, e.component_id, e.batch_index, e.batch_count, e.items)
}

#[test_only]
public fun items_deposited_fields(e: &ItemsDeposited): (ID, u64, u64, u64, vector<MovedBalance>) {
    (e.entity_id, e.component_id, e.batch_index, e.batch_count, e.items)
}

/// `(type_id, quantity, transit_id, balance_after, used_after)`.
#[test_only]
public fun moved_balance_fields(b: &MovedBalance): (u64, u64, ID, u64, u64) {
    (b.type_id, b.quantity, b.transit_id, b.balance_after, b.used_after)
}

/// BCS size of an `ItemsWithdrawn` (same layout as `ItemsDeposited`) holding
/// `batch_size` entries, every field at its widest.
#[test_only]
public fun full_moved_batch_bcs_size(batch_size: u64): u64 {
    let max = std::u64::max_value!();
    let id = object::id_from_address(@0x0);
    let mut items = vector[];
    batch_size.do!(
        |_| items.push_back(MovedBalance {
            type_id: max,
            quantity: max,
            transit_id: id,
            balance_after: max,
            used_after: max,
        }),
    );
    let batch = ItemsWithdrawn {
        entity_id: id,
        component_id: max,
        batch_index: max,
        batch_count: max,
        items,
    };
    sui::bcs::to_bytes(&batch).length()
}
