/// Item foundation for the inventory module. Two kinds of item:
///
/// - **non-singleton** — identified by `type_id`, stackable by quantity. `Item` is a
///   standalone object created on withdraw and consumed on deposit; `ItemBag`
///   holds them as at-rest `Balance`s keyed by `type_id`.
/// - **singleton** — identified by a unique game-assigned `item_id`, quantity
///   always 1.
///
/// Chain trusts the game to allocate `item_id`s uniquely; `mint_singleton` only
/// guards against a duplicate landing in the *same* bag, not globally.
///
/// TODO: volume (and mass) are per-type metadata, not per-balance/instance. Move
/// them to an admin-registered item type (source of truth) and read volume from
/// there instead of carrying it on the bag. Pending team discussion.
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
const EItemIdExists: vector<u8> = b"Singleton item id already exists in this bag";
#[error(code = 5)]
const EItemIdNotFound: vector<u8> = b"Singleton item id not found in this bag";
#[error(code = 6)]
const EIsSingleton: vector<u8> = b"Singleton items cannot be split or merged";

// === Structs ===

/// Standalone item: created on withdraw, destroyed on deposit. `item_id` is
/// `none` for a non-singleton item, `some` (unique) for a singleton — a singleton's
/// `quantity` is always 1. `volume` is the per-unit volume (see module TODO).
public struct Item has key, store {
    id: UID,
    item_id: Option<u64>,
    type_id: u64,
    quantity: u64,
    volume: u64,
}

/// One at-rest balance: quantity plus the per-unit volume shared by the type.
public struct Balance has drop, store {
    quantity: u64,
    volume: u64,
}

