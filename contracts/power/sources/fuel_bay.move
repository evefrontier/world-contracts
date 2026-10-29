/// Fuel bay marker component: one or more per Creation, each at its own
/// component id. Its capacity, online state and fuel live in `power_grid`,
/// which also owns the rest of its lifecycle.
module power::fuel_bay;

use core::{component::{Self, Component}, entity::Entity, request::Request};
use std::{internal::Permit, string::String};
use sui::event;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"FuelBay component version does not match the package version";
#[error(code = 1)]
const EComponentMissing: vector<u8> = b"FuelBay component is not installed on this entity";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// A fitted fuel bay. Marks the component slot; its state is in the grid.
public struct FuelBay has store {}

// === Events ===

public struct FuelBayInstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
}

public struct FuelBayUninstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
}

// === Public Functions ===

/// Install the fuel bay under `component_id`. Admin-gated.
public(package) fun install(
    entity: &mut Entity,
    component_id: u64,
    name: Option<String>,
    ctx: &mut TxContext,
): Request {
    let entity_id = entity.id();
    let req = entity.install(component_id, name, FuelBay {}, VERSION, fuel_bay_permit(), ctx);
    event::emit(FuelBayInstalled { entity_id, component_id });
    req
}

// === View Functions ===

/// Abort unless a fuel bay of this version is installed under `component_id`.
public fun assert_installed(entity: &Entity, component_id: u64) {
    assert!(entity.has_component_with_type<FuelBay>(component_id), EComponentMissing);
    let bay_component: &Component<FuelBay> = entity.component_ref(component_id, fuel_bay_permit());
    assert!(component::version(bay_component) == VERSION, EWrongVersion);
}

// === Package Functions ===

/// Remove the fuel bay. Called by `grid_fuel::uninstall`.
public(package) fun uninstall(
    entity: &mut Entity,
    component_id: u64,
    ctx: &mut TxContext,
): Request {
    assert_installed(entity, component_id);
    let (bay_component, req) = entity.uninstall<FuelBay>(component_id, fuel_bay_permit(), ctx);
    let FuelBay {} = bay_component.unwrap(fuel_bay_permit());
    event::emit(FuelBayUninstalled { entity_id: entity.id(), component_id });
    req
}

/// Display name of the fuel bay at `component_id`.
public(package) fun name(entity: &Entity, component_id: u64): Option<String> {
    assert_installed(entity, component_id);
    let c: &Component<FuelBay> = entity.component_ref(component_id, fuel_bay_permit());
    c.name()
}

// === Private Functions ===

fun fuel_bay_permit(): Permit<FuelBay> {
    internal::permit<FuelBay>()
}
