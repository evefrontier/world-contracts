/// Fuel bay install, uninstall, online state and deposits. A fuel bay connects
/// to the grid inside its install, offline and holding its own fuel. An
/// uninstalled bay's fuel stays on the grid as a stash until the bay is refitted
/// here or the service takes it out as a `FuelLoad`, to refit on another
/// Creation, stash elsewhere, or destroy. Borrows the grid and asks `power_grid` to
/// write the bay.
module power::grid_fuel;

use core::{access_cap, admin_service, entity::Entity, request::Request, requirement::Requirement};
use power::{fuel_bay, power_grid::{Self, Fuel, PowerGrid}};
use std::string::String;
use sui::{bcs, clock::Clock, event};

// === Errors ===

#[error(code = 0)]
const EFuelOverCapacity: vector<u8> = b"Fuel amount would exceed the fuel bay's capacity";
#[error(code = 1)]
const EZeroFuel: vector<u8> = b"Fuel amount must be greater than zero";
#[error(code = 2)]
const EFuelTypeNotAllowed: vector<u8> = b"Fuel type is not allowed by the requirement";
#[error(code = 3)]
const EBurdenAboveMax: vector<u8> = b"Fuel containment burden is above the requirement";
#[error(code = 4)]
const EFuelAmountBelowMin: vector<u8> = b"Fuel amount is below the requirement";
#[error(code = 5)]
const EFuelAmountAboveMax: vector<u8> = b"Fuel amount is above the requirement";
#[error(code = 6)]
const EFuelBayNotConnected: vector<u8> = b"Fuel bay is not connected to this power grid";
#[error(code = 7)]
const EWrongTenant: vector<u8> = b"Fuel bays can only move between entities of the same tenant";
#[error(code = 8)]
const EFuelBayAlreadyOnline: vector<u8> = b"Fuel bay is already online";
#[error(code = 9)]
const EFuelBayAlreadyOffline: vector<u8> = b"Fuel bay is already offline";
#[error(code = 10)]
const EStashMissing: vector<u8> = b"No stashed fuel for this fuel bay on this power grid";
#[error(code = 11)]
const EStashExists: vector<u8> = b"Fuel bay is already connected or stashed on this power grid";
#[error(code = 12)]
const EWrongFuelBay: vector<u8> = b"Fuel load belongs to another fuel bay";
#[error(code = 13)]
const EFuelShort: vector<u8> = b"Online fuel bays hold less fuel than the withdrawal";
#[error(code = 14)]
const ETooManyFuelBays: vector<u8> =
    b"Power grid has reached its maximum fitted and stashed fuel bays";
#[error(code = 15)]
const EFuelBayTooLarge: vector<u8> = b"Fuel bay capacity is above the maximum";

// === Structs ===

/// A fuel bay's exact fuel taken out of a grid by `take_stash`. It has no
/// abilities, so the same transaction must refit it with `install_with_fuel`,
/// stash it on a grid with `stash_load`, or destroy it with `destroy_fuel_load`.
public struct FuelLoad {
    tenant: String,
    entity_id: ID,
    fuel_bay_id: u64,
    fuel: Fuel,
}

// === Events ===

public struct FuelBayAttached has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    capacity: u64,
}

public struct FuelBayDetached has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
}

/// An uninstalled bay's fuel was stashed on the grid, by `uninstall` or `stash_load`.
public struct FuelStashed has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    quantity: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
}

/// A refitted bay took its fuel back from the stash, or arrived with it.
public struct FuelRestored has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    quantity: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
}

/// The service took a bay's stash out of the grid as a `FuelLoad`.
public struct FuelUnstashed has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    quantity: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
}

/// A fuel load was destroyed; its fuel is gone.
public struct FuelLoadDestroyed has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    quantity: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
}

public struct FuelBayToggled has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    online: bool,
}

/// The service took `quantity` (at `SCALE`) from the online bays, for a warp.
/// `remaining` is what the online bays hold after.
public struct FuelWithdrawn has copy, drop {
    entity_id: ID,
    quantity: u64,
    remaining: u64,
}

