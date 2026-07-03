/// Inventory module installed on an `Entity`. Holds one `Inventory` (a balance
/// area with its own volume cap) per accessor, keyed by entity id:
///
/// - **main** — keyed by the entity's own id, created at install. Only the owner
///   can configure actions (`enable_action` is owner-gated), so a main
///   requirement on an action is trusted by construction and satisfying the
///   action grants access to main inv. Lets an owner-configured swap run in one
///   player-signed transaction with no owner cap at call time.
/// - **ephemeral** — keyed by the caller's id (`req.authorized_id()`), created on
///   first use, giving a player a personal space. Stop-gap until ship
///   inventories are on-chain; removable without a schema change.
///
/// Each requirement carries an `ephemeral` flag; the handler routes on it.
/// Ephemeral requirements also need `access_cap::caller_requirement()` so the
/// caller is recorded.
///
/// Items are at-rest as balances in an `ItemBag` and in-transit as `Item`
/// objects (see `inventory::item`): the two bridges mint/burn balances against
/// the game, `withdraw`/`deposit` move balances out/in as `Item` objects.
module inventory::inventory;

use core::{
    entity::Entity,
    entity_key,
    mod::{Self, Module},
    request::{Request, Frame},
    requirement::{Self, Requirement}
};
use inventory::item::{Self, Item, ItemBag};
use std::{internal::Permit, string::String};
use sui::{bcs, linked_table::{Self, LinkedTable}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Inventory module version does not match the package version";
#[error(code = 1)]
const EModuleMissing: vector<u8> = b"Inventory module is not installed on this entity";
#[error(code = 2)]
const EOverCapacity: vector<u8> = b"Operation would exceed inventory capacity";
#[error(code = 3)]
const EItemTypeNotAllowed: vector<u8> = b"Item type not permitted by the requirement";
#[error(code = 4)]
const EQuantityBelowMin: vector<u8> = b"Quantity below the required minimum";
#[error(code = 5)]
const EQuantityAboveMax: vector<u8> = b"Quantity above the allowed maximum";
#[error(code = 6)]
const ENotAuthorized: vector<u8> = b"No caller recorded; action must carry a caller requirement";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// One balance with its own volume cap.
public struct Inventory has store {
    capacity: u64,
    used: u64,
    items: ItemBag,
}

/// Module state installed on the entity. One `Inventory` per player, keyed by
/// the authorized id: the entity's own id is the main inventory (created at
/// install); any other key is a lazily-created ephemeral inventory.
public struct StorageInventory has store {
    ephemeral_capacity: u64,
    // `LinkedTable`: so it can be iterated to burn every inventory
    // on uninstall.
    inventories: LinkedTable<ID, Inventory>,
}

/// Requirement config shared by deposit, withdraw, and bridge handlers.
/// `ephemeral` selects the target: false = main, true = the caller's ephemeral
/// inventory.
public struct ItemRequirement has drop {
    ephemeral: bool,
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

/// Build and install the storage module under `name` with independent main and
/// ephemeral volume capacities.
public fun install(
    entity: &mut Entity,
    name: String,
    main_capacity: u64,
    ephemeral_capacity: u64,
    ctx: &mut TxContext,
): Request {
    let entity_id = entity.id();
    let mut inventories = linked_table::new(ctx);
    inventories.push_back(
        entity_id,
        Inventory { capacity: main_capacity, used: 0, items: item::new_bag(ctx) },
    );
    let storage = StorageInventory { ephemeral_capacity, inventories };
    entity.install(name, storage, VERSION, module_permit(), ctx)
}

/// Remove the storage module. Aborts if it was never installed. Burns every
/// inventory's balances (emitting `ItemBurned` per type) so the game client is
/// notified.
public fun uninstall(entity: &mut Entity, name: String, ctx: &mut TxContext): Request {
    assert!(entity.has_module_with_type<StorageInventory>(name), EModuleMissing);

    let tenant = entity.key().tenant();
    let (inv_module, req) = entity.uninstall<StorageInventory>(name, module_permit(), ctx);
    let StorageInventory { ephemeral_capacity: _, inventories } = inv_module.unwrap(
        module_permit(),
    );
    burn_all_inventories(inventories, tenant);
    req
}

/// Game to chain bridge: mint `quantity` of `type_id` into the caller's routed
/// inventory (owner to main, else ephemeral).
public fun game_item_to_chain_inventory(
    entity: &mut Entity,
    req: &mut Request,
    type_id: u64,
    quantity: u64,
    volume: u64,
    ctx: &mut TxContext,
) {
    let key = entity_key::new(type_id, entity.key().tenant());
    let entity_id = entity.id();
    let caller = req.authorized_id();
    let (requirement, frame, storage) = take(entity, req, module_permit_bridge_in());
    let ephemeral = enforce_rule(&requirement, type_id, quantity);
    let inv_key = route_key(caller, entity_id, ephemeral);
    storage.ensure_inventory(inv_key, ctx);
    storage.inventory_mut(inv_key).mint_item(key, quantity, volume);
    req.enqueue(frame);
}

/// Chain to game bridge: burn `quantity` of `type_id` from the caller's routed
/// inventory.
public fun chain_item_to_game_inventory(
    entity: &mut Entity,
    req: &mut Request,
    type_id: u64,
    quantity: u64,
    ctx: &mut TxContext,
) {
    let key = entity_key::new(type_id, entity.key().tenant());
    let entity_id = entity.id();
    let caller = req.authorized_id();
    let (requirement, frame, storage) = take(entity, req, module_permit_bridge_out());
    let ephemeral = enforce_rule(&requirement, type_id, quantity);
    let inv_key = route_key(caller, entity_id, ephemeral);
    storage.ensure_inventory(inv_key, ctx);
    storage.inventory_mut(inv_key).burn_item(key, type_id, quantity);
    req.enqueue(frame);
}

/// Deposit a standalone `Item` into the caller's routed inventory.
public fun deposit(entity: &mut Entity, req: &mut Request, item: Item, ctx: &mut TxContext) {
    let type_id = item.type_id();
    let quantity = item.quantity();
    let tenant = entity.key().tenant();
    let entity_id = entity.id();
    let caller = req.authorized_id();
    let (requirement, frame, storage) = take(entity, req, module_permit_deposit());
    let ephemeral = enforce_rule(&requirement, type_id, quantity);
    let inv_key = route_key(caller, entity_id, ephemeral);
    storage.ensure_inventory(inv_key, ctx);
    storage.inventory_mut(inv_key).deposit_item(item, tenant);
    req.enqueue(frame);
}

/// Withdraw `quantity` of `type_id` from the caller's routed inventory as a
/// fresh `Item`.
public fun withdraw(
    entity: &mut Entity,
    req: &mut Request,
    type_id: u64,
    quantity: u64,
    ctx: &mut TxContext,
): Item {
    let key = entity_key::new(type_id, entity.key().tenant());
    let entity_id = entity.id();
    let caller = req.authorized_id();
    let (requirement, frame, storage) = take(entity, req, module_permit_withdrawal());
    let ephemeral = enforce_rule(&requirement, type_id, quantity);
    let inv_key = route_key(caller, entity_id, ephemeral);
    storage.ensure_inventory(inv_key, ctx);
    let item = storage.inventory_mut(inv_key).withdraw_item(key, type_id, quantity, ctx);
    req.enqueue(frame);
    item
}

/// Build a bridge-in requirement on module `name`. `ephemeral` selects the
/// target: false = main, true = the caller's ephemeral inventory.
public fun bridge_in_requirement(
    name: String,
    ephemeral: bool,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(name),
        BridgeIn(rule(ephemeral, type_id, min_quantity, max_quantity)),
    )
}

/// Build a bridge-out requirement on module `name`. See `bridge_in_requirement`.
public fun bridge_out_requirement(
    name: String,
    ephemeral: bool,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(name),
        BridgeOut(rule(ephemeral, type_id, min_quantity, max_quantity)),
    )
}

