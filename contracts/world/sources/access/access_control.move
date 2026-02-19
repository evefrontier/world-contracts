/// This module manages issuing capabilities for world objects for access control.
///
/// The module defines three levels of capabilities:
/// - `GovernorCap`: Top-level capability (defined in world module)
/// - `AdminACL`: Shared object with a table of authorized sponsor addresses
/// - `OwnerCap`: Object-level capability that can be created by authorized sponsors
///
/// This hierarchy allows for delegation of permissions:
/// - Governor can add/remove sponsors in AdminACL
/// - Authorized sponsors can create/transfer/delete OwnerCaps
/// Future: Capability registry to support multi party access/shared control. (eg: A capability for corporation/tribe with multiple members)
/// Capabilities based on different roles/permission in a corporation/tribe.

module world::access;

use std::{ascii::String, type_name::{Self, TypeName}};
use sui::{event, table::{Self, Table}, transfer::Receiving};
use world::world::GovernorCap;

#[error(code = 0)]
const ECharacterTransfer: vector<u8> = b"Character cannot be transferred";
#[error(code = 1)]
const EUnauthorizedSponsor: vector<u8> = b"Unauthorized sponsor";
#[error(code = 2)]
const EOwnerIdMismatch: vector<u8> = b"Owner ID mismatch";
#[error(code = 3)]
const EOwnerCapIdMismatch: vector<u8> = b"Owner Cap ID mismatch";

/// Proof that an owner cap was borrowed from an object; must be used to either return or transfer the cap.
public struct ReturnOwnerCapReceipt {
    owner_id: address,
    owner_cap_id: ID,
}

public struct AdminACL has key {
    id: UID,
    authorized_sponsors: Table<address, bool>,
}

/// `OwnerCap` serves as a transferable capability ("KeyCard") for accessing and mutating shared objects.
///
/// This capability pattern allows:
/// 1. Centralized on-chain ownership
/// 2. Granular access control for shared objects (e.g., Characters, Assemblies) that live on-chain.
/// 3. Delegation of rights by transferring the OwnerCap without moving the underlying object.
///
/// Fields:
/// - `authorized_object_id`: The ID of the specific object this KeyCard grants mutation access to.
public struct OwnerCap<phantom T> has key {
    id: UID,
    authorized_object_id: ID,
}

/// Registry of authorized server addresses that can sign location proofs.
/// Only the deployer (stored in `admin`) can modify it.
public struct ServerAddressRegistry has key {
    id: UID,
    authorized_address: Table<address, bool>,
}

// === Events ===
public struct OwnerCapCreatedEvent has copy, drop {
    owner_cap_id: ID,
    authorized_object_id: ID,
}

public struct OwnerCapTransferred has copy, drop {
    owner_cap_id: ID,
    authorized_object_id: ID,
    previous_owner: address,
    owner: address,
}

fun init(ctx: &mut TxContext) {
    let server_address_registry = ServerAddressRegistry {
        id: object::new(ctx),
        authorized_address: table::new(ctx),
    };

    let admin_acl = AdminACL {
        id: object::new(ctx),
        authorized_sponsors: table::new(ctx),
    };

    // Share the registry so anyone can read it for verification
    transfer::share_object(server_address_registry);
    transfer::share_object(admin_acl);
}

// === Public Functions ===

// Note: Currently, OwnerCap transfers are restricted via contracts
// Future: This restriction may be lifted to allow free transfers
/// Transfers an OwnerCap to a new owner.
///
/// Security: Ownership is enforced by the Sui runtime. Only the current owner of the OwnerCap
/// can call this function - if a non-owner attempts to move the object, the transaction will
/// be rejected by the runtime before this function is even called.
public fun transfer_owner_cap<T: key>(owner_cap: OwnerCap<T>, owner: address) {
    transfer::transfer(owner_cap, owner);
}

public fun transfer_owner_cap_to_address<T: key>(
    owner_cap: OwnerCap<T>,
    new_owner: address,
    ctx: &mut TxContext,
) {
    let type_name: TypeName = type_name::with_defining_ids<T>();
    let str: &String = type_name.as_string();
    assert!(str == &std::ascii::string(b"Character"), ECharacterTransfer);
    transfer<T>(owner_cap, ctx.sender(), new_owner);
}

/// Returns a borrowed owner cap to the object it was borrowed from. Consumes the receipt.
public fun return_owner_cap_to_object<T: key>(
    owner_cap: OwnerCap<T>,
    receipt: ReturnOwnerCapReceipt,
    owner_id: address,
) {
    validate_return_receipt(receipt, object::id(&owner_cap), owner_id);
    transfer_owner_cap(owner_cap, owner_id);
}

/// Transfers a borrowed owner cap to an address, consuming the return receipt.
public fun transfer_owner_cap_with_receipt<T: key>(
    owner_cap: OwnerCap<T>,
    receipt: ReturnOwnerCapReceipt,
    new_owner: address,
    ctx: &mut TxContext,
) {
    let ReturnOwnerCapReceipt { owner_id: _, owner_cap_id: receipt_owner_cap_id } = receipt;
    assert!(receipt_owner_cap_id == object::id(&owner_cap), EOwnerCapIdMismatch);
    transfer_owner_cap_to_address(owner_cap, new_owner, ctx);
}

// === View Functions ===
/// Checks if an address is an authorized server address.
public fun is_authorized_server_address(
    server_address_registry: &ServerAddressRegistry,
    address: address,
): bool {
    server_address_registry.authorized_address.contains(address)
}

