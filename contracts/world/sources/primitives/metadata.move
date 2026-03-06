/// Metadata for any assembly is managed here
module world::metadata;

use std::string::String;
use sui::event;
use world::in_game_id::TenantItemId;

// === Structs ===
public struct Metadata has store {
    assembly_id: ID,
    name: String,
    description: String,
    url: String,
}

// === Events ===
public struct MetadataChangedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    name: String,
    description: String,
    url: String,
}

// === Package Functions ===
public(package) fun create_metadata(
    assembly_id: ID,
    assembly_key: TenantItemId,
    name: String,
    description: String,
    url: String,
): Metadata {
    let metadata = Metadata {
        assembly_id,
        name,
        description,
        url,
    };

    metadata.emit_metadata_changed(assembly_key);
    metadata
}

public(package) fun delete(metadata: Metadata) {
    let Metadata { .. } = metadata;
}

public(package) fun update_name(metadata: &mut Metadata, assembly_key: TenantItemId, name: String) {
    metadata.name = name;
    metadata.emit_metadata_changed(assembly_key);
}

public(package) fun update_description(
    metadata: &mut Metadata,
    assembly_key: TenantItemId,
    description: String,
) {
    metadata.description = description;
    metadata.emit_metadata_changed(assembly_key);
}

public(package) fun update_url(metadata: &mut Metadata, assembly_key: TenantItemId, url: String) {
    metadata.url = url;
    metadata.emit_metadata_changed(assembly_key);
}

// === Private Functions ===
fun emit_metadata_changed(metadata: &Metadata, assembly_key: TenantItemId) {
    event::emit(MetadataChangedEvent {
        assembly_id: metadata.assembly_id,
        assembly_key,
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