/// Fuel was loaded into a bay; the `resulting_*` values are that bay after blending.
/// `amount` is plain as deposited; `resulting_amount` is at `SCALE`.
public struct FuelAdded has copy, drop {
    entity_id: ID,
    fuel_bay_id: u64,
    fuel_type: u64,
    amount: u64,
    resulting_amount: u64,
    resulting_impulse: u64,
    resulting_containment_burden: u64,
    resulting_volatility: u64,
}

// === Public Functions ===

/// Install a fuel bay of `capacity` plain units, offline. It takes back its
/// stashed fuel if this grid holds any for `component_id`, else starts empty.
/// Admin-gated. Aborts if the stash exceeds `capacity`.
public fun install(
    entity: &mut Entity,
    component_id: u64,
    name: Option<String>,
    capacity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    connect(entity, component_id, name, capacity, option::none(), clock, ctx)
}

/// Install a fuel bay holding `load`, offline. `load` must be this bay's fuel
/// from the same tenant. Admin-gated. Aborts if the load exceeds `capacity`.
public fun install_with_fuel(
    entity: &mut Entity,
    fuel_bay_id: u64,
    name: Option<String>,
    capacity: u64,
    load: FuelLoad,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    let fuel = unpack_for(entity, fuel_bay_id, load);
    connect(entity, fuel_bay_id, name, capacity, option::some(fuel), clock, ctx)
}

/// Uninstall a fuel bay. Its exact fuel stays on this grid as a stash, which
/// never burns, until `install` refits it here or `take_stash` takes it out.
/// Admin-gated.
public fun uninstall(
    entity: &mut Entity,
    fuel_bay_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(power_grid::is_fuel_bay_connected(entity, fuel_bay_id), EFuelBayNotConnected);
    let entity_id = entity.id();
    let req = fuel_bay::uninstall(entity, fuel_bay_id, ctx);
    let grid = power_grid::grid_mut(entity);
    grid.settle(clock);
    let fuel = grid.disconnect_fuel_bay(fuel_bay_id);
    grid.stash_fuel(fuel_bay_id, fuel);
    grid.regrant(entity_id);
    event::emit(FuelBayDetached { entity_id, fuel_bay_id });
    emit_stashed(entity_id, fuel_bay_id, fuel);
    req
}

/// Move fuel bay `fuel_bay_id` from `from` to `to` with its exact fuel. It
/// arrives offline. Admin-gated: returns `from`'s request, then `to`'s.
public fun migrate(
    from: &mut Entity,
    to: &mut Entity,
    fuel_bay_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Request, Request) {
    assert!(from.key().tenant() == to.key().tenant(), EWrongTenant);
    let capacity = power_grid::fuel_bay_state(from, fuel_bay_id).capacity();
    let name = fuel_bay::name(from, fuel_bay_id);
    let from_req = uninstall(from, fuel_bay_id, clock, ctx);
    let fuel = power_grid::grid_mut(from).take_stash(fuel_bay_id);
    let to_req = connect(to, fuel_bay_id, name, capacity, fuel, clock, ctx);
    (from_req, to_req)
}

/// Take bay `fuel_bay_id`'s stash out of the grid as a `FuelLoad`, when the
/// service moves or destroys the uninstalled bay item. The request needs a
/// `manage_stash_requirement`, and the frame then requires the admin.
public fun take_stash(entity: &mut Entity, req: &mut Request, fuel_bay_id: u64): FuelLoad {
    let tenant = entity.key().tenant();
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::manage_stash_permit(),
    );
    let fuel = grid.take_stash(fuel_bay_id).destroy_or!(abort EStashMissing);
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
    event::emit(FuelUnstashed {
        entity_id,
        fuel_bay_id,
        quantity: fuel.quantity(),
        impulse: fuel.impulse(),
        containment_burden: fuel.containment_burden(),
        volatility: fuel.volatility(),
    });
    FuelLoad { tenant, entity_id, fuel_bay_id, fuel }
}

