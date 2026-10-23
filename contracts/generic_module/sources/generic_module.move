/// Opaque in-game module state for fittings that have no on-chain logic yet.
/// Installed as `Component<GenericModule>`. Installing connects it to the Creation's
/// power grid; uninstalling disconnects it.
module generic_module::generic_module;

use core::{component::{Self, Component}, entity::Entity, request::Request};
use power::{grid_load, power_grid::{Self, DrawKind, PowerKind}};
use std::{internal::Permit, string::String};
use sui::clock::Clock;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Generic module version does not match the package version";
#[error(code = 1)]
const EModuleMissing: vector<u8> = b"Generic module is not installed on this entity";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

public struct GenericModule has store {
    type_id: u64,
    data: vector<u8>,
}

// === Public Functions ===

/// Install a generic module and connect it to the power grid. Aborts if the
/// Creation has no grid.
public fun install(
    entity: &mut Entity,
    component_id: u64,
    type_id: u64,
    name: Option<String>,
    data: vector<u8>,
    power_req: u64,
    draw_kind: DrawKind,
    power_kind: PowerKind,
    priority: u64,
    line_loss: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    let req = entity.install(
        component_id,
        name,
        GenericModule { type_id, data },
        VERSION,
        generic_module_permit(),
        ctx,
    );
    let power = power_grid::module_power_spec(
        power_req,
        draw_kind,
        power_kind,
        priority,
        line_loss,
    );
    grid_load::connect<GenericModule>(
        entity,
        component_id,
        power,
        generic_module_permit(),
        clock,
    );
    req
}

/// Move the generic module at `component_id` from `from` to `to` with its data,
/// and its grid connection with it. Admin-gated: returns `from`'s request,
/// then `to`'s.
public fun migrate(
    from: &mut Entity,
    to: &mut Entity,
    component_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Request, Request) {
    borrow_module(from, component_id);
    let (c, from_req) = from.uninstall<GenericModule>(
        component_id,
        generic_module_permit(),
        ctx,
    );
    let name = c.name();
    let generic = c.unwrap(generic_module_permit());
    let to_req = to.install(component_id, name, generic, VERSION, generic_module_permit(), ctx);
    grid_load::migrate<GenericModule>(from, to, component_id, generic_module_permit(), clock);
    (from_req, to_req)
}

/// Uninstall a generic module and disconnect it from the power grid.
public fun uninstall(
    entity: &mut Entity,
    component_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Request {
    let (_data, req) = extract_for_migration(entity, component_id, clock, ctx);
    req
}

/// Uninstall a generic module and return its bytes, disconnecting it from the power grid.
public fun extract_for_migration(
    entity: &mut Entity,
    component_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (vector<u8>, Request) {
    assert!(entity.has_component_with_type<GenericModule>(component_id), EModuleMissing);

    let (c, req) = entity.uninstall<GenericModule>(component_id, generic_module_permit(), ctx);
    let GenericModule { type_id: _, data } = c.unwrap(generic_module_permit());
    grid_load::disconnect<GenericModule>(entity, component_id, generic_module_permit(), clock);
    (data, req)
}

// === View Functions ===

public fun data(entity: &Entity, component_id: u64): vector<u8> {
    borrow_module(entity, component_id).inner().data
}

public fun type_id(entity: &Entity, component_id: u64): u64 {
    borrow_module(entity, component_id).inner().type_id
}

public fun name(entity: &Entity, component_id: u64): Option<String> {
    borrow_module(entity, component_id).name()
}

// === Private Functions ===

fun borrow_module(entity: &Entity, component_id: u64): &Component<GenericModule> {
    assert!(entity.has_component_with_type<GenericModule>(component_id), EModuleMissing);
    let c = entity.component_ref(component_id, generic_module_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    c
}

fun generic_module_permit(): Permit<GenericModule> {
    internal::permit<GenericModule>()
}
