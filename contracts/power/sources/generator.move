/// Generator component installed on an `Entity`: one or more per Creation, each
/// at its own component id. While online, it contributes its output to the
/// sibling `PowerGrid` and burns the grid's pooled fuel.
///
/// This module only owns the marker component. The Generator's stats and online
/// state live in the grid (`power_grid::GeneratorState`), and the rest of the
/// lifecycle is on `power_grid`:
/// 1. `install` (admin) fits the component.
/// 2. `power_grid::register_generator` (admin) adds it to the grid, offline.
/// 3. `power_grid::set_generator` (owner-configured actions) toggles it.
/// 4. `power_grid::unregister_generator` (admin) removes it from the grid; it
///    must be offline.
/// 5. `power_grid::uninstall_generator` (admin) removes the component; it must
///    be unregistered.
///
/// This module doesn't depend on `power_grid`, so the grid can call
/// `assert_installed` without a dependency cycle.
module power::generator;

use core::{component::{Self, Component}, entity::Entity, request::Request};
use std::{internal::Permit, string::String};
use sui::event;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Generator component version does not match the package version";
#[error(code = 1)]
const EComponentMissing: vector<u8> = b"Generator component is not installed on this entity";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// A fitted power generator. Marks the component slot; its state is in the grid.
public struct Generator has store {}

// === Events ===

public struct GeneratorInstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
}

public struct GeneratorUninstalled has copy, drop {
    entity_id: ID,
    component_id: u64,
}

// === Public Functions ===

/// Install the Generator component under `component_id`. Admin-gated by
/// `entity::install`. Follow with `power_grid::register_generator`.
public fun install(
    entity: &mut Entity,
    component_id: u64,
    name: Option<String>,
    ctx: &mut TxContext,
): Request {
    let entity_id = entity.id();
    let req = entity.install(component_id, name, Generator {}, VERSION, generator_permit(), ctx);
    event::emit(GeneratorInstalled { entity_id, component_id });
    req
}

// === View Functions ===

/// Abort unless a Generator of this version is installed under `component_id`.
public fun assert_installed(entity: &Entity, component_id: u64) {
    assert!(entity.has_component_with_type<Generator>(component_id), EComponentMissing);
    let c: &Component<Generator> = entity.component_ref(component_id, generator_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
}

// === Package Functions ===

/// Remove the Generator component. Called by `power_grid::uninstall_generator`,
/// which first checks it is unregistered. Admin-gated by `entity::uninstall`.
public(package) fun uninstall(
    entity: &mut Entity,
    component_id: u64,
    ctx: &mut TxContext,
): Request {
    assert_installed(entity, component_id);
    let (generator_component, req) = entity.uninstall<Generator>(
        component_id,
        generator_permit(),
        ctx,
    );
    let Generator {} = generator_component.unwrap(generator_permit());
    event::emit(GeneratorUninstalled { entity_id: entity.id(), component_id });
    req
}

// === Private Functions ===

fun generator_permit(): Permit<Generator> {
    internal::permit<Generator>()
}
