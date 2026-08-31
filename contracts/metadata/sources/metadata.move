/// Display metadata module installable on any `Entity`.
///
/// Holds `name`, `description`, and `url`. Owners expose an `edit` action that
/// includes `edit_requirement`; callers satisfy it via `edit`.
module metadata::metadata;

use core::{
    behavior_type::{Self, BehaviorType},
    entity::Entity,
    entity_key::EntityKey,
    mod::{Self, Module},
    request::Request,
    requirement::{Self, Requirement}
};
use std::{internal::Permit, string::{Self, String}};
use sui::event;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Metadata module version does not match the package version";
#[error(code = 1)]
const EModuleMissing: vector<u8> = b"Metadata module is not installed on this entity";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"metadata";

// === Structs ===

public struct Metadata has store {
    name: String,
    description: String,
    url: String,
}

/// Requirement marker satisfied by `edit`.
public struct Edit() has drop;

// === Events ===

public struct MetadataChanged has copy, drop {
    entity_id: ID,
    entity_key: EntityKey,
    name: String,
    description: String,
    url: String,
}

// === Public Functions ===

/// Build and install the metadata module with the given display fields.
/// Empty strings are allowed.
public fun install(
    entity: &mut Entity,
    type_id: u64,
    name: String,
    description: String,
    url: String,
    ctx: &mut TxContext,
): Request {
    let metadata = Metadata { name, description, url };
    emit_changed(entity, &metadata);
    entity.install(
        module_id(),
        type_id,
        option::some(behavior_type::metadata()),
        option::some(module_label()),
        metadata,
        VERSION,
        module_permit(),
        ctx,
    )
}

/// Remove the metadata module, discarding its state. Aborts if missing.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(entity.has_module_with_type<Metadata>(module_id()), EModuleMissing);

    let (m, req) = entity.uninstall<Metadata>(module_id(), module_permit(), ctx);
    let Metadata { name: _, description: _, url: _ } = m.unwrap(module_permit());
    req
}

/// Replace all display fields. Next requirement must be this module's `Edit`.
public fun edit(
    entity: &mut Entity,
    req: &mut Request,
    name: String,
    description: String,
    url: String,
) {
    let entity_id = entity.id();
    let entity_key = entity.key();
    let m: &mut Module<Metadata> = entity.module_mut(req, module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    let (_requirement, frame) = req.take_next(edit_permit());
    let metadata = m.inner_mut();
    metadata.name = name;
    metadata.description = description;
    metadata.url = url;
    event::emit(MetadataChanged {
        entity_id,
        entity_key,
        name: metadata.name,
        description: metadata.description,
        url: metadata.url,
    });
    frame.destroy_empty_frame();
}

/// Build an edit requirement targeting the metadata module slot.
public fun edit_requirement(): Requirement {
    requirement::from_config(option::some(module_id()), Edit())
}

// === View Functions ===

public fun name(entity: &Entity): String {
    borrow(entity).name
}

public fun description(entity: &Entity): String {
    borrow(entity).description
}

public fun url(entity: &Entity): String {
    borrow(entity).url
}

public fun module_id(): u64 {
    mod::id_from_name(NAME)
}

public fun type_id(entity: &Entity): u64 {
    borrow_module(entity).type_id()
}

public fun behaviour_type_id(entity: &Entity): Option<BehaviorType> {
    borrow_module(entity).behaviour_type_id()
}

// === Private Functions ===

fun borrow_module(entity: &Entity): &Module<Metadata> {
    let m: &Module<Metadata> = entity.module_ref(module_id(), module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    m
}

fun borrow(entity: &Entity): &Metadata {
    borrow_module(entity).inner()
}

fun emit_changed(entity: &Entity, metadata: &Metadata) {
    event::emit(MetadataChanged {
        entity_id: entity.id(),
        entity_key: entity.key(),
        name: metadata.name,
        description: metadata.description,
        url: metadata.url,
    });
}

fun module_label(): String {
    string::utf8(NAME)
}

fun module_permit(): Permit<Metadata> {
    internal::permit<Metadata>()
}

fun edit_permit(): Permit<Edit> {
    internal::permit<Edit>()
}
