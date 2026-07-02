/// A capability proving its holder owns an entity.
///
/// An `AccessCap` is bound to one entity and is `key`-only, so it can never be
/// `public_transfer`ed. A soulbound cap (`transferable: false`) has no transfer
/// path at all; a transferable cap moves only via `transfer_access`. Minting is
/// admin-gated through `entity::mint_access`.
module core::access_cap;

use core::{request::Request, requirement::{Self, Requirement}};
use std::internal::Permit;
use sui::event;

// === Errors ===

#[error(code = 0)]
const ENotOwner: vector<u8> = b"AccessCap does not grant access to this entity";
#[error(code = 1)]
const ENotTransferable: vector<u8> = b"Access cap is soulbound and cannot be transferred";
#[error(code = 2)]
const EWrongVersion: vector<u8> = b"AccessCap version does not match the package version";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

public struct AccessCap has key {
    id: UID,
    version: u64,
    entity: ID,
    transferable: bool,
}

/// Requirement marker: present on a request means "the caller must hold the
/// `AccessCap` for the request's target entity".
public struct Owner() has drop;

/// Requirement marker: the caller must present *any* valid `AccessCap`. Records
/// its `entity()` as the request's authorized entity for downstream routing
/// (e.g. inventory owner-vs-ephemeral). Does not require the cap to own the
/// target entity.
public struct Caller() has drop;

// === Events ===

public struct AccessCapCreated has copy, drop {
    cap_id: ID,
    entity: ID,
}

// === Public Functions ===

public fun owner_requirement(): Requirement {
    requirement::from_config(option::none(), Owner())
}

/// Requirement satisfied by any valid `AccessCap`, recording its holder as the
/// request actor. Use to gate actions open to any identified caller.
public fun caller_requirement(): Requirement {
    requirement::from_config(option::none(), Caller())
}

public fun verify(request: &mut Request, cap: &AccessCap) {
    assert!(cap.version == VERSION, EWrongVersion);
    let (_requirement, frame) = request.take_next(permit());
    assert!(request.entity_id() == option::some(cap.entity), ENotOwner);
    request.set_authorized_id(cap.entity);
    frame.destroy_empty_frame();
}

/// Satisfy the next (caller) requirement with any valid cap, recording
/// `cap.entity()` as the request's authorized entity for downstream routing.
public fun verify_caller(request: &mut Request, cap: &AccessCap) {
    assert!(cap.version == VERSION, EWrongVersion);
    let (_requirement, frame) = request.take_next(caller_permit());
    request.set_authorized_id(cap.entity);
    frame.destroy_empty_frame();
}

public fun transfer_access(cap: AccessCap, new_owner: address) {
    assert!(cap.transferable, ENotTransferable);
    transfer::transfer(cap, new_owner);
}

// === View Functions ===

public fun version(cap: &AccessCap): u64 {
    cap.version
}

public fun entity(cap: &AccessCap): ID {
    cap.entity
}

public fun is_transferable(cap: &AccessCap): bool {
    cap.transferable
}

// === Package Functions ===

/// Mint a cap for `entity` and transfer it to `owner`.
public(package) fun mint(entity: ID, owner: address, transferable: bool, ctx: &mut TxContext) {
    let cap = AccessCap { id: object::new(ctx), version: VERSION, entity, transferable };
    event::emit(AccessCapCreated { cap_id: cap.id.to_inner(), entity });
    transfer::transfer(cap, owner);
}

// === Private Functions ===

fun permit(): Permit<Owner> {
    internal::permit<Owner>()
}

fun caller_permit(): Permit<Caller> {
    internal::permit<Caller>()
}
