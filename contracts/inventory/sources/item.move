/// Fungible item foundation for the inventory module.
///
/// `Item` is a standalone object created on withdraw and consumed on deposit;
/// `ItemBag` is at-rest balances keyed by `VariantKey`, so stacks join only when
/// they are the same variant. Quantities are plain base units (1 item, or 1e-9 kg)
/// and carry the variant's `unit_volume` and `decimals` (see `variant::variant`).
///
/// Volume is in nano-m³: a stack's volume is `ceil(unit_volume × quantity /
/// 10^decimals)`, recomputed whenever its quantity changes, so rounding happens
/// once per stack. Mass amounts must be whole 0.0001 kg (the game's precision),
/// so nothing is lost when they go back to the game.
module inventory::item;

use sui::{event, linked_table::{Self, LinkedTable}};
use variant::variant::VariantKey;

// === Errors ===

#[error(code = 0)]
const EWrongVariant: vector<u8> = b"Item variant does not match";
#[error(code = 1)]
const EInsufficientQuantity: vector<u8> = b"Not enough quantity in the bag";
#[error(code = 2)]
const EZeroQuantity: vector<u8> = b"Quantity must be non-zero";
#[error(code = 3)]
const ESourceMismatch: vector<u8> = b"Items withdrawn from different entities cannot merge";
#[error(code = 4)]
const EQuantityNotWholeStep: vector<u8> = b"Mass quantity must be a whole multiple of 0.0001 kg";
#[error(code = 5)]
const EVolumeOverflow: vector<u8> = b"Stack volume does not fit in u64";

// === Constants ===

/// Decimals the game keeps; finer base units must come in whole steps of this.
const GAME_DECIMALS: u8 = 4;

// === Structs ===

/// Standalone item: created on withdraw, destroyed on deposit. No `store`: a
/// withdrawn `Item` can only move via functions this package defines (i.e.
/// `inventory::deposit`), never by a bare `public_transfer` that would let it
/// leave the Entity/Requirement system ungated.
public struct Item has key {
    id: UID,
    key: VariantKey,
    quantity: u64, // base units
    unit_volume: u64, // nano-m³ per kg (mass) or per item, from the variant
    decimals: u8, // of `quantity`, from the variant
    source: ID,
}

/// One at-rest stack of a variant.
public struct Balance has drop, store {
    quantity: u64,
    unit_volume: u64,
    decimals: u8,
}

/// At-rest balances inside an inventory: `VariantKey -> Balance`.
public struct ItemBag has store {
    balances: LinkedTable<VariantKey, Balance>,
}

// === Events ===
// `balance_after` and `used_after` are the inventory's state after the movement.

/// Game to chain bridge.
public struct ItemMinted has copy, drop {
    key: VariantKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    balance_after: u64,
    used_after: u64,
}

/// Chain to game bridge.
public struct ItemBurned has copy, drop {
    key: VariantKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    balance_after: u64,
    used_after: u64,
}

/// `transit_id` matches the `ItemWithdrawn` that produced the `Item`.
public struct ItemDeposited has copy, drop {
    key: VariantKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    transit_id: ID,
    balance_after: u64,
    used_after: u64,
}

/// `transit_id` is the withdrawn `Item`'s id, matching its `ItemDeposited`.
public struct ItemWithdrawn has copy, drop {
    key: VariantKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    transit_id: ID,
    balance_after: u64,
    used_after: u64,
}