// Checks if the `OwnerCap` is allowed to access the object with the given `object_id`.
/// Returns true iff the `OwnerCap` has mutation access for the specified object.
public fun is_authorized<T: key>(owner_cap: &OwnerCap<T>, object_id: ID): bool {
    owner_cap.authorized_object_id == object_id
}

/// Verifies that the transaction is from an authorized address.
/// Checks the sponsor if the transaction is sponsored, otherwise falls back to the sender.
public fun verify_sponsor(admin_acl: &AdminACL, ctx: &TxContext) {
    let sponsor_opt = tx_context::sponsor(ctx);
    let authorized_address = if (option::is_some(&sponsor_opt)) {
        *option::borrow(&sponsor_opt)
    } else {
        ctx.sender()
    };
    assert!(admin_acl.authorized_sponsors.contains(authorized_address), EUnauthorizedSponsor);
}

// === Package Functions ===
public(package) fun create_and_transfer_owner_cap<T: key>(
    object_id: ID,
    admin_acl: &AdminACL,
    owner: address,
    ctx: &mut TxContext,
): ID {
    let owner_cap = create_owner_cap_by_id<T>(object_id, admin_acl, ctx);
    let owner_cap_id = object::id(&owner_cap);
    transfer<T>(owner_cap, @0x0, owner);
    owner_cap_id
}

/// Receives an `OwnerCap<T>` from a `Receiving<OwnerCap<T>>` ticket.
///
/// - **Borrow**: the `Character` receives (materializes) the `OwnerCap<T>` from a
///   `Receiving<OwnerCap<T>>` ticket for the duration of a transaction.
/// - **Return**: the `OwnerCap<T>` is put back under the `Character`’s control at
///   the end of the flow.
public(package) fun receive_owner_cap<T: key>(
    receiving_id: &mut UID,
    ticket: Receiving<OwnerCap<T>>,
): OwnerCap<T> {
    transfer::receive(receiving_id, ticket)
}

/// Creates a return receipt. Consumed by return_owner_cap_to_object or transfer_owner_cap_with_receipt.
public(package) fun create_return_receipt(
    owner_cap_id: ID,
    owner_id: address,
): ReturnOwnerCapReceipt {
    ReturnOwnerCapReceipt { owner_id, owner_cap_id }
}

// === Admin Functions ===
public fun add_sponsor_to_acl(
    admin_acl: &mut AdminACL,
    _: &GovernorCap, // Its governorCap, so its part of initial configuration
    sponsor: address,
) {
    admin_acl.authorized_sponsors.add(sponsor, true);
}

public fun create_owner_cap<T: key>(
    admin_acl: &AdminACL,
    obj: &T,
    ctx: &mut TxContext,
): OwnerCap<T> {
    admin_acl.verify_sponsor(ctx);
    let object_id = object::id(obj);
    let owner_cap = OwnerCap<T> {
        id: object::new(ctx),
        authorized_object_id: object_id,
    };
    event::emit(OwnerCapCreatedEvent {
        owner_cap_id: object::id(&owner_cap),
        authorized_object_id: object_id,
    });
    owner_cap
}

public fun create_owner_cap_by_id<T: key>(
    object_id: ID,
    admin_acl: &AdminACL,
    ctx: &mut TxContext,
): OwnerCap<T> {
    admin_acl.verify_sponsor(ctx);
    let owner_cap = OwnerCap<T> {
        id: object::new(ctx),
        authorized_object_id: object_id,
    };
    event::emit(OwnerCapCreatedEvent {
        owner_cap_id: object::id(&owner_cap),
        authorized_object_id: object_id,
    });
    owner_cap
}

public fun register_server_address(
    server_address_registry: &mut ServerAddressRegistry,
    _: &GovernorCap,
    server_address: address,
) {
    server_address_registry.authorized_address.add(server_address, true);
}

public fun remove_server_address(
    server_address_registry: &mut ServerAddressRegistry,
    _: &GovernorCap,
    server_address: address,
) {
    server_address_registry.authorized_address.remove(server_address);
}

public fun delete_owner_cap<T: key>(owner_cap: OwnerCap<T>, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    let OwnerCap { id, .. } = owner_cap;
    id.delete();
}

// === Private Functions ===
fun transfer<T: key>(owner_cap: OwnerCap<T>, previous_owner: address, new_owner: address) {
    event::emit(OwnerCapTransferred {
        owner_cap_id: object::id(&owner_cap),
        authorized_object_id: owner_cap.authorized_object_id,
        previous_owner: previous_owner,
        owner: new_owner,
    });
    transfer::transfer(owner_cap, new_owner);
}

fun validate_return_receipt(receipt: ReturnOwnerCapReceipt, owner_cap_id: ID, owner_id: address) {
    let ReturnOwnerCapReceipt {
        owner_id: receipt_owner_id,
        owner_cap_id: receipt_owner_cap_id,
    } = receipt;
    assert!(receipt_owner_id == owner_id, EOwnerIdMismatch);
    assert!(receipt_owner_cap_id == owner_cap_id, EOwnerCapIdMismatch);
}

#[test_only]
public fun destroy_receipt_for_testing(receipt: ReturnOwnerCapReceipt) {
    let ReturnOwnerCapReceipt { owner_id: _, owner_cap_id: _ } = receipt;
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
