/// This module manages issuing capabilities for world objects for access control.
///
/// The module defines three levels of capabilities:
/// - `GovernorCap`: Top-level capability (defined in world module)
/// - `AdminCap`: Mid-level capability that can be created by the Governor
/// - `OwnerCap`: Object-level capability that can be created by Admins
///
/// This hierarchy allows for delegation of permissions:
/// - Governor can create/delete AdminCaps for specific addresses
/// - Admins can create/transfer/delete OwnerCaps
/// Future: Capability registry to support multi party access/shared control. (eg: A capability for corporatio/tribe with multiple members)
/// Capabilities based on different roles/permission in a corporation/tribe.

module world::authority;

use sui::event;
use world::world::GovernorCap;

public struct AdminCap has key {
    id: UID,
    admin: address,
}

public struct OwnerCap has key {
    id: UID,
    owned_object_id: ID,
}

public struct AdminCapCreatedEvent has copy, drop {
    admin_cap_id: ID,
    admin: address,
}

public fun create_admin_cap(_: &GovernorCap, admin: address, ctx: &mut TxContext) {
    let admin_cap = AdminCap {
        id: object::new(ctx),
        admin: admin,
    };
    event::emit(AdminCapCreatedEvent {
        admin_cap_id: object::id(&admin_cap),
        admin: admin,
    });

    transfer::transfer(admin_cap, admin);
}

public fun delete_admin_cap(admin_cap: AdminCap, _: &GovernorCap) {
    let AdminCap { id, .. } = admin_cap;
    id.delete();
}

public fun create_owner_cap(_: &AdminCap, owned_object_id: ID, ctx: &mut TxContext): OwnerCap {
    OwnerCap {
        id: object::new(ctx),
        owned_object_id: owned_object_id,
    }
}

public fun transfer_owner_cap(owner_cap: OwnerCap, _: &AdminCap, owner: address) {
    transfer::transfer(owner_cap, owner);
}

// Ideally only the owner can delete the owner cap
public fun delete_owner_cap(owner_cap: OwnerCap, _: &AdminCap) {
    let OwnerCap { id, .. } = owner_cap;
    id.delete();
}

// Checks if the `OwnerCap` is allowed to access the object with the given `object_id`.
/// Returns true iff the `OwnerCap` has mutation access for the specified object.
public fun is_authorized(owner_cap: &OwnerCap, object_id: ID): bool {
    owner_cap.owned_object_id == object_id
}
