/// Metadata for any structure is managed here
module world::metadata;

use std::string::String;
use sui::event;
use world::authority::{Self, OwnerCap};

// === Errors ===
#[error(code = 0)]
const ENotAuthorized: vector<u8> = b"Not authorized to update metadata";

// === Structs ===
public struct Metadata has store {
    assembly_id: ID,
    item_id: u64,
    name: String,
    description: String,
    url: String,
}

// === Events ===
public struct MetadataChangedEvent has copy, drop {
    assembly_id: ID,
    item_id: u64,
    name: String,
    description: String,
    url: String,
}

// === Public Functions ===
public fun update_name<T: key>(metadata: &mut Metadata, owner_cap: &OwnerCap<T>, name: String) {
    assert!(authority::is_authorized(owner_cap, metadata.assembly_id), ENotAuthorized);
    metadata.name = name;
    metadata.emit_metadata_changed();
}

public fun update_description<T: key>(
    metadata: &mut Metadata,
    owner_cap: &OwnerCap<T>,
    description: String,
) {
    assert!(authority::is_authorized(owner_cap, metadata.assembly_id), ENotAuthorized);
    metadata.description = description;
    metadata.emit_metadata_changed();
}

public fun update_url<T: key>(metadata: &mut Metadata, owner_cap: &OwnerCap<T>, url: String) {
    assert!(authority::is_authorized(owner_cap, metadata.assembly_id), ENotAuthorized);
    metadata.url = url;
    metadata.emit_metadata_changed();
}

// === Package Functions ===
public(package) fun create_metadata(
    assembly_id: ID,
    item_id: u64,
    name: String,
    description: String,
    url: String,
): Metadata {
    let metadata = Metadata {
        assembly_id,
        item_id,
        name,
        description,
        url,
    };

    metadata.emit_metadata_changed();
    metadata
}

public(package) fun delete(metadata: Metadata) {
    let Metadata { .. } = metadata;
}

// === Private Functions ===
fun emit_metadata_changed(metadata: &Metadata) {
    event::emit(MetadataChangedEvent {
        assembly_id: metadata.assembly_id,
        item_id: metadata.item_id,
        name: metadata.name,
        description: metadata.description,
        url: metadata.url,
    });
}

#[test_only]
public fun name(metadata: &Metadata): String {
    metadata.name
}

#[test_only]
public fun description(metadata: &Metadata): String {
    metadata.description
}

#[test_only]
public fun url(metadata: &Metadata): String {
    metadata.url
}
