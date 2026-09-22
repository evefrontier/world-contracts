/// Fungible item foundation for the inventory module.
///
/// `Item` is a standalone object created on withdraw and consumed on deposit;
/// `ItemBag` is at-rest balances keyed by `type_id`. Items are fungible: balances
/// stack exactly by `type_id`.
///
/// Pure balance mechanics, with no event surface: a movement is only legible
/// once it is attributed to an inventory, and the owning entity and component
/// are reachable in `inventory::inventory` alone, which emits there instead.
///
/// TODO: volume (and mass) are per-type metadata, not per-balance. Move them to
/// an admin-registered item type (source of truth) and read volume from there
/// instead of carrying it on the bag. Pending team discussion.
module inventory::item;

use core::entity_key::{Self, EntityKey};
use sui::linked_table::{Self, LinkedTable};

// === Errors ===

#[error(code = 0)]
const EInsufficientQuantity: vector<u8> = b"Not enough quantity in the bag";
#[error(code = 1)]
const EZeroQuantity: vector<u8> = b"Quantity must be non-zero";
#[error(code = 2)]
const EVolumeMismatch: vector<u8> = b"Item volume does not match the stored volume for this type";

// === Structs ===

/// Standalone item: created on withdraw, destroyed on deposit. No `store`: a
/// withdrawn `Item` can only move via functions this package defines (i.e.
/// `inventory::deposit`), never by a bare `public_transfer` that would let it
/// leave the Entity/Requirement system ungated. Lacking `store` and `drop` it
/// also cannot outlive its transaction, which is what makes the `transit_id` on
/// `ItemWithdrawn` / `ItemDeposited` an always-paired correlation key.
/// `volume` is the per-unit volume (see module TODO).
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

/// Drain every balance out of `bag` and destroy it. The balances are not
/// reported: `inventory::uninstall` accounts for the whole inventory in one
/// `InventoryUninstalled`, so there is nothing per type to hand back. Entries
/// are still popped one by one rather than dropped wholesale, because
/// `linked_table::drop` deletes only the table's parent `UID` and would orphan
/// one dynamic field per balance.
public(package) fun burn_all_and_destroy(bag: ItemBag) {
    let ItemBag { mut balances } = bag;
    while (!balances.is_empty()) {
        let (_, Balance { quantity: _, volume: _ }) = balances.pop_front();
    };
    balances.destroy_empty();
}

/// Deposit `item` into `bag`, merging into the existing balance for its type.
public(package) fun deposit(bag: &mut ItemBag, item: Item) {
    let Item { id, type_id, quantity, volume, .. } = item;
    id.delete();
    add_balance(bag, type_id, quantity, volume);
}

/// Withdraw `quantity` of `game_id` from `bag` as a fresh `Item` carrying the
/// type's stored volume.
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

/// Dispose of an in-transit `Item`. Tests only: production has exactly one exit
/// for an `Item` — `inventory::deposit` — and a withdrawal with no valid
/// destination aborts the transaction rather than taking another one.
#[test_only]
public fun destroy_for_testing(item: Item) {
    let Item { id, .. } = item;
    id.delete();
}
