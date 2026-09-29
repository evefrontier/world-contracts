/// Docking proof (server-signed): a ship docked at a structure or another ship.
///
/// Docking is world physics, not an owner rule, so handlers that move items
/// between two creations check it inline with `assert_docked` instead of pushing
/// a requirement. The caller verifies one docking per transaction, kept in the
/// transaction scratchpad, and every handler call reads it.
module core::docking;

use core::{admin_service::AdminACL, proof};
use sui::{bcs, clock::Clock};

// === Errors ===

#[error(code = 0)]
const ENotDocked: vector<u8> = b"Entity is not part of the docking";
#[error(code = 1)]
const ESameCreation: vector<u8> = b"A ship cannot dock at itself";
#[error(code = 2)]
const EWrongSource: vector<u8> = b"Docking does not link the entity to the source";
#[error(code = 3)]
const EAlreadyDocked: vector<u8> = b"A docking was already verified in this transaction";
#[error(code = 4)]
const ENoDocking: vector<u8> = b"No docking was verified in this transaction";
#[error(code = 5)]
const ENotAttester: vector<u8> = b"Sender is not an admin and gas sponsor is not allowlisted";

// === Structs ===

/// Verified docking. The payload the server signs. No `store`: lives for one transaction.
public struct Docking has copy, drop {
    ship: ID,
    target: ID,
    character: ID,
}

/// How this transaction's docking was established (ADR 0004).
public enum Proven has copy, drop {
    /// A server-signed proof.
    Signed(Docking),
    /// An admin sender or allowlisted sponsor vouches for the whole transaction.
    Attested,
}

/// Scratchpad key for the transaction's `Proven`.
public struct DockingKey() has copy, drop;

// === Public Functions ===

/// Verify a server-signed docking proof and keep it for the rest of the
/// transaction. The signer must be an admin on `acl`.
public fun verify(acl: &AdminACL, bytes: vector<u8>, clock: &Clock, ctx: &mut TxContext) {
    let mut proof_bytes = bcs::new(
        proof::verify<Docking>(acl, bytes, clock, internal::permit(), ctx),
    );
    let docking = Docking {
        ship: proof_bytes.peel_address().to_id(),
        target: proof_bytes.peel_address().to_id(),
        character: proof_bytes.peel_address().to_id(),
    };
    assert!(docking.ship != docking.target, ESameCreation);
    store(Proven::Signed(docking), ctx);
}

/// Attest the transaction's docking without a proof: the sender is an admin, or
/// the gas sponsor is allowlisted and has checked the transaction before paying.
///
/// TODO: gate on the kind's `ProofConfig` mode, so it stops working once
/// docking switches to Signed.
public fun attest(acl: &AdminACL, ctx: &mut TxContext) {
    let sponsor = ctx.sponsor();
    let authorized = acl.is_admin(ctx.sender()) || sponsor.is_some_and!(|s| acl.is_sponsor(*s));
    assert!(authorized, ENotAttester);
    store(Proven::Attested, ctx);
}

/// Abort unless this transaction's docking links `entity`, and also `source`
/// when set (the other side of a transfer). Components can verify it inline.
public fun assert_docked(entity: ID, source: Option<ID>, ctx: &mut TxContext) {
    match (cached(ctx)) {
        Proven::Attested => (),
        Proven::Signed(docking) => {
            assert!(docking.links(entity), ENotDocked);
            source.do!(|s| assert!(s == entity || docking.links(s), EWrongSource));
        },
    }
}

// === View Functions ===

/// The docking cached for this transaction.
public fun cached(ctx: &mut TxContext): Proven {
    ctx.scratch_internal_read_opt!(DockingKey()).destroy_or!(abort ENoDocking)
}

public fun ship(docking: &Docking): ID {
    docking.ship
}

public fun target(docking: &Docking): ID {
    docking.target
}

public fun character(docking: &Docking): ID {
    docking.character
}

// === Private Functions ===

fun links(docking: &Docking, id: ID): bool {
    docking.ship == id || docking.target == id
}

fun store(proven: Proven, ctx: &mut TxContext) {
    assert!(!ctx.scratch_internal_exists!(DockingKey()), EAlreadyDocked);
    ctx.scratch_internal_add!(DockingKey(), proven);
}

// === Test Functions ===

/// Store a signed docking for this transaction without a proof.
#[test_only]
public fun dock_for_testing(ship: ID, target: ID, character: ID, ctx: &mut TxContext) {
    store(Proven::Signed(Docking { ship, target, character }), ctx);
}

#[test_only]
public fun signed_docking(proven: Proven): Docking {
    match (proven) {
        Proven::Signed(docking) => docking,
        Proven::Attested => abort,
    }
}
