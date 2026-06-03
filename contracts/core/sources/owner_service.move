/// Ownership requirement marker (stub).
///
/// Declares the `Owner` requirement so lifecycle/admin operations can later
/// require owner approval. Verification and injection are intentionally
/// deferred until the OwnerCap / admin-ACL design lands; for now this module
/// only constructs the requirement value.
module core::owner_service;

use core::requirement::{Self, Requirement};

// === Structs ===

/// Requirement marker; wraps the id of the owning capability.
public struct Owner(ID) has drop;

// === Public Functions ===

/// Build an ownership requirement targeting `owner_cap_id`.
public fun requirement(owner_cap_id: ID): Requirement {
    requirement::from_config(option::none(), Owner(owner_cap_id))
}
