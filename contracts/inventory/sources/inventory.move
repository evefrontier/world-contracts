/// Inventory module installed on an `Entity`.
///
/// Holds one `Inventory` (balance area with its own volume cap) per accessor,
/// keyed by the id the caller's `AccessCap` authorises (`req.authorized_id()`):
///
/// - **main** — keyed by the entity's own id; the owner (a cap for this entity)
///   operates here.
/// - **ephemeral** — keyed by a non-owner's own entity id; lazily created so a
///   player interacting with this entity has a personal, access-controlled space.
///   A stop-gap until ship inventories are on-chain; removable without a schema
///   change.
///
/// The access-cap service (`access_cap::verify_caller`) records the caller
/// mid-request and each op routes on it. Every inventory action must therefore
/// carry `access_cap::caller_requirement()`.
///
/// # Item flow
///
/// Items exist at-rest as balances in an `ItemBag` and in-transit as standalone
/// `Item` objects (see `inventory::item`):
///
/// - `game_item_to_chain_inventory` — mints a balance into the routed inventory.
/// - `chain_item_to_game_inventory` — burns a balance from the routed inventory.
/// - `withdraw` — moves a balance out as an `Item` object.
/// - `deposit`  — returns an `Item` object into the routed inventory.
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
    let authorized_id = req.authorized_id().destroy_or!(abort ENotAuthorized);
    let (requirement, frame, storage) = take(entity, req, module_permit_bridge_in());
    enforce_rule(&requirement, type_id, quantity);
    storage.ensure_inventory(authorized_id, ctx);
    storage.inventory_mut(authorized_id).mint_item(key, quantity, volume);
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
    let authorized_id = req.authorized_id().destroy_or!(abort ENotAuthorized);
    let (requirement, frame, storage) = take(entity, req, module_permit_bridge_out());
    enforce_rule(&requirement, type_id, quantity);
    storage.ensure_inventory(authorized_id, ctx);
    storage.inventory_mut(authorized_id).burn_item(key, type_id, quantity);
    req.enqueue(frame);
}

/// Deposit a standalone `Item` into the caller's routed inventory.
public fun deposit(entity: &mut Entity, req: &mut Request, item: Item, ctx: &mut TxContext) {
    let type_id = item.type_id();
    let quantity = item.quantity();
    let tenant = entity.key().tenant();
    let authorized_id = req.authorized_id().destroy_or!(abort ENotAuthorized);
    let (requirement, frame, storage) = take(entity, req, module_permit_deposit());
    enforce_rule(&requirement, type_id, quantity);
    storage.ensure_inventory(authorized_id, ctx);
    storage.inventory_mut(authorized_id).deposit_item(item, tenant);
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
    let authorized_id = req.authorized_id().destroy_or!(abort ENotAuthorized);
    let (requirement, frame, storage) = take(entity, req, module_permit_withdrawal());
    enforce_rule(&requirement, type_id, quantity);
    storage.ensure_inventory(authorized_id, ctx);
    let item = storage.inventory_mut(authorized_id).withdraw_item(key, type_id, quantity, ctx);
    req.enqueue(frame);
    item
}

/// Build a bridge-in requirement targeting module `name`.
public fun bridge_in_requirement(
    name: String,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(name),
        BridgeIn(ItemRequirement { type_id, min_quantity, max_quantity }),
    )
}

/// Build a bridge-out requirement targeting module `name`.
public fun bridge_out_requirement(
    name: String,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(name),
        BridgeOut(ItemRequirement { type_id, min_quantity, max_quantity }),
    )
}

/// Build a deposit requirement targeting module `name`.
public fun deposit_requirement(
    name: String,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(name),
        Deposit(ItemRequirement { type_id, min_quantity, max_quantity }),
    )
}

/// Build a withdraw requirement targeting module `name`.
public fun withdraw_requirement(
    name: String,
    type_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(name),
        Withdrawal(ItemRequirement { type_id, min_quantity, max_quantity }),
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

/// Decode the `ItemRequirement` config and assert the operation satisfies it.
/// Mirrors the field order in `ItemRequirement`: type_id, min, max.
fun enforce_rule(requirement: &Requirement, type_id: u64, quantity: u64) {
    let mut b = bcs::new(requirement.data());
    let allowed_type = b.peel_option_u64();
    let min_quantity = b.peel_option_u64();
    let max_quantity = b.peel_option_u64();
    allowed_type.do!(|t| assert!(type_id == t, EItemTypeNotAllowed));
    min_quantity.do!(|m| assert!(quantity >= m, EQuantityBelowMin));
    max_quantity.do!(|m| assert!(quantity <= m, EQuantityAboveMax));
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
    inv.used = inv.used - volume * quantity;
    inv.items.burn(game_id, quantity);
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
    inv.used = inv.used - volume * quantity;
    inv.items.withdraw(game_id, quantity, ctx)
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
