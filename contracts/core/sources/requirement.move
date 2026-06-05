/// A typed rule attached to an `Action` and resolved through a `Request`.
///
/// - `type_name` identifies which handler may satisfy it (e.g. `inventory::Deposit`).
/// - `name` optionally targets an installed module (e.g. `some("storage unit (01)")`).
/// - `data` is the BCS encoding of the rule's typed config.
module core::requirement;

use std::{bcs, string::String, type_name::{Self, TypeName}};

// === Structs ===

public struct Requirement has drop, store {
    // Identifies which handler type may satisfy this requirement.
    type_name: TypeName,
    // Optional target module name; `None` when not module-scoped.
    name: Option<String>,
    // BCS-encoded typed config the handler enforces.
    data: vector<u8>,
}

// === Public Functions ===

/// Build a requirement from a typed config `c`. The type identity is recorded
/// from `T`, so only the package that defines `T` can later satisfy it, while
/// `data` carries the BCS-encoded configuration the handler enforces.
public fun from_config<T: drop>(name: Option<String>, c: T): Requirement {
    Requirement {
        type_name: type_name::with_original_ids<T>(),
        data: bcs::to_bytes(&c),
        name,
    }
}

// === View Functions ===

/// True when this requirement is satisfied by handlers owning type `T`.
public fun is<T>(r: &Requirement): bool {
    r.type_name == type_name::with_original_ids<T>()
}

public fun type_name(r: &Requirement): TypeName {
    r.type_name
}

/// The module this requirement targets, if any. `None` means the requirement
/// is not module-scoped (e.g. an admin/sponsor approval).
public fun module_name(r: &Requirement): Option<String> {
    r.name
}

public fun data(r: &Requirement): vector<u8> {
    r.data
}

// === Package Functions ===

public(package) fun clone(r: &Requirement): Requirement {
    Requirement {
        type_name: r.type_name,
        name: r.name,
        data: r.data,
    }
}
