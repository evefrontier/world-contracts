/// Inventory component installed on an `Entity`: a balance area with its own
/// volume cap. One per entity, created at install.
///
/// Only the owner can configure actions (`enable_action` is owner-gated), so an
/// action's requirements are trusted by construction and any caller who
/// satisfies them may move items through the Inventory. This is how a shared
/// swap (e.g. deposit X, withdraw Y) runs in one player-signed transaction with
/// no owner cap at call time, and how a neutral, multi-party interaction is
/// expressed without a separate per-caller inventory.
///
/// Items are at-rest as balances in an `ItemBag` and in-transit as `Item`
/// objects (see `inventory::item`): the two bridges mint/burn balances against
/// the game, `withdraw`/`deposit` move balances out/in as `Item` objects.
module inventory::inventory;

use core::{
    component::{Self, Component},
    entity::Entity,
    entity_key,
    request::{Request, Frame},
    requirement::{Self, Requirement}
};
use inventory::item::{Self, Item, ItemBag};
use std::{internal::Permit, string::String};
use sui::bcs;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Inventory component version does not match the package version";
#[error(code = 1)]
const EComponentMissing: vector<u8> = b"Inventory component is not installed on this entity";
#[error(code = 2)]
const EOverCapacity: vector<u8> = b"Operation would exceed inventory capacity";
#[error(code = 3)]
const EItemTypeNotAllowed: vector<u8> = b"Item type not permitted by the requirement";
#[error(code = 4)]
const EQuantityBelowMin: vector<u8> = b"Quantity below the required minimum";
#[error(code = 5)]
const EQuantityAboveMax: vector<u8> = b"Quantity above the allowed maximum";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// One balance area with its own volume cap; the component's inner state.
public struct Inventory has store {
    type_id: u64,
    capacity: u64,
    used: u64,
    items: ItemBag,
}

/// Requirement config shared by deposit, withdraw, and bridge handlers.
public struct ItemRequirement has drop {
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
}

public struct BridgeIn(ItemRequirement) has drop;
public struct BridgeOut(ItemRequirement) has drop;
public struct Deposit(ItemRequirement) has drop;
public struct Withdrawal(ItemRequirement) has drop;

// === Events ===

// === Public Functions ===

/// Build and install the storage component under `component_id` with the
/// Inventory's volume capacity. `name` is an optional display label and is not
/// unique.
public fun install(
    entity: &mut Entity,
    component_id: u64,
    type_id: u64,
    name: Option<String>,
    capacity: u64,
    ctx: &mut TxContext,
): Request {
    let inventory = Inventory { type_id, capacity, used: 0, items: item::new_bag(ctx) };
    entity.install(
        component_id,
        name,
        inventory,
        VERSION,
        inventory_permit(),
        ctx,
    )
}

/// Remove the storage component. Aborts if it was never installed. Burns the
/// Inventory's balances (emitting `ItemBurned` per type) so the game client is
/// notified.
public fun uninstall(entity: &mut Entity, component_id: u64, ctx: &mut TxContext): Request {
    assert!(entity.has_component_with_type<Inventory>(component_id), EComponentMissing);

    let tenant = entity.key().tenant();
    let (inv_component, req) = entity.uninstall<Inventory>(
        component_id,
        inventory_permit(),
        ctx,
    );
    let inventory = inv_component.unwrap(inventory_permit());
    burn_inventory(inventory, tenant);
    req
}

/// Game to chain bridge: mint `quantity` of `type_id` into the entity's Inventory.
public fun game_item_to_chain_inventory(
    entity: &mut Entity,
    req: &mut Request,
    type_id: u64,
    quantity: u64,
    volume: u64, // TODO: volume should be stored in static data module in the future
) {
    let key = entity_key::new(type_id, entity.key().tenant());
    let (requirement, frame, inv) = take(entity, req, bridge_in_permit());
    enforce_rule(&requirement, type_id, quantity);
    inv.mint_item(key, quantity, volume);
    req.enqueue(frame);
}

/// Chain to game bridge: burn `quantity` of `type_id` from the entity's Inventory.
public fun chain_item_to_game_inventory(
    entity: &mut Entity,
    req: &mut Request,
    type_id: u64,
    quantity: u64,
) {
    let key = entity_key::new(type_id, entity.key().tenant());
    let (requirement, frame, inv) = take(entity, req, bridge_out_permit());
    enforce_rule(&requirement, type_id, quantity);
    inv.burn_item(key, type_id, quantity);
    req.enqueue(frame);
}

/// Deposit a standalone `Item` into the entity's Inventory.
public fun deposit(entity: &mut Entity, req: &mut Request, item: Item) {
    let type_id = item.type_id();
    let quantity = item.quantity();
    let tenant = entity.key().tenant();
    let (requirement, frame, inv) = take(entity, req, deposit_permit());
    enforce_rule(&requirement, type_id, quantity);
    inv.deposit_item(item, tenant);
    req.enqueue(frame);
}

/// Withdraw `quantity` of `type_id` from the entity's Inventory as a fresh `Item`.
public fun withdraw(
    entity: &mut Entity,
    req: &mut Request,
    type_id: u64,
    quantity: u64,
    ctx: &mut TxContext,
): Item {
    let key = entity_key::new(type_id, entity.key().tenant());
    let (requirement, frame, inv) = take(entity, req, withdrawal_permit());
    enforce_rule(&requirement, type_id, quantity);
    let item = inv.withdraw_item(key, type_id, quantity, ctx);
    req.enqueue(frame);
    item
}

