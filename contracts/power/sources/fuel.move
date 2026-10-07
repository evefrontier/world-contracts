/// Fuel component marker: one or more per Creation, each at its own component
/// id. Its capacity and the pooled fuel live in `power_grid`, which also owns
/// the rest of its lifecycle.
module power::fuel;

use core::{component::{Self, Component}, entity::Entity, request::Request};
use std::{internal::Permit, string::String};
use sui::event;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Fuel component version does not match the package version";
#[error(code = 1)]
const EComponentMissing: vector<u8> = b"Fuel component is not installed on this entity";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// A fitted fuel bay. Marks the component slot; its state is in the grid.
public struct Fuel has store {}

// === Events ===

public struct FuelInstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
}

public struct FuelUninstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
}

// === Public Functions ===

/// Install the Fuel bay under `component_id`. Admin-gated.
public fun install(
    entity: &mut Entity,
    component_id: u64,
    name: Option<String>,
    ctx: &mut TxContext,
): Request {
    let entity_id = entity.id();
    let req = entity.install(component_id, name, Fuel {}, VERSION, fuel_permit(), ctx);
    event::emit(FuelInstalled { entity_id, component_id });
    req
}

// === View Functions ===

/// Abort unless a Fuel bay of this version is installed under `component_id`.
public fun assert_installed(entity: &Entity, component_id: u64) {
    assert!(entity.has_component_with_type<Fuel>(component_id), EComponentMissing);
    let c: &Component<Fuel> = entity.component_ref(component_id, fuel_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
}

// === Package Functions ===

/// Remove the Fuel bay. Called by `power_grid::uninstall_fuel_source`.
public(package) fun uninstall(
    entity: &mut Entity,
    component_id: u64,
    ctx: &mut TxContext,
): Request {
    assert_installed(entity, component_id);
    let (fuel_component, req) = entity.uninstall<Fuel>(component_id, fuel_permit(), ctx);
    let Fuel {} = fuel_component.unwrap(fuel_permit());
    event::emit(FuelUninstalled { entity_id: entity.id(), component_id });
    req
}

// === Private Functions ===

fun fuel_permit(): Permit<Fuel> {
    internal::permit<Fuel>()
}
