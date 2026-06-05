/// Shared types and event for freezing assembly extension configuration.
/// Used by Gate, Turret, and StorageUnit so the owner cannot change the extension after freeze (no rugpull).
///
/// **Before freeze:** The owner may call `authorize_extension` (set or replace) or `revoke_extension_authorization`
/// (clear back to default world behaviour). Indexers and users should treat unfrozen assemblies as mutable.
///
/// **After freeze:** Extension config is immutable until the assembly is destroyed (unanchor cleans the marker).
/// If a bug is found in the extension code, the owner cannot point this assembly at a different package; they would
/// need a new assembly. Freeze only after the extension is audited/tested and you are comfortable with this permanence.
module world::extension_freeze;

use sui::{dynamic_field as df, event};

/// Dynamic field key for the "extension config frozen" slot on an assembly.
public struct ExtensionFrozenKey has copy, drop, store {}

/// Marker value stored as a dynamic field when extension config is frozen.
public struct ExtensionFrozen has copy, drop, store {}

/// Emitted when an assembly's extension configuration is frozen.
public struct ExtensionConfigFrozenEvent has copy, drop {
    assembly_id: ID,
}

/// Returns true if the given object has its extension config frozen (dynamic field present).
public fun is_extension_frozen(object: &UID): bool {
    df::exists_<ExtensionFrozenKey>(object, ExtensionFrozenKey {})
}

/// Adds the frozen marker and emits the event. Call from Gate/Turret/StorageUnit after auth and extension checks.
/// One-time and irreversible: the assembly will stay on this extension package; no upgrade path if the extension has a bug.
public(package) fun freeze_extension_config(parent: &mut UID, assembly_id: ID) {
    df::add(parent, ExtensionFrozenKey {}, ExtensionFrozen {});
    event::emit(ExtensionConfigFrozenEvent { assembly_id });
}

/// Removes the frozen marker if present. Call from Gate/Turret/StorageUnit unanchor/unanchor_orphan before deleting the assembly UID so DF storage is cleaned up.
public(package) fun remove_frozen_marker_if_present(parent: &mut UID) {
    if (df::exists_<ExtensionFrozenKey>(parent, ExtensionFrozenKey {})) {
        let _ = df::remove<ExtensionFrozenKey, ExtensionFrozen>(parent, ExtensionFrozenKey {});
    };
}