/// At-rest items inside an inventory: non-singleton `Balance`s keyed by `type_id`,
/// and singleton `Item` objects keyed by their own `item_id`.
public struct ItemBag has store {
    balances: LinkedTable<u64, Balance>,
    singletons: LinkedTable<u64, Item>,
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

public fun item_id(item: &Item): Option<u64> {
    item.item_id
}

public fun type_id(item: &Item): u64 {
    item.type_id
}

public fun quantity(item: &Item): u64 {
    item.quantity
}

public fun volume(item: &Item): u64 {
    item.volume
}

/// Current quantity of `type_id` in `bag` (0 if absent).
public fun balance(bag: &ItemBag, type_id: u64): u64 {
    if (bag.balances.contains(type_id)) bag.balances[type_id].quantity else 0
}

/// Per-unit volume stored for `type_id` in `bag` (0 if absent).
public fun volume_of(bag: &ItemBag, type_id: u64): u64 {
    if (bag.balances.contains(type_id)) bag.balances[type_id].volume else 0
}

/// True if a singleton `item_id` is stored in `bag`.
public fun has_singleton(bag: &ItemBag, item_id: u64): bool {
    bag.singletons.contains(item_id)
}

/// Volume of the singleton `item_id` in `bag` (0 if absent).
public fun singleton_volume(bag: &ItemBag, item_id: u64): u64 {
    if (bag.singletons.contains(item_id)) bag.singletons[item_id].volume else 0
}

// === Package Functions ===

/// Create an empty item store.
public(package) fun new_bag(ctx: &mut TxContext): ItemBag {
    ItemBag { balances: linked_table::new(ctx), singletons: linked_table::new(ctx) }
}

/// Drop a bag and all its items without emitting burn events.
public(package) fun destroy_bag(bag: ItemBag) {
    let ItemBag { balances, mut singletons } = bag;
    linked_table::drop(balances);
    while (!singletons.is_empty()) {
        let (_, item) = singletons.pop_front();
        let Item { id, item_id: _, type_id: _, quantity: _, volume: _ } = item;
        id.delete();
    };
    singletons.destroy_empty();
}

/// Mint `quantity` of `game_id` into `bag` at `volume` (game-to-chain bridge).
public(package) fun mint(bag: &mut ItemBag, game_id: EntityKey, quantity: u64, volume: u64) {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    add_balance(bag, type_id, quantity, volume);
    event::emit(ItemMinted { game_id, quantity });
}

/// Burn `quantity` of `game_id` from `bag`, removing it from existence.
public(package) fun burn(bag: &mut ItemBag, game_id: EntityKey, quantity: u64) {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    subtract_balance(bag, type_id, quantity);
    event::emit(ItemBurned { game_id, quantity });
}

/// Burn every non-singleton balance and singleton in `bag` (one `ItemBurned` event
/// each), then destroy it.
public(package) fun burn_all_and_destroy(bag: ItemBag, tenant: String) {
    let ItemBag { mut balances, mut singletons } = bag;
    while (!balances.is_empty()) {
        let (type_id, Balance { quantity, volume: _ }) = balances.pop_front();
        event::emit(ItemBurned { game_id: entity_key::new(type_id, tenant), quantity });
    };
    balances.destroy_empty();
    while (!singletons.is_empty()) {
        let (_, item) = singletons.pop_front();
        let Item { id, item_id: _, type_id, quantity, volume: _ } = item;
        id.delete();
        event::emit(ItemBurned { game_id: entity_key::new(type_id, tenant), quantity });
    };
    singletons.destroy_empty();
}

/// Destroy a non-singleton `Item`, removing its quantity from existence.
public(package) fun destroy(item: Item, game_id: EntityKey) {
    let Item { id, item_id: _, type_id, quantity, volume: _ } = item;
    assert!(entity_key::id(&game_id) == type_id, EWrongType);
    event::emit(ItemBurned { game_id, quantity });
    id.delete();
}

/// Deposit `item` into `bag`. A non-singleton item (`item_id` `none`) merges into
/// the existing balance for its type; a singleton is stored under its own
/// `item_id`. Aborts if that `item_id` already exists in this bag.
public(package) fun deposit(bag: &mut ItemBag, item: Item, tenant: String) {
    if (item.item_id.is_some()) {
        let item_id = *item.item_id.borrow();
        let type_id = item.type_id;
        assert!(!bag.singletons.contains(item_id), EItemIdExists);
        bag.singletons.push_back(item_id, item);
        event::emit(ItemDeposited { game_id: entity_key::new(type_id, tenant), quantity: 1 });
    } else {
        let Item { id, item_id: _, type_id, quantity, volume } = item;
        id.delete();
        add_balance(bag, type_id, quantity, volume);
        event::emit(ItemDeposited { game_id: entity_key::new(type_id, tenant), quantity });
    }
}

/// Withdraw `quantity` of `game_id` from `bag` as a fresh non-singleton `Item` with `volume`.
public(package) fun withdraw(
    bag: &mut ItemBag,
    game_id: EntityKey,
    quantity: u64,
    ctx: &mut TxContext,
): Item {
    let type_id = entity_key::id(&game_id);
    assert!(quantity > 0, EZeroQuantity);
    assert!(bag.balances.contains(type_id), EInsufficientQuantity);
    let volume = bag.balances[type_id].volume;
    subtract_balance(bag, type_id, quantity);
    event::emit(ItemWithdrawn { game_id, quantity });
    Item { id: object::new(ctx), item_id: option::none(), type_id, quantity, volume }
}

/// Mint a singleton `item_id` of kind `game_id` into `bag` at `volume`
/// (game-to-chain bridge). Aborts if `item_id` already exists in this bag (see
/// module docs on the uniqueness trust boundary).
public(package) fun mint_singleton(
    bag: &mut ItemBag,
    item_id: u64,
    game_id: EntityKey,
    volume: u64,
    ctx: &mut TxContext,
) {
    assert!(!bag.singletons.contains(item_id), EItemIdExists);
    let type_id = entity_key::id(&game_id);
    let item = Item { id: object::new(ctx), item_id: option::some(item_id), type_id, quantity: 1, volume };
    bag.singletons.push_back(item_id, item);
    event::emit(ItemMinted { game_id, quantity: 1 });
}

/// Burn the singleton `item_id` from `bag` (chain-to-game bridge), removing it
/// from existence. Aborts if absent or if `game_id`'s type doesn't match the
/// stored instance.
public(package) fun burn_singleton(bag: &mut ItemBag, item_id: u64, game_id: EntityKey) {
    assert!(bag.singletons.contains(item_id), EItemIdNotFound);
    let Item { id, item_id: _, type_id, quantity, volume: _ } = bag.singletons.remove(item_id);
    assert!(type_id == entity_key::id(&game_id), EWrongType);
    id.delete();
    event::emit(ItemBurned { game_id, quantity });
}

/// Remove the singleton `item_id` from `bag` and return it as a standalone
/// `Item`. Aborts if absent or if `game_id`'s type doesn't match the stored
/// instance.
public(package) fun withdraw_singleton(bag: &mut ItemBag, item_id: u64, game_id: EntityKey): Item {
    assert!(bag.singletons.contains(item_id), EItemIdNotFound);
    let item = bag.singletons.remove(item_id);
    assert!(item.type_id == entity_key::id(&game_id), EWrongType);
    event::emit(ItemWithdrawn { game_id, quantity: 1 });
    item
}

/// Split `quantity` off `item` into a new non-singleton `Item` of the same type.
/// Aborts if `item` is a singleton (`item_id` is `some`) — singletons never
/// split or merge.
public(package) fun split(item: &mut Item, quantity: u64, ctx: &mut TxContext): Item {
    assert!(item.item_id.is_none(), EIsSingleton);
    assert!(quantity > 0, EZeroQuantity);
    assert!(item.quantity >= quantity, EInsufficientQuantity);
    item.quantity = item.quantity - quantity;
    Item {
        id: object::new(ctx),
        item_id: option::none(),
        type_id: item.type_id,
        quantity,
        volume: item.volume,
    }
}

/// Merge `other` into `item`. Both must be the same type; aborts if either is
/// a singleton — singletons never split or merge.
public(package) fun merge(item: &mut Item, other: Item) {
    assert!(item.item_id.is_none() && other.item_id.is_none(), EIsSingleton);
    let Item { id, item_id: _, type_id, quantity, volume: _ } = other;
    assert!(item.type_id == type_id, EWrongType);
    id.delete();
    item.quantity = item.quantity + quantity;
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