/// Stash `load` on this grid, for a bay item that arrives here uninstalled.
/// Same tenant only. The request needs a `manage_stash_requirement`, and the
/// frame then requires the admin.
public fun stash_load(entity: &mut Entity, req: &mut Request, load: FuelLoad) {
    let fuel_bay_id = load.fuel_bay_id;
    let fuel = unpack_for(entity, fuel_bay_id, load);
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::manage_stash_permit(),
    );
    assert!(
        !power_grid::bays(grid).contains(&fuel_bay_id)
            && !power_grid::stashed(grid).contains(&fuel_bay_id),
        EStashExists,
    );
    assert_room_for_bay(grid);
    grid.stash_fuel(fuel_bay_id, fuel);
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
    emit_stashed(entity_id, fuel_bay_id, fuel);
}

/// Take `quantity` of fuel (at `SCALE`) from the online bays, all or nothing,
/// each bay giving in proportion to what it holds. The game server calls it
/// before a warp with the warp's cost; an abort means no warp. Settles first, so
/// burn counts before the check. The request needs a `withdraw_fuel_requirement`,
/// and the frame then requires the admin.
public fun withdraw_fuel(entity: &mut Entity, req: &mut Request, quantity: u64, clock: &Clock) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::withdraw_fuel_permit(),
    );
    assert!(quantity > 0, EZeroFuel);
    grid.settle(clock);
    let held = grid.online_fuel().quantity();
    assert!(held >= quantity, EFuelShort);
    grid.take_from_online(quantity);
    grid.regrant(entity_id);
    event::emit(FuelWithdrawn { entity_id, quantity, remaining: held - quantity });
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Destroy a fuel load whose bay item no longer exists.
public fun destroy_fuel_load(load: FuelLoad) {
    let FuelLoad { tenant: _, entity_id, fuel_bay_id, fuel } = load;
    event::emit(FuelLoadDestroyed {
        entity_id,
        fuel_bay_id,
        quantity: fuel.quantity(),
        impulse: fuel.impulse(),
        containment_burden: fuel.containment_burden(),
        volatility: fuel.volatility(),
    });
}

/// Bring a fuel bay online or offline. An offline bay keeps its fuel and feeds
/// nothing. Settles first, because burn depends on which bays feed the grid.
public fun set_fuel_bay(
    entity: &mut Entity,
    req: &mut Request,
    fuel_bay_id: u64,
    online: bool,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (_requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::operate_grid_permit(),
    );
    assert!(power_grid::bays(grid).contains(&fuel_bay_id), EFuelBayNotConnected);
    grid.settle(clock);
    let already_online = grid.bay_state(fuel_bay_id).bay_online();
    if (online) assert!(!already_online, EFuelBayAlreadyOnline)
    else assert!(already_online, EFuelBayAlreadyOffline);
    grid.set_bay_online(fuel_bay_id, online);
    event::emit(FuelBayToggled { entity_id, fuel_bay_id, online });
    grid.regrant(entity_id);
    frame.require(access_cap::owner_requirement());
    req.enqueue(frame);
}

// TODO: an `Item` to fuel path once inventory can connect to the fuel bay.
/// Load `amount` of fuel into one bay and blend its stats by weighted average,
/// if it meets the owner's `FuelRequirement`. Supplied by the game server: `amount`
/// plain, stats at `SCALE`. The bay stores the amount at `SCALE`.
public fun deposit_fuel(
    entity: &mut Entity,
    req: &mut Request,
    fuel_bay_id: u64,
    fuel_type: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
    volatility: u64,
    clock: &Clock,
) {
    let entity_id = entity.id();
    let (requirement, mut frame, grid) = power_grid::take_grid(
        entity,
        req,
        power_grid::deposit_fuel_permit(),
    );
    assert!(amount > 0, EZeroFuel);
    enforce_fuel(&requirement, fuel_type, amount, impulse, containment_burden);
    assert!(power_grid::bays(grid).contains(&fuel_bay_id), EFuelBayNotConnected);
    grid.settle(clock);
    let bay = grid.bay_state(fuel_bay_id);
    let scaled = (amount as u128) * (power_grid::scale() as u128);
    assert_fits(bay.capacity(), (bay.fuel().quantity() as u128) + scaled);
    grid.blend_into_bay(
        fuel_bay_id,
        power_grid::new_fuel(scaled as u64, impulse, containment_burden, volatility),
    );
    let fuel = grid.bay_state(fuel_bay_id).fuel();
    event::emit(FuelAdded {
        entity_id,
        fuel_bay_id,
        fuel_type,
        amount,
        resulting_amount: fuel.quantity(),
        resulting_impulse: fuel.impulse(),
        resulting_containment_burden: fuel.containment_burden(),
        resulting_volatility: fuel.volatility(),
    });
    grid.regrant(entity_id);
    frame.require(access_cap::owner_requirement());
    frame.require(admin_service::sponsor_requirement());
    req.enqueue(frame);
}