/// Build a bridge-in requirement on component `component_id`.
public fun bridge_in_requirement(
    component_id: u64,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id),
        BridgeIn(rule(type_id, min_quantity, max_quantity)),
    )
}

/// Build a bridge-out requirement on component `component_id`. See `bridge_in_requirement`.
public fun bridge_out_requirement(
    component_id: u64,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id),
        BridgeOut(rule(type_id, min_quantity, max_quantity)),
    )
}

/// Build a deposit requirement on component `component_id`. See `bridge_in_requirement`.
public fun deposit_requirement(
    component_id: u64,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id),
        Deposit(rule(type_id, min_quantity, max_quantity)),
    )
}

/// Build a withdraw requirement on component `component_id`. See `bridge_in_requirement`.
public fun withdraw_requirement(
    component_id: u64,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id),
        Withdrawal(rule(type_id, min_quantity, max_quantity)),
    )
}

// === View Functions ===

/// Read the entity's Inventory installed under `component_id`.
public fun inventory(entity: &Entity, component_id: u64): &Inventory {
    borrow_component(entity, component_id).inner()
}

public fun type_id(inv: &Inventory): u64 {
    inv.type_id
}

public fun capacity(inv: &Inventory): u64 {
    inv.capacity
}

public fun used(inv: &Inventory): u64 {
    inv.used
}

public fun items(inv: &Inventory): &ItemBag {
    &inv.items
}

/// Current balance of `type_id` in the entity's Inventory. Read-only; for
/// clients querying state.
public fun balance_of(entity: &Entity, component_id: u64, type_id: u64): u64 {
    inventory(entity, component_id).items.balance(type_id)
}

// === Private Functions ===

/// Borrow the installed module mid-interaction, popping the next requirement
/// of type `T`. Returns the requirement, the frame, and a mutable handle to the
/// state; the caller enforces the requirement before mutating.
fun take<T: drop>(
    entity: &mut Entity,
    req: &mut Request,
    permit: Permit<T>,
): (Requirement, Frame, &mut Inventory) {
    let c: &mut Component<Inventory> = entity.component_mut(req, inventory_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    let inv = c.inner_mut();
    let (requirement, frame) = req.take_next(permit);
    (requirement, frame, inv)
}

fun rule(
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): ItemRequirement {
    ItemRequirement { type_id, min_quantity, max_quantity }
}

/// Decode the `ItemRequirement` config and assert the operation satisfies it.
/// Mirrors field order: type_id, min, max.
fun enforce_rule(requirement: &Requirement, type_id: u64, quantity: u64) {
    let mut b = bcs::new(requirement.data());
    let allowed_type = b.peel_option_u64();
    let min_quantity = b.peel_option_u64();
    let max_quantity = b.peel_option_u64();
    allowed_type.do!(|t| assert!(type_id == t, EItemTypeNotAllowed));
    min_quantity.do!(|m| assert!(quantity >= m, EQuantityBelowMin));
    max_quantity.do!(|m| assert!(quantity <= m, EQuantityAboveMax));
}

/// Mint a balance into an inventory, enforcing its volume capacity.
fun mint_item(inv: &mut Inventory, game_id: entity_key::EntityKey, quantity: u64, volume: u64) {
    let added = volume * quantity;
    assert!(inv.used + added <= inv.capacity, EOverCapacity);
    inv.used = inv.used + added;
    inv.items.mint(game_id, quantity, volume);
}

/// Burn a balance from an inventory, freeing its volume (chain-to-game bridge).
fun burn_item(inv: &mut Inventory, game_id: entity_key::EntityKey, type_id: u64, quantity: u64) {
    let volume = inv.items.volume_of(type_id);
    inv.items.burn(game_id, quantity);
    inv.used = inv.used - volume * quantity;
}

/// Deposit an item into an inventory, enforcing its volume capacity.
fun deposit_item(inv: &mut Inventory, item: Item, tenant: String) {
    let added = item.volume() * item.quantity();
    assert!(inv.used + added <= inv.capacity, EOverCapacity);
    inv.used = inv.used + added;
    inv.items.deposit(item, tenant);
}

/// Withdraw a balance from an inventory as a fresh `Item`, freeing its volume.
fun withdraw_item(
    inv: &mut Inventory,
    game_id: entity_key::EntityKey,
    type_id: u64,
    quantity: u64,
    ctx: &mut TxContext,
): Item {
    let volume = inv.items.volume_of(type_id);
    let item = inv.items.withdraw(game_id, quantity, ctx);
    inv.used = inv.used - volume * quantity;
    item
}

fun burn_inventory(inv: Inventory, tenant: String) {
    let Inventory { items, type_id: _, capacity: _, used: _ } = inv;
    item::burn_all_and_destroy(items, tenant);
}

fun borrow_component(entity: &Entity, component_id: u64): &Component<Inventory> {
    let c: &Component<Inventory> = entity.component_ref(component_id, inventory_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    c
}

fun inventory_permit(): Permit<Inventory> {
    internal::permit<Inventory>()
}

fun bridge_in_permit(): Permit<BridgeIn> {
    internal::permit<BridgeIn>()
}

fun bridge_out_permit(): Permit<BridgeOut> {
    internal::permit<BridgeOut>()
}

fun deposit_permit(): Permit<Deposit> {
    internal::permit<Deposit>()
}

fun withdrawal_permit(): Permit<Withdrawal> {
    internal::permit<Withdrawal>()
}