/// Build a deposit requirement on module `name`. See `bridge_in_requirement`.
public fun deposit_requirement(
    name: String,
    ephemeral: bool,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(name),
        Deposit(rule(ephemeral, type_id, min_quantity, max_quantity)),
    )
}

/// Build a withdraw requirement on module `name`. See `bridge_in_requirement`.
public fun withdraw_requirement(
    name: String,
    ephemeral: bool,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(name),
        Withdrawal(rule(ephemeral, type_id, min_quantity, max_quantity)),
    )
}

// === View Functions ===

/// Read the installed storage state by module `name`.
public fun storage(entity: &Entity, name: String): &StorageInventory {
    let m: &Module<StorageInventory> = entity.module_ref(name, module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    m.inner()
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

public fun ephemeral_capacity(storage: &StorageInventory): u64 {
    storage.ephemeral_capacity
}

/// True if an inventory exists for `authorized_id`.
public fun has_inventory(storage: &StorageInventory, authorized_id: ID): bool {
    storage.inventories.contains(authorized_id)
}

/// Read the inventory for `authorized_id` (the entity's own id for main).
public fun inventory(storage: &StorageInventory, authorized_id: ID): &Inventory {
    &storage.inventories[authorized_id]
}

// === Private Functions ===

/// Borrow the installed module mid-interaction, popping the next requirement
/// of type `T`. Returns the requirement, the frame, and a mutable handle to the
/// state; the caller enforces the requirement before mutating.
fun take<T: drop>(
    entity: &mut Entity,
    req: &mut Request,
    permit: Permit<T>,
): (Requirement, Frame, &mut StorageInventory) {
    let m: &mut Module<StorageInventory> = entity.module_mut(req, module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    let storage = m.inner_mut();
    let (requirement, frame) = req.take_next(permit);
    (requirement, frame, storage)
}

fun rule(
    ephemeral: bool,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): ItemRequirement {
    ItemRequirement { ephemeral, type_id, min_quantity, max_quantity }
}

/// Decode the `ItemRequirement` config, assert the operation satisfies it, and
/// return the `ephemeral` target flag. Mirrors field order: ephemeral, type_id,
/// min, max.
fun enforce_rule(requirement: &Requirement, type_id: u64, quantity: u64): bool {
    let mut b = bcs::new(requirement.data());
    let ephemeral = b.peel_bool();
    let allowed_type = b.peel_option_u64();
    let min_quantity = b.peel_option_u64();
    let max_quantity = b.peel_option_u64();
    allowed_type.do!(|t| assert!(type_id == t, EItemTypeNotAllowed));
    min_quantity.do!(|m| assert!(quantity >= m, EQuantityBelowMin));
    max_quantity.do!(|m| assert!(quantity <= m, EQuantityAboveMax));
    ephemeral
}

/// Resolve the routing key: the entity's own id for main, or the recorded
/// caller for an ephemeral target (aborts if no caller was recorded).
fun route_key(caller: Option<ID>, entity_id: ID, ephemeral: bool): ID {
    if (ephemeral) caller.destroy_or!(abort ENotAuthorized) else entity_id
}

/// Ensure an inventory exists for `authorized_id`, lazily creating an ephemeral
/// one if absent. The main inventory (entity's own id) always exists from
/// install, so a missing key is by definition a non-owner's ephemeral inventory.
fun ensure_inventory(storage: &mut StorageInventory, authorized_id: ID, ctx: &mut TxContext) {
    if (!storage.inventories.contains(authorized_id)) {
        storage
            .inventories
            .push_back(
                authorized_id,
                Inventory {
                    capacity: storage.ephemeral_capacity,
                    used: 0,
                    items: item::new_bag(ctx),
                },
            );
    };
}

/// Borrow the inventory for `authorized_id`.
fun inventory_mut(storage: &mut StorageInventory, authorized_id: ID): &mut Inventory {
    &mut storage.inventories[authorized_id]
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
    let Inventory { items, capacity: _, used: _ } = inv;
    item::burn_all_and_destroy(items, tenant);
}

fun burn_all_inventories(mut inventories: LinkedTable<ID, Inventory>, tenant: String) {
    while (!inventories.is_empty()) {
        let (_, inv) = inventories.pop_front();
        burn_inventory(inv, tenant);
    };
    inventories.destroy_empty();
}

fun module_permit(): Permit<StorageInventory> {
    internal::permit<StorageInventory>()
}

fun module_permit_bridge_in(): Permit<BridgeIn> {
    internal::permit<BridgeIn>()
}

fun module_permit_bridge_out(): Permit<BridgeOut> {
    internal::permit<BridgeOut>()
}

fun module_permit_deposit(): Permit<Deposit> {
    internal::permit<Deposit>()
}

fun module_permit_withdrawal(): Permit<Withdrawal> {
    internal::permit<Withdrawal>()
}
