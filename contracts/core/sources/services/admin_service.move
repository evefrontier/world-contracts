/// Admin and sponsor authorization as composable requirements.
///
/// Two separable authorities
/// - **Admin** — verified against the transaction *sender*; governance and minting.
/// - **Sponsor** — verified against the transaction *gas sponsor* (falling back to
///   the sender when unsponsored); backend-sponsored player transactions.
module core::admin_service;

use core::{request::Request, requirement::{Self, Requirement}};
use std::internal::Permit;
use sui::table::{Self, Table};

// === Errors ===

const EUnauthorizedAdmin: u64 = 0;
const EUnauthorizedSponsor: u64 = 1;

// === Structs ===

/// Requirement marker: present on a request means "the caller must be an admin".
public struct Admin() has drop;

/// Requirement marker: present on a request means "the caller must be a sponsor".
public struct Sponsor() has drop;

/// Shared allowlist of admin and sponsor addresses.
public struct AdminACL has key {
    id: UID,
    admins: Table<address, bool>,
    sponsors: Table<address, bool>,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    let mut acl = AdminACL {
        id: object::new(ctx),
        admins: table::new(ctx),
        sponsors: table::new(ctx),
    };
    acl.admins.add(ctx.sender(), true);
    transfer::share_object(acl);
}

// === Public Functions ===

/// Build an admin requirement for a privileged operation.
public fun admin_requirement(): Requirement {
    requirement::from_config(option::none(), Admin())
}

/// Build a sponsor requirement for a privileged operation.
public fun sponsor_requirement(): Requirement {
    requirement::from_config(option::none(), Sponsor())
}

/// Satisfy the next (admin) requirement on `request`. Aborts unless the
/// transaction sender is an admin.
public fun verify_admin(request: &mut Request, acl: &AdminACL, ctx: &mut TxContext) {
    let (_requirement, frame) = request.take_next(admin_permit());
    assert!(acl.admins.contains(ctx.sender()), EUnauthorizedAdmin);
    frame.destroy_empty_frame();
}

/// Satisfy the next (sponsor) requirement on `request`. Aborts unless the gas
/// sponsor — or the sender, when the transaction is unsponsored — is a sponsor.
public fun verify_sponsor(request: &mut Request, acl: &AdminACL, ctx: &mut TxContext) {
    let (_requirement, frame) = request.take_next(sponsor_permit());
    let authorized = ctx.sponsor().destroy_or!(ctx.sender());
    assert!(acl.sponsors.contains(authorized), EUnauthorizedSponsor);
    frame.destroy_empty_frame();
}

// === View Functions ===

public fun is_admin(acl: &AdminACL, addr: address): bool {
    acl.admins.contains(addr)
}

public fun is_sponsor(acl: &AdminACL, addr: address): bool {
    acl.sponsors.contains(addr)
}

// === Admin Functions ===

/// Add a single admin. Itself admin-gated: caller satisfies `request` first.
public fun add_admin(
    acl: &mut AdminACL,
    request: &mut Request,
    addr: address,
    ctx: &mut TxContext,
) {
    verify_admin(request, acl, ctx);
    acl.admins.add(addr, true);
}

/// Add a single sponsor. Admin-gated.
public fun add_sponsor(
    acl: &mut AdminACL,
    request: &mut Request,
    addr: address,
    ctx: &mut TxContext,
) {
    verify_admin(request, acl, ctx);
    acl.sponsors.add(addr, true);
}

/// Add a batch of admins in one call. Admin-gated.
public fun add_admins(
    acl: &mut AdminACL,
    request: &mut Request,
    addrs: vector<address>,
    ctx: &mut TxContext,
) {
    verify_admin(request, acl, ctx);
    addrs.do!(|addr| acl.admins.add(addr, true));
}

/// Add a batch of sponsors in one call. Admin-gated.
public fun add_sponsors(
    acl: &mut AdminACL,
    request: &mut Request,
    addrs: vector<address>,
    ctx: &mut TxContext,
) {
    verify_admin(request, acl, ctx);
    addrs.do!(|addr| acl.sponsors.add(addr, true));
}

// === Private Functions ===

/// Mint the package-authorship permit for `Admin`. Only this module defines
/// `Admin`, so only this module can satisfy its requirement.
fun admin_permit(): Permit<Admin> {
    internal::permit<Admin>()
}

/// Mint the package-authorship permit for `Sponsor`.
fun sponsor_permit(): Permit<Sponsor> {
    internal::permit<Sponsor>()
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