// === View Functions ===

public fun load_entity_id(load: &FuelLoad): ID {
    load.entity_id
}

public fun load_fuel_bay_id(load: &FuelLoad): u64 {
    load.fuel_bay_id
}

public fun load_tenant(load: &FuelLoad): String {
    load.tenant
}

public fun load_fuel(load: &FuelLoad): Fuel {
    load.fuel
}

/// Quantity at `SCALE`.
public fun load_amount(load: &FuelLoad): u64 {
    load.fuel.quantity()
}

public fun load_impulse(load: &FuelLoad): u64 {
    load.fuel.impulse()
}

public fun load_containment_burden(load: &FuelLoad): u64 {
    load.fuel.containment_burden()
}

public fun load_volatility(load: &FuelLoad): u64 {
    load.fuel.volatility()
}

// === Private Functions ===

/// Unpack `load` for bay `fuel_bay_id` on `entity`. Aborts unless the load is
/// that bay's fuel and from the same tenant.
fun unpack_for(entity: &Entity, fuel_bay_id: u64, load: FuelLoad): Fuel {
    let FuelLoad { tenant, entity_id: _, fuel_bay_id: load_bay_id, fuel } = load;
    assert!(tenant == entity.key().tenant(), EWrongTenant);
    assert!(load_bay_id == fuel_bay_id, EWrongFuelBay);
    fuel
}

/// Install the bay component and connect it to the grid, offline, holding
/// `moved` fuel if given, else this grid's stash for it, else nothing.
fun connect(
    entity: &mut Entity,
    fuel_bay_id: u64,
    name: Option<String>,
    capacity: u64,
    moved: Option<Fuel>,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    assert!(capacity <= power_grid::max_fuel_bay_capacity(), EFuelBayTooLarge);
    let entity_id = entity.id();
    let req = fuel_bay::install(entity, fuel_bay_id, name, ctx);
    let grid = power_grid::grid_mut(entity);
    let stash = grid.take_stash(fuel_bay_id);
    assert!(moved.is_none() || stash.is_none(), EStashExists);
    assert_room_for_bay(grid);
    let restored = if (moved.is_some()) moved else stash;
    let fuel = restored.destroy_or!(power_grid::empty_fuel());
    assert_fits(capacity, fuel.quantity() as u128);
    grid.settle(clock);
    grid.connect_fuel_bay(fuel_bay_id, capacity, fuel);
    grid.regrant(entity_id);
    event::emit(FuelBayAttached { entity_id, fuel_bay_id, capacity });
    if (restored.is_some()) {
        event::emit(FuelRestored {
            entity_id,
            fuel_bay_id,
            quantity: fuel.quantity(),
            impulse: fuel.impulse(),
            containment_burden: fuel.containment_burden(),
            volatility: fuel.volatility(),
        });
    };
    req
}

fun emit_stashed(entity_id: ID, fuel_bay_id: u64, fuel: Fuel) {
    event::emit(FuelStashed {
        entity_id,
        fuel_bay_id,
        quantity: fuel.quantity(),
        impulse: fuel.impulse(),
        containment_burden: fuel.containment_burden(),
        volatility: fuel.volatility(),
    });
}

/// Abort unless the grid has room for one more fitted or stashed bay.
fun assert_room_for_bay(grid: &PowerGrid) {
    let held = power_grid::bays(grid).length() + power_grid::stashed(grid).length();
    assert!(held < power_grid::max_fuel_bays(), ETooManyFuelBays);
}

