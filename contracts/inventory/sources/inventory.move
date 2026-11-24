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
    admin_service,
    component::{Self, Component},
    entity::Entity,
    request::{Request, Frame},
    requirement::{Self, Requirement}
};
use inventory::item::{Self, Item, ItemBag};
use power::{grid_fuel, grid_load, power_grid::{Self, DrawKind}};
use std::{internal::Permit, string::String};
use sui::{bcs, clock::Clock, event};
use variant::variant::{Variant, VariantKey};

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
#[error(code = 6)]
const EWrongTenant: vector<u8> = b"Inventory can only move between entities of the same tenant";
#[error(code = 7)]
const EBatchLengthMismatch: vector<u8> = b"keys and quantities must be the same length";
#[error(code = 8)]
const EEmptyBatch: vector<u8> = b"Batch must not be empty";
#[error(code = 9)]
const EWrongVariant: vector<u8> = b"Item is not this variant";
#[error(code = 10)]
const EVariantWithoutType: vector<u8> = b"A rule's variant_id needs its type_id";
#[error(code = 11)]
const EItemVariantNotAllowed: vector<u8> = b"Item variant not permitted by the requirement";

// === Constants ===

const VERSION: u64 = 1;

/// Most entries per batched event (`ItemsDestroyed`, `ItemsWithdrawn`,
/// `ItemsDeposited`). A full batch is at most ~64 KB of BCS, well under Sui's
/// 256 KB per-event limit.
const EVENT_BATCH_SIZE: u64 = 1000;

// === Structs ===

/// One balance area with its own volume cap; the component's inner state.
public struct Inventory has store {
    type_id: u64,
    capacity: u64,
    used: u64,
    items: ItemBag,
}

/// Requirement config shared by deposit, withdraw, and bridge handlers.
/// `variant_id` narrows `type_id` to one variant; `none` admits every variant.
public struct ItemRequirement has drop {
    type_id: Option<u64>,
    variant_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
}

public struct BridgeIn(ItemRequirement) has drop;
public struct BridgeOut(ItemRequirement) has drop;
public struct Deposit(ItemRequirement) has drop;
public struct Withdrawal(ItemRequirement) has drop;

// === Events ===

/// Emitted when an inventory is installed. `inventory_type_id` is the
/// inventory's own kind (`Inventory.type_id`), never an item type.
public struct InventoryInstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
    inventory_type_id: u64,
    name: Option<String>,
    capacity: u64,
}

/// Emitted when an inventory is uninstalled, ahead of the `batch_count`
/// `ItemsDestroyed` events listing its `balance_count` balances. `used_before`
/// is the volume destroyed; unlike a bridge-out, none of it returns to the game.
public struct InventoryUninstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
    used_before: u64,
    balance_count: u64,
    batch_count: u64,
}

/// A fuel `Item` was burned into fuel bay `fuel_bay_id` of `entity_id`. The service
/// reports it to the game; `grid_fuel::FuelAdded`, emitted just before, has the bay's values.
public struct FuelItemDeposited has copy, drop {
    item_id: ID,
    key: VariantKey,
    quantity: u64,
    entity_id: ID,
    fuel_bay_id: u64,
}

/// Inventory moved between entities with balances intact.
public struct InventoryMigrated has copy, drop {
    from_entity_id: ID,
    to_entity_id: ID,
    component_id: u64,
    inventory_type_id: u64,
    capacity: u64,
    used: u64,
}

// === Public Functions ===

/// Build and install the storage component under `component_id` with the
/// Inventory's volume `capacity` in nano-m³. `name` is an optional display label and is not
/// unique. The power fields are the spec the Inventory connects to the Creation's
/// power grid with. Aborts if the grid is not installed.
public fun install(
    entity: &mut Entity,
    component_id: u64,
    type_id: u64,
    name: Option<String>,
    capacity: u64,
    power_req: u64,
    draw_kind: DrawKind,
    priority: u64,
    line_loss: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    let entity_id = entity.id();
    let inventory = Inventory { type_id, capacity, used: 0, items: item::new_bag(ctx) };
    let req = entity.install(
        component_id,
        name,
        inventory,
        VERSION,
        inventory_permit(),
        ctx,
    );
    let power = power_grid::module_power_spec(
        power_req,
        draw_kind,
        priority,
        line_loss,
    );
    grid_load::connect<Inventory>(entity, component_id, power, inventory_permit(), clock);
    event::emit(InventoryInstalled {
        entity_id,
        component_id,
        inventory_type_id: type_id,
        name,
        capacity,
    });
    req
}

