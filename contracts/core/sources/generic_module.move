/// Opaque in-game module state for fittings that have no on-chain logic yet.
/// Installed as `Component<GenericModule>`. Core owns the type so it can mint
/// `Permit<GenericModule>` internally.
module core::generic_module;

use core::{component::{Self, Component}, entity::Entity, request::Request};
use std::{internal::Permit, string::String};

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

public fun install(
    entity: &mut Entity,
    component_id: u64,
    type_id: u64,
    name: Option<String>,
    data: vector<u8>,
    ctx: &mut TxContext,
): Request {
    entity.install(
        component_id,
        name,
        GenericModule { type_id, data },
        VERSION,
        generic_module_permit(),
        ctx,
    )
}

public fun uninstall(entity: &mut Entity, component_id: u64, ctx: &mut TxContext): Request {
    let (_data, req) = extract_for_migration(entity, component_id, ctx);
    req
}

public fun extract_for_migration(
    entity: &mut Entity,
    component_id: u64,
    ctx: &mut TxContext,
): (vector<u8>, Request) {
    assert!(entity.has_component_with_type<GenericModule>(component_id), EModuleMissing);

    let (c, req) = entity.uninstall<GenericModule>(component_id, generic_module_permit(), ctx);
    let GenericModule { type_id: _, data } = c.unwrap(generic_module_permit());
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
