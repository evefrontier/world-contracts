/// Display metadata component installable on any `Entity`.
///
/// Holds `name`, `description`, and `url`. Owners expose an `edit` action that
/// includes `edit_requirement`; callers satisfy it via `edit`.
module metadata::metadata;

use core::{
    component::{Self, Component},
    entity::Entity,
    entity_key::EntityKey,
    request::Request,
    requirement::{Self, Requirement}
};
use std::{internal::Permit, string::{Self, String}};
use sui::event;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Metadata component version does not match the package version";
#[error(code = 1)]
const EComponentMissing: vector<u8> = b"Metadata component is not installed on this entity";

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

/// Build and install the metadata component with the given display fields.
/// Empty strings are allowed.
public fun install(
    entity: &mut Entity,
    name: String,
    description: String,
    url: String,
    ctx: &mut TxContext,
): Request {
    let metadata = Metadata { name, description, url };
    emit_changed(entity, &metadata);
    entity.install(
        component_id(),
        option::some(component_label()),
        metadata,
        VERSION,
        metadata_permit(),
        ctx,
    )
}

/// Remove the metadata component, discarding its state. Aborts if missing.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(entity.has_component_with_type<Metadata>(component_id()), EComponentMissing);

    let (c, req) = entity.uninstall<Metadata>(component_id(), metadata_permit(), ctx);
    let Metadata { name: _, description: _, url: _ } = c.unwrap(metadata_permit());
    req
}

/// Replace all display fields. Next requirement must be this component's `Edit`.
public fun edit(
    entity: &mut Entity,
    req: &mut Request,
    name: String,
    description: String,
    url: String,
) {
    let entity_id = entity.id();
    let entity_key = entity.key();
    let c: &mut Component<Metadata> = entity.component_mut(req, metadata_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    let (_requirement, frame) = req.take_next(edit_permit());
    let metadata = c.inner_mut();
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

/// Build an edit requirement targeting the metadata component slot.
public fun edit_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), Edit())
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

public fun component_id(): u64 {
    component::id_from_name(NAME)
}

// === Private Functions ===

fun borrow_component(entity: &Entity): &Component<Metadata> {
    let c: &Component<Metadata> = entity.component_ref(component_id(), metadata_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    c
}

fun borrow(entity: &Entity): &Metadata {
    borrow_component(entity).inner()
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

fun component_label(): String {
    string::utf8(NAME)
}

fun metadata_permit(): Permit<Metadata> {
    internal::permit<Metadata>()
}

fun edit_permit(): Permit<Edit> {
    internal::permit<Edit>()
}