/// Remove the storage component and disconnect it from the power grid. Aborts if it was never
/// installed. Emits `InventoryUninstalled`, then destroys the Inventory's
/// balances in `ItemsDestroyed` batches so the game client is notified.
public fun uninstall(
    entity: &mut Entity,
    component_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(entity.has_component_with_type<Inventory>(component_id), EComponentMissing);

    let (inv_component, req) = entity.uninstall<Inventory>(
        component_id,
        inventory_permit(),
        ctx,
    );
    grid_load::disconnect<Inventory>(entity, component_id, inventory_permit(), clock);
    let entity_id = entity.id();
    let Inventory { items, type_id: _, capacity: _, used } = inv_component.unwrap(
        inventory_permit(),
    );
    let balance_count = items.balance_count();
    event::emit(InventoryUninstalled {
        entity_id,
        component_id,
        used_before: used,
        balance_count,
        batch_count: balance_count.div_ceil(EVENT_BATCH_SIZE),
    });
    item::drain_and_destroy(items, entity_id, component_id, EVENT_BATCH_SIZE);
    req
}

/// Move the Inventory at `component_id` from `from` to `to` with its items, and
/// its grid connection with it. Nothing is burned. Admin-gated: returns
/// `from`'s request, then `to`'s.
public fun migrate(
    from: &mut Entity,
    to: &mut Entity,
    component_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Request, Request) {
    assert!(from.has_component_with_type<Inventory>(component_id), EComponentMissing);
    assert!(from.key().tenant() == to.key().tenant(), EWrongTenant);
    borrow_component(from, component_id);
    let (inv_component, from_req) = from.uninstall<Inventory>(
        component_id,
        inventory_permit(),
        ctx,
    );
    let name = inv_component.name();
    let inventory = inv_component.unwrap(inventory_permit());
    let migrated = InventoryMigrated {
        from_entity_id: from.id(),
        to_entity_id: to.id(),
        component_id,
        inventory_type_id: inventory.type_id,
        capacity: inventory.capacity,
        used: inventory.used,
    };
    let to_req = to.install(component_id, name, inventory, VERSION, inventory_permit(), ctx);
    grid_load::migrate<Inventory>(from, to, component_id, inventory_permit(), clock);
    event::emit(migrated);
    (from_req, to_req)
}

/// Game to chain bridge: mint `quantity` (base units of `variant`) into the
/// entity's Inventory. The variant must be in the entity's tenant. Pushes a
/// sponsor requirement. The owner can sign. The gas sponsor must be on `AdminACL`.
public fun game_item_to_chain_inventory(
    entity: &mut Entity,
    req: &mut Request,
    variant: &Variant,
    quantity: u64,
) {
    let entity_id = entity.id();
    let key = variant.key();
    assert_tenant(entity, key);
    let (requirement, mut frame, inv) = take(entity, req, bridge_in_permit());
    let module_id = module_id(&requirement);
    enforce_rule(&requirement, key, quantity);
    inv
        .items
        .mint(
            key,
            quantity,
            variant.unit_volume(),
            variant.decimals(),
            entity_id,
            module_id,
            &mut inv.used,
        );
    assert!(inv.used <= inv.capacity, EOverCapacity);
    frame.require(admin_service::sponsor_requirement());
    frame.require(online_requirement(entity, module_id));
    req.enqueue(frame);
}

/// Chain to game bridge: burn `quantity` of `key` from the entity's Inventory.
/// Pushes a sponsor requirement. The owner can sign. The gas sponsor must be on `AdminACL`.
public fun chain_item_to_game_inventory(
    entity: &mut Entity,
    req: &mut Request,
    key: VariantKey,
    quantity: u64,
) {
    let entity_id = entity.id();
    assert_tenant(entity, key);
    let (requirement, mut frame, inv) = take(entity, req, bridge_out_permit());
    let module_id = module_id(&requirement);
    enforce_rule(&requirement, key, quantity);
    inv.items.burn(key, quantity, entity_id, module_id, &mut inv.used);
    frame.require(admin_service::sponsor_requirement());
    frame.require(online_requirement(entity, module_id));
    req.enqueue(frame);
}

/// Deposit a standalone `Item` into the entity's Inventory, joining the stack of
/// its variant. Aborts unless the item comes from this entity or from a docked
/// entity, and is in this entity's tenant. Pushes an `OnlineRequirement` for
/// this inventory's grant. The caller satisfies it with `grid_load::assert_online`.
public fun deposit(entity: &mut Entity, req: &mut Request, item: Item) {
    let entity_id = entity.id();
    entity.assert_docked(item.source());
    assert_tenant(entity, item.key());
    let key = item.key();
    let quantity = item.quantity();
    let (requirement, mut frame, inv) = take(entity, req, deposit_permit());
    let module_id = module_id(&requirement);
    enforce_rule(&requirement, key, quantity);
    inv.items.deposit(item, entity_id, module_id, &mut inv.used);
    assert!(inv.used <= inv.capacity, EOverCapacity);
    frame.require(online_requirement(entity, module_id));
    req.enqueue(frame);
}