/// Abort unless `quantity` (at `SCALE`) fits a bay of `capacity` plain units.
fun assert_fits(capacity: u64, quantity: u128) {
    let room = (capacity as u128) * (power_grid::scale() as u128);
    assert!(quantity <= room, EFuelOverCapacity);
}

/// Abort if a deposit breaks a `FuelRequirement`. Mirrors its field order.
fun enforce_fuel(
    requirement: &Requirement,
    fuel_type: u64,
    amount: u64,
    impulse: u64,
    containment_burden: u64,
) {
    let mut encoded = bcs::new(requirement.data());
    let fuel_types = encoded.peel_vec_u64();
    let min_impulse = encoded.peel_option_u64();
    let max_containment_burden = encoded.peel_option_u64();
    let min_amount = encoded.peel_option_u64();
    let max_amount = encoded.peel_option_u64();
    assert!(fuel_types.is_empty() || fuel_types.contains(&fuel_type), EFuelTypeNotAllowed);
    min_impulse.do!(|min| power_grid::assert_impulse_at_least(impulse, min));
    max_containment_burden.do!(|max| assert!(containment_burden <= max, EBurdenAboveMax));
    min_amount.do!(|min| assert!(amount >= min, EFuelAmountBelowMin));
    max_amount.do!(|max| assert!(amount <= max, EFuelAmountAboveMax));
}

// === Test Functions ===

/// `(entity_id, quantity, remaining)`.
#[test_only]
public fun fuel_withdrawn_fields(withdrawn: &FuelWithdrawn): (ID, u64, u64) {
    (withdrawn.entity_id, withdrawn.quantity, withdrawn.remaining)
}

/// `(entity_id, fuel_bay_id, fuel_type, amount, resulting_amount, resulting_impulse,
/// resulting_containment_burden, resulting_volatility)`.
#[test_only]
public fun fuel_added_fields(added: &FuelAdded): (ID, u64, u64, u64, u64, u64, u64, u64) {
    (
        added.entity_id,
        added.fuel_bay_id,
        added.fuel_type,
        added.amount,
        added.resulting_amount,
        added.resulting_impulse,
        added.resulting_containment_burden,
        added.resulting_volatility,
    )
}

/// `(entity_id, fuel_bay_id, capacity)`.
#[test_only]
public fun fuel_bay_attached_fields(attached: &FuelBayAttached): (ID, u64, u64) {
    (attached.entity_id, attached.fuel_bay_id, attached.capacity)
}

/// `(entity_id, fuel_bay_id, online)`.
#[test_only]
public fun fuel_bay_toggled_fields(toggled: &FuelBayToggled): (ID, u64, bool) {
    (toggled.entity_id, toggled.fuel_bay_id, toggled.online)
}

/// `(entity_id, fuel_bay_id, quantity, volatility)`.
#[test_only]
public fun fuel_stashed_fields(stashed: &FuelStashed): (ID, u64, u64, u64) {
    (stashed.entity_id, stashed.fuel_bay_id, stashed.quantity, stashed.volatility)
}

/// `(entity_id, fuel_bay_id, quantity, volatility)`.
#[test_only]
public fun fuel_restored_fields(restored: &FuelRestored): (ID, u64, u64, u64) {
    (restored.entity_id, restored.fuel_bay_id, restored.quantity, restored.volatility)
}

/// `(entity_id, fuel_bay_id, quantity, volatility)`.
#[test_only]
public fun fuel_unstashed_fields(taken: &FuelUnstashed): (ID, u64, u64, u64) {
    (taken.entity_id, taken.fuel_bay_id, taken.quantity, taken.volatility)
}

/// `(entity_id, fuel_bay_id, quantity, volatility)`.
#[test_only]
public fun fuel_load_destroyed_fields(destroyed: &FuelLoadDestroyed): (ID, u64, u64, u64) {
    (destroyed.entity_id, destroyed.fuel_bay_id, destroyed.quantity, destroyed.volatility)
}
