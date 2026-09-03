/// Opaque module state for kinds that have no on-chain logic yet.
/// Core owns `GenericModule` so it can mint `Permit<GenericModule>` internally.
module core::generic_module;

use core::{entity::Entity, mod::{Self, Module}, request::Request};
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
    module_id: u64,
    type_id: u64,
    name: Option<String>,
    data: vector<u8>,
    ctx: &mut TxContext,
): Request {
    entity.install(
        module_id,
        name,
        GenericModule { type_id, data },
        VERSION,
        module_permit(),
        ctx,
    )
}

public fun uninstall(entity: &mut Entity, module_id: u64, ctx: &mut TxContext): Request {
    let (_data, req) = extract_for_migration(entity, module_id, ctx);
    req
}

public fun extract_for_migration(
    entity: &mut Entity,
    module_id: u64,
    ctx: &mut TxContext,
): (vector<u8>, Request) {
    assert!(entity.has_module_with_type<GenericModule>(module_id), EModuleMissing);

    let (m, req) = entity.uninstall<GenericModule>(module_id, module_permit(), ctx);
    let GenericModule { type_id: _, data } = m.unwrap(module_permit());
    (data, req)
}

// === View Functions ===

public fun data(entity: &Entity, module_id: u64): vector<u8> {
    borrow_module(entity, module_id).inner().data
}

public fun type_id(entity: &Entity, module_id: u64): u64 {
    borrow_module(entity, module_id).inner().type_id
}

public fun name(entity: &Entity, module_id: u64): Option<String> {
    borrow_module(entity, module_id).name()
}

// === Private Functions ===

fun borrow_module(entity: &Entity, module_id: u64): &Module<GenericModule> {
    assert!(entity.has_module_with_type<GenericModule>(module_id), EModuleMissing);
    let m = entity.module_ref(module_id, module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    m
}

fun module_permit(): Permit<GenericModule> {
    internal::permit<GenericModule>()
}
