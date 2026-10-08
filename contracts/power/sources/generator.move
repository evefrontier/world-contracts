/// Generator marker component: one or more per Creation, each at its own
/// component id. Its stats and online state live in `power_grid`, which also
/// owns the rest of its lifecycle.
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

/// Install the Generator under `component_id`. Admin-gated.
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
    let generator_component: &Component<Generator> = entity.component_ref(
        component_id,
        generator_permit(),
    );
    assert!(component::version(generator_component) == VERSION, EWrongVersion);
}

// === Package Functions ===

/// Remove the Generator. Called by `power_grid::uninstall_generator`.
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
