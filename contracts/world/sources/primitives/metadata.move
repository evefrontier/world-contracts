/// Metadata for any structure is managed here
module world::metadata;

use std::string::String;
use sui::event;

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

    event::emit(MetadataChangedEvent {
        assembly_id,
        item_id,
        name,
        description,
        url,
    });

    metadata
}

public(package) fun update_name(metadata: &mut Metadata, name: String) {
    metadata.name = name;
}

public(package) fun update_description(metadata: &mut Metadata, description: String) {
    metadata.description = description;
}

public(package) fun update_url(metadata: &mut Metadata, url: String) {
    metadata.url = url;
}

public(package) fun delete(metadata: Metadata) {
    let Metadata {
        assembly_id: _,
        item_id: _,
        name: _,
        description: _,
        url: _,
    } = metadata;
}