/// Withdraw `quantity` of `key` from the entity's Inventory as a fresh `Item`.
/// No docking check: the `Item` can only leave the transaction through `deposit`,
/// which checks its source. Pushes an `OnlineRequirement` for this
/// inventory's grant. The caller satisfies it with `grid_load::assert_online`.
public fun withdraw(
    entity: &mut Entity,
    req: &mut Request,
    key: VariantKey,
    quantity: u64,
    ctx: &mut TxContext,
): Item {
    let source = entity.id();
    let (requirement, mut frame, inv) = take(entity, req, withdrawal_permit());
    let module_id = module_id(&requirement);
    enforce_rule(&requirement, key, quantity);
    let item = inv.items.withdraw(key, quantity, source, module_id, &mut inv.used, ctx);
    frame.require(online_requirement(entity, module_id));
    req.enqueue(frame);
    item
}

/// `deposit` for every `items` entry under one `Deposit` requirement. Every
/// entry must be the rule's type and variant, and its quantity bounds apply to the batch's
/// total, so one requirement never admits more than one `deposit` could. Emits `ItemsDeposited` in batches of at most
/// `EVENT_BATCH_SIZE`. Aborts if `items` is empty.
public fun deposit_batch(entity: &mut Entity, req: &mut Request, items: vector<Item>) {
    assert!(!items.is_empty(), EEmptyBatch);
    let entity_id = entity.id();
    let mut total = 0;
    let mut keys = vector[];
    items.do_ref!(|item| {
        entity.assert_docked(item.source());
        assert_tenant(entity, item.key());
        total = total + item.quantity();
        keys.push_back(item.key());
    });
    let (requirement, mut frame, inv) = take(entity, req, deposit_permit());
    let module_id = module_id(&requirement);
    enforce_batch_rule(&requirement, &keys, total);
    inv.items.deposit_batch(items, entity_id, module_id, &mut inv.used, EVENT_BATCH_SIZE);
    assert!(inv.used <= inv.capacity, EOverCapacity);
    frame.require(online_requirement(entity, module_id));
    req.enqueue(frame);
}

/// `withdraw` of `quantities[i]` of `keys[i]` for each `i` under one
/// `Withdrawal` requirement. Every entry must be the rule's type and variant, and its
/// quantity bounds apply to the batch's total, so one requirement never
/// releases more than one `withdraw` could. Returns the
/// `Item`s in input order and emits `ItemsWithdrawn` in batches of at most
/// `EVENT_BATCH_SIZE`. Aborts if the vectors are empty or differ in length.
public fun withdraw_batch(
    entity: &mut Entity,
    req: &mut Request,
    keys: vector<VariantKey>,
    quantities: vector<u64>,
    ctx: &mut TxContext,
): vector<Item> {
    assert!(keys.length() == quantities.length(), EBatchLengthMismatch);
    assert!(!keys.is_empty(), EEmptyBatch);
    let source = entity.id();
    let (requirement, mut frame, inv) = take(entity, req, withdrawal_permit());
    let module_id = module_id(&requirement);
    let mut total = 0;
    quantities.do_ref!(|q| total = total + *q);
    enforce_batch_rule(&requirement, &keys, total);
    let items = inv
        .items
        .withdraw_batch(
            keys,
            quantities,
            source,
            module_id,
            &mut inv.used,
            EVENT_BATCH_SIZE,
            ctx,
        );
    frame.require(online_requirement(entity, module_id));
    req.enqueue(frame);
    items
}

/// Burn a fuel `Item` into fuel bay `fuel_bay_id` of the entity. Aborts unless the
/// item comes from this entity or a docked one, is in this entity's tenant, and is
/// `variant`. The fuel loads through `grid_fuel::deposit_fuel`: the next requirement
/// must be the grid's `DepositFuel` (the owner's fuel rules apply), and it requires
/// the owner and the sponsor, so fuel never enters a bay without the game service.
public fun deposit_fuel_item(
    entity: &mut Entity,
    req: &mut Request,
    item: Item,
    variant: &Variant,
    fuel_bay_id: u64,
    clock: &Clock,
) {
    entity.assert_docked(item.source());
    assert_tenant(entity, item.key());
    assert!(item.key() == variant.key(), EWrongVariant);
    let item_id = object::id(&item);
    let (key, quantity) = item.burn_item();
    grid_fuel::deposit_fuel(entity, req, fuel_bay_id, variant, quantity, clock);
    event::emit(FuelItemDeposited { item_id, key, quantity, entity_id: entity.id(), fuel_bay_id });
}