/// One balance `uninstall` destroyed: `quantity` of `key`, taking `volume` nano-m³.
public struct DestroyedBalance has copy, drop {
    key: VariantKey,
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
    key: VariantKey,
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

public fun key(item: &Item): VariantKey {
    item.key
}

public fun quantity(item: &Item): u64 {
    item.quantity
}

public fun unit_volume(item: &Item): u64 {
    item.unit_volume
}

public fun decimals(item: &Item): u8 {
    item.decimals
}

public fun source(item: &Item): ID {
    item.source
}

/// Volume the item takes in nano-m³, rounded up.
public fun volume(item: &Item): u64 {
    stack_volume(item.unit_volume, item.quantity, item.decimals)
}

/// Current quantity of `key` in `bag` (0 if absent).
public fun balance(bag: &ItemBag, key: VariantKey): u64 {
    if (bag.balances.contains(key)) bag.balances[key].quantity else 0
}

/// Volume of the `key` stack in `bag` in nano-m³ (0 if absent).
public fun volume_of(bag: &ItemBag, key: VariantKey): u64 {
    if (bag.balances.contains(key)) {
        let bal = &bag.balances[key];
        stack_volume(bal.unit_volume, bal.quantity, bal.decimals)
    } else 0
}

/// Number of stacks held in `bag`.
public fun balance_count(bag: &ItemBag): u64 {
    bag.balances.length()
}

/// `ceil(unit_volume × quantity / 10^decimals)`: a stack's volume in nano-m³.
public fun stack_volume(unit_volume: u64, quantity: u64, decimals: u8): u64 {
    let product = (unit_volume as u128) * (quantity as u128);
    let volume = product.div_ceil(std::u128::pow(10, decimals));
    assert!(volume <= (std::u64::max_value!() as u128), EVolumeOverflow);
    volume as u64
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

/// Mint `quantity` of `key` into `bag` (game-to-chain bridge).
public(package) fun mint(
    bag: &mut ItemBag,
    key: VariantKey,
    quantity: u64,
    unit_volume: u64,
    decimals: u8,
    entity_id: ID,
    component_id: u64,
    used: &mut u64,
) {
    assert_quantity(quantity, decimals);
    let balance_after = add_balance(bag, key, quantity, unit_volume, decimals, used);
    event::emit(ItemMinted {
        key,
        quantity,
        entity_id,
        component_id,
        balance_after,
        used_after: *used,
    });
}

/// Burn `quantity` of `key` from `bag`, removing it from existence.
public(package) fun burn(
    bag: &mut ItemBag,
    key: VariantKey,
    quantity: u64,
    entity_id: ID,
    component_id: u64,
    used: &mut u64,
) {
    let (balance_after, _, _) = subtract_balance(bag, key, quantity, used);
    event::emit(ItemBurned {
        key,
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
            let (key, Balance { quantity, unit_volume, decimals }) = balances.pop_front();
            let volume = stack_volume(unit_volume, quantity, decimals);
            batch.push_back(DestroyedBalance { key, quantity, volume });
        };
        event::emit(ItemsDestroyed { entity_id, component_id, batch_index, balances: batch });
        batch_index = batch_index + 1;
    };
    balances.destroy_empty();
}

/// Deposit `item` into `bag`, merging into the existing stack of its variant.
public(package) fun deposit(
    bag: &mut ItemBag,
    item: Item,
    entity_id: ID,
    component_id: u64,
    used: &mut u64,
) {
    let MovedBalance { key, quantity, transit_id, balance_after, used_after } = put_item(
        bag,
        item,
        used,
    );
    event::emit(ItemDeposited {
        key,
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

/// Withdraw `quantity` of `key` from `bag` as a fresh `Item`.
public(package) fun withdraw(
    bag: &mut ItemBag,
    key: VariantKey,
    quantity: u64,
    source: ID,
    component_id: u64,
    used: &mut u64,
    ctx: &mut TxContext,
): Item {
    let (item, entry) = take_item(bag, key, quantity, source, used, ctx);
    let MovedBalance { key, quantity, transit_id, balance_after, used_after } = entry;
    event::emit(ItemWithdrawn {
        key,
        quantity,
        entity_id: source,
        component_id,
        transit_id,
        balance_after,
        used_after,
    });
    item
}

/// Withdraw `quantities[i]` of `keys[i]` for each `i` as `withdraw` would,
/// returning the `Item`s in input order and listing them in `ItemsWithdrawn`
/// events of at most `batch_size` each. The vectors must be the same length.
public(package) fun withdraw_batch(
    bag: &mut ItemBag,
    keys: vector<VariantKey>,
    quantities: vector<u64>,
    source: ID,
    component_id: u64,
    used: &mut u64,
    batch_size: u64,
    ctx: &mut TxContext,
): vector<Item> {
    let count = keys.length();
    let batch_count = count.div_ceil(batch_size);
    let mut items = vector[];
    let mut entries = vector[];
    let mut batch_index = 0;
    count.do!(|i| {
        let (item, entry) = take_item(bag, keys[i], quantities[i], source, used, ctx);
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

/// Split `quantity` off `item` into a new `Item` of the same variant.
public(package) fun split(item: &mut Item, quantity: u64, ctx: &mut TxContext): Item {
    assert_quantity(quantity, item.decimals);
    assert!(item.quantity >= quantity, EInsufficientQuantity);
    item.quantity = item.quantity - quantity;
    Item {
        id: object::new(ctx),
        key: item.key,
        quantity,
        unit_volume: item.unit_volume,
        decimals: item.decimals,
        source: item.source,
    }
}

/// Merge `other` into `item`. Both must be the same variant and source.
public(package) fun merge(item: &mut Item, other: Item) {
    let Item { id, key, quantity, source, .. } = other;
    assert!(item.key == key, EWrongVariant);
    assert!(item.source == source, ESourceMismatch);
    id.delete();
    item.quantity = item.quantity + quantity;
}

/// Destroy `item`, taking it out of play. Returns its variant and quantity.
public(package) fun burn_item(item: Item): (VariantKey, u64) {
    let Item { id, key, quantity, .. } = item;
    id.delete();
    (key, quantity)
}

// === Private Functions ===

/// Abort unless `quantity` is non-zero and, for units finer than the game's,
/// a whole number of the game's smallest step.
fun assert_quantity(quantity: u64, decimals: u8) {
    assert!(quantity > 0, EZeroQuantity);
    if (decimals > GAME_DECIMALS) {
        let step = std::u64::pow(10, decimals - GAME_DECIMALS);
        assert!(quantity % step == 0, EQuantityNotWholeStep);
    };
}

/// Merge `item` into `bag` and account its volume; the shared core of
/// `deposit` and `deposit_batch`.
fun put_item(bag: &mut ItemBag, item: Item, used: &mut u64): MovedBalance {
    let Item { id, key, quantity, unit_volume, decimals, .. } = item;
    assert!(quantity > 0, EZeroQuantity);
    let transit_id = id.to_inner();
    id.delete();
    let balance_after = add_balance(bag, key, quantity, unit_volume, decimals, used);
    MovedBalance { key, quantity, transit_id, balance_after, used_after: *used }
}

/// Split a fresh `Item` off `bag` and account its volume; the shared core of
/// `withdraw` and `withdraw_batch`.
fun take_item(
    bag: &mut ItemBag,
    key: VariantKey,
    quantity: u64,
    source: ID,
    used: &mut u64,
    ctx: &mut TxContext,
): (Item, MovedBalance) {
    let (balance_after, unit_volume, decimals) = subtract_balance(bag, key, quantity, used);
    let item = Item { id: object::new(ctx), key, quantity, unit_volume, decimals, source };
    let transit_id = object::id(&item);
    (item, MovedBalance { key, quantity, transit_id, balance_after, used_after: *used })
}

/// Add to the `key` stack, re-rounding its volume into `used`. Returns the new quantity.
fun add_balance(
    bag: &mut ItemBag,
    key: VariantKey,
    quantity: u64,
    unit_volume: u64,
    decimals: u8,
    used: &mut u64,
): u64 {
    if (!bag.balances.contains(key)) {
        bag.balances.push_back(key, Balance { quantity: 0, unit_volume, decimals });
    };
    let bal = &mut bag.balances[key];
    let before = stack_volume(bal.unit_volume, bal.quantity, bal.decimals);
    bal.quantity = bal.quantity + quantity;
    *used = *used - before + stack_volume(bal.unit_volume, bal.quantity, bal.decimals);
    bal.quantity
}

/// Take from the `key` stack, re-rounding its volume into `used`; drops an empty
/// stack. Returns the remaining quantity and the stack's `unit_volume` and `decimals`.
fun subtract_balance(
    bag: &mut ItemBag,
    key: VariantKey,
    quantity: u64,
    used: &mut u64,
): (u64, u64, u8) {
    assert!(bag.balances.contains(key), EInsufficientQuantity);
    let bal = &mut bag.balances[key];
    let (unit_volume, decimals) = (bal.unit_volume, bal.decimals);
    assert_quantity(quantity, decimals);
    assert!(bal.quantity >= quantity, EInsufficientQuantity);
    let before = stack_volume(unit_volume, bal.quantity, decimals);
    bal.quantity = bal.quantity - quantity;
    let remaining = bal.quantity;
    *used = *used - before + stack_volume(unit_volume, remaining, decimals);
    if (remaining == 0) {
        bag.balances.remove(key);
    };
    (remaining, unit_volume, decimals)
}

// === Test Functions ===

#[test_only]
public fun destroy(item: Item) {
    let Item { id, .. } = item;
    id.delete();
}

/// An `Item` no inventory produced, for checks that run before its source is used.
#[test_only]
public fun new_for_testing(
    key: VariantKey,
    quantity: u64,
    unit_volume: u64,
    decimals: u8,
    source: ID,
    ctx: &mut TxContext,
): Item {
    Item { id: object::new(ctx), key, quantity, unit_volume, decimals, source }
}

#[test_only]
public fun minted_fields(e: &ItemMinted): (VariantKey, u64, ID, u64, u64, u64) {
    (e.key, e.quantity, e.entity_id, e.component_id, e.balance_after, e.used_after)
}

#[test_only]
public fun burned_fields(e: &ItemBurned): (VariantKey, u64, ID, u64, u64, u64) {
    (e.key, e.quantity, e.entity_id, e.component_id, e.balance_after, e.used_after)
}

#[test_only]
public fun deposited_fields(e: &ItemDeposited): (VariantKey, u64, ID, u64, ID, u64, u64) {
    (e.key, e.quantity, e.entity_id, e.component_id, e.transit_id, e.balance_after, e.used_after)
}

#[test_only]
public fun withdrawn_fields(e: &ItemWithdrawn): (VariantKey, u64, ID, u64, ID, u64, u64) {
    (e.key, e.quantity, e.entity_id, e.component_id, e.transit_id, e.balance_after, e.used_after)
}

#[test_only]
public fun items_destroyed_fields(e: &ItemsDestroyed): (ID, u64, u64, vector<DestroyedBalance>) {
    (e.entity_id, e.component_id, e.batch_index, e.balances)
}

#[test_only]
public fun destroyed_balance_fields(b: &DestroyedBalance): (VariantKey, u64, u64) {
    (b.key, b.quantity, b.volume)
}

/// A variant key with the longest tenant `new_key` accepts.
#[test_only]
fun widest_key(): VariantKey {
    let max = std::u64::max_value!();
    let mut tenant = vector[];
    variant::variant::max_tenant_length().do!(|_| tenant.push_back(0x61));
    variant::variant::new_key(tenant.to_string(), max, max)
}

/// BCS size of an `ItemsDestroyed` holding `batch_size` balances, every field at
/// its widest.
#[test_only]
public fun full_batch_bcs_size(batch_size: u64): u64 {
    let max = std::u64::max_value!();
    let key = widest_key();
    let mut balances = vector[];
    batch_size.do!(|_| balances.push_back(DestroyedBalance { key, quantity: max, volume: max }));
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

/// `(key, quantity, transit_id, balance_after, used_after)`.
#[test_only]
public fun moved_balance_fields(b: &MovedBalance): (VariantKey, u64, ID, u64, u64) {
    (b.key, b.quantity, b.transit_id, b.balance_after, b.used_after)
}

/// BCS size of an `ItemsWithdrawn` (same layout as `ItemsDeposited`) holding
/// `batch_size` entries, every field at its widest.
#[test_only]
public fun full_moved_batch_bcs_size(batch_size: u64): u64 {
    let max = std::u64::max_value!();
    let id = object::id_from_address(@0x0);
    let key = widest_key();
    let mut items = vector[];
    batch_size.do!(
        |_| items.push_back(MovedBalance {
            key,
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
