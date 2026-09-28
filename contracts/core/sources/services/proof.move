/// Server-signed proofs (ADR 0004).
///
/// Proof bytes are `bcs(ProofMessage) || bcs(signature)`. The message carries the
/// fields every proof shares; `payload` is the BCS of a kind-specific struct
/// that only the module defining that kind can decode.
module core::proof;

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

/// Verify proof `bytes` of kind `K` and return its payload. Only `K`'s module
/// can call this, via `Permit<K>`.
///
/// TODO: mock, skips the server and signature checks.
public fun verify<K>(
    bytes: vector<u8>,
    clock: &Clock,
    _: Permit<K>,
    ctx: &mut TxContext,
): vector<u8> {
    let (message, _signature) = unpack(bytes);
    let kind = type_name::with_original_ids<K>().into_string().into_bytes();
    assert!(message.kind == kind, EWrongKind);
    assert!(message.sender == ctx.sender(), EWrongSender);
    assert!(message.deadline_ms > clock.timestamp_ms(), EDeadlineExpired);
    message.payload
}

// === Private Functions ===

fun unpack(bytes: vector<u8>): (ProofMessage, vector<u8>) {
    let mut b = bcs::new(bytes);
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
    sender: address,
    kind: vector<u8>,
    deadline_ms: u64,
    payload: vector<u8>,
): vector<u8> {
    let mut bytes = bcs::to_bytes(
        &ProofMessage { server: @0x0, sender, kind, deadline_ms, payload },
    );
    bytes.append(bcs::to_bytes(&vector<u8>[]));
    bytes
}