/// Build a bridge-in requirement on component `component_id`. `none` allows any
/// type, variant or amount. `variant_id` needs `type_id`; without it, any
/// variant of the type passes. Quantities are in the variant's base units.
public fun bridge_in_requirement(
    component_id: u64,
    type_id: Option<u64>,
    variant_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id),
        BridgeIn(rule(type_id, variant_id, min_quantity, max_quantity)),
    )
}

/// Build a bridge-out requirement on component `component_id`. See `bridge_in_requirement`.
public fun bridge_out_requirement(
    component_id: u64,
    type_id: Option<u64>,
    variant_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id),
        BridgeOut(rule(type_id, variant_id, min_quantity, max_quantity)),
    )
}

/// Build a deposit requirement on component `component_id`. See `bridge_in_requirement`.
public fun deposit_requirement(
    component_id: u64,
    type_id: Option<u64>,
    variant_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id),
        Deposit(rule(type_id, variant_id, min_quantity, max_quantity)),
    )
}

/// Build a withdraw requirement on component `component_id`. See `bridge_in_requirement`.
public fun withdraw_requirement(
    component_id: u64,
    type_id: Option<u64>,
    variant_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): Requirement {
    requirement::from_config(
        option::some(component_id),
        Withdrawal(rule(type_id, variant_id, min_quantity, max_quantity)),
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

/// Current balance of `key` in the entity's Inventory, in base units. Read-only;
/// for clients querying state.
public fun balance_of(entity: &Entity, component_id: u64, key: VariantKey): u64 {
    inventory(entity, component_id).items.balance(key)
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

fun module_id(requirement: &Requirement): u64 {
    requirement.component_id().destroy_some()
}

/// `OnlineRequirement` for the grant stored when this inventory connected.
fun online_requirement(entity: &Entity, module_id: u64): Requirement {
    let state = power_grid::module_state(power_grid::power_grid(entity), module_id);
    power_grid::online_requirement(
        module_id,
        power_grid::power_req(&state),
        power_grid::draw_kind(&state),
    )
}

fun rule(
    type_id: Option<u64>,
    variant_id: Option<u64>,
    min_quantity: Option<u64>,
    max_quantity: Option<u64>,
): ItemRequirement {
    // A variant ID only names a variant within its type.
    assert!(variant_id.is_none() || type_id.is_some(), EVariantWithoutType);
    ItemRequirement { type_id, variant_id, min_quantity, max_quantity }
}

/// Decode the `ItemRequirement` config and assert the operation satisfies it.
fun enforce_rule(requirement: &Requirement, key: VariantKey, quantity: u64) {
    enforce_batch_rule(requirement, &vector[key], quantity)
}

/// The rule for everything one requirement moves: each of `keys` must be the
/// allowed type and variant, and `total` quantity must be within the bounds.
/// Mirrors field order: type_id, variant_id, min, max.
fun enforce_batch_rule(requirement: &Requirement, keys: &vector<VariantKey>, total: u64) {
    let mut b = bcs::new(requirement.data());
    let allowed_type = b.peel_option_u64();
    let allowed_variant = b.peel_option_u64();
    let min_quantity = b.peel_option_u64();
    let max_quantity = b.peel_option_u64();
    allowed_type.do!(|t| keys.do_ref!(|key| assert!(key.type_id() == t, EItemTypeNotAllowed)));
    allowed_variant.do!(
        |v| keys.do_ref!(|key| assert!(key.variant_id() == v, EItemVariantNotAllowed)),
    );
    min_quantity.do!(|m| assert!(total >= m, EQuantityBelowMin));
    max_quantity.do!(|m| assert!(total <= m, EQuantityAboveMax));
}

/// Abort unless `key` is in the entity's tenant.
fun assert_tenant(entity: &Entity, key: VariantKey) {
    assert!(key.tenant() == entity.key().tenant(), EWrongTenant);
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

// === Test Functions ===

#[test_only]
public fun installed_fields(e: &InventoryInstalled): (ID, u64, u64, Option<String>, u64) {
    (e.entity_id, e.component_id, e.inventory_type_id, e.name, e.capacity)
}

#[test_only]
public fun uninstalled_fields(e: &InventoryUninstalled): (ID, u64, u64, u64, u64) {
    (e.entity_id, e.component_id, e.used_before, e.balance_count, e.batch_count)
}

#[test_only]
public fun event_batch_size(): u64 { EVENT_BATCH_SIZE }

/// `(item_id, key, quantity, entity_id, fuel_bay_id)`.
#[test_only]
public fun fuel_item_deposited_fields(e: &FuelItemDeposited): (ID, VariantKey, u64, ID, u64) {
    (e.item_id, e.key, e.quantity, e.entity_id, e.fuel_bay_id)
}

#[test_only]
public fun migrated_fields(e: &InventoryMigrated): (ID, ID, u64, u64, u64, u64) {
    (e.from_entity_id, e.to_entity_id, e.component_id, e.inventory_type_id, e.capacity, e.used)
}
