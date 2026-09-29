/// Server-signed proofs (ADR 0004).
///
/// Proof bytes are `bcs(ProofMessage) || bcs(signature)`. The message carries the
/// fields every proof shares; `payload` is the BCS of a kind-specific struct
/// that only the module defining that kind can decode.
module core::proof;

use core::{admin_service::AdminACL, sig_verify};
use std::{internal::Permit, type_name};
use sui::{bcs, clock::Clock};

// === Errors ===

#[error(code = 0)]
const EWrongKind: vector<u8> = b"Proof was signed for another kind";
#[error(code = 1)]
const EWrongSender: vector<u8> = b"Proof was not issued to the sender";
#[error(code = 2)]
const EDeadlineExpired: vector<u8> = b"Proof deadline has expired";
#[error(code = 3)]
const ETrailingBytes: vector<u8> = b"Proof has trailing bytes";
#[error(code = 4)]
const EInvalidSignature: vector<u8> = b"Proof signature is not the server's";
#[error(code = 5)]
const EUnauthorizedServer: vector<u8> = b"Proof server is not an admin";

// === Structs ===

/// The server-signed part of a proof.
public struct ProofMessage has drop {
    server: address,
    sender: address,
    /// `type_name` (original ids) of the payload struct.
    kind: vector<u8>,
    deadline_ms: u64,
    payload: vector<u8>,
}

// === Public Functions ===

/// Verify proof `proof_bytes` of kind `K` and return its payload. Only `K`'s
/// module can call this, via `Permit<K>`. `server` must be an admin on `acl`,
/// and the signature must be that admin's Ed25519 personal-message signature
/// over `bcs(ProofMessage)`.
public fun verify<K>(
    acl: &AdminACL,
    proof_bytes: vector<u8>,
    clock: &Clock,
    _: Permit<K>,
    ctx: &mut TxContext,
): vector<u8> {
    let (message, signature) = unpack(proof_bytes);
    let kind = type_name::with_original_ids<K>().into_string().into_bytes();
    assert!(message.kind == kind, EWrongKind);
    assert!(message.sender == ctx.sender(), EWrongSender);
    assert!(message.deadline_ms > clock.timestamp_ms(), EDeadlineExpired);
    assert!(acl.is_admin(message.server), EUnauthorizedServer);
    assert!(
        sig_verify::verify_signature(bcs::to_bytes(&message), signature, message.server),
        EInvalidSignature,
    );
    message.payload
}

// === Private Functions ===

fun unpack(proof_bytes: vector<u8>): (ProofMessage, vector<u8>) {
    let mut b = bcs::new(proof_bytes);
    let message = ProofMessage {
        server: b.peel_address(),
        sender: b.peel_address(),
        kind: b.peel_vec_u8(),
        deadline_ms: b.peel_u64(),
        payload: b.peel_vec_u8(),
    };
    let signature = b.peel_vec_u8();
    assert!(b.into_remainder_bytes().is_empty(), ETrailingBytes);
    (message, signature)
}

// === Test Functions ===

#[test_only]
public fun proof_bytes_for_testing(
    server: address,
    sender: address,
    kind: vector<u8>,
    deadline_ms: u64,
    payload: vector<u8>,
    signature: vector<u8>,
): vector<u8> {
    let mut proof_bytes = bcs::to_bytes(
        &ProofMessage { server, sender, kind, deadline_ms, payload },
    );
    proof_bytes.append(bcs::to_bytes(&signature));
    proof_bytes
}
