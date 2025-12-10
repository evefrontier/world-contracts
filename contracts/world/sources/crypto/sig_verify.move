/// # Signature Verification Module
///
/// This module provides cryptographic signature verification functionality for validating
/// off-chain signed messages on the Sui blockchain. It supports Ed25519 digital signature
/// verification, enabling secure authentication of messages signed by external key pairs.
///
/// ## Key Features
/// - Derives Sui addresses from Ed25519 public keys
/// - Verifies Ed25519 signatures against expected addresses
/// - Validates message integrity using Sui's PersonalMessage intent protocol
/// - Supports Sui's signature format (flag + signature + public key)
///
/// ## Use Cases
/// This module is essential for scenarios requiring proof of ownership or authorization,
/// such as:
/// - Verifying that a message was signed by a specific account holder
/// - Authenticating off-chain actions before executing on-chain operations
/// - Validating location proofs or other attestations signed externally
///
/// ## Implementation Reference
/// Based on the Sui off-chain message signing pattern described at:
/// https://medium.com/@gfusee33/signing-sui-off-chain-messages-and-verifying-them-on-chain-using-move-e6c5108a04e7
module world::sig_verify;

use std::bcs;
use sui::{ed25519, hash};

// === Errors ===
#[error(code = 0)]
const EInvalidPublicKeyLen: vector<u8> = b"Invalid public key length";
#[error(code = 1)]
const EUnsupportedScheme: vector<u8> = b"Unsupported scheme";
#[error(code = 2)]
const EInvalidLen: vector<u8> = b"Invalid length";

// === Constants ===
const ED25519_FLAG: u8 = 0x00;
const ED25519_SIG_LEN: u64 = 64;
const ED25519_PK_LEN: u64 = 32;

public fun derive_address_from_public_key(public_key: vector<u8>): address {
    assert!(public_key.length() == ED25519_PK_LEN, EInvalidPublicKeyLen);

    // ED25519_FLAG is the signature scheme flag for Ed25519 in Sui
    let mut concatenated: vector<u8> = vector::singleton(ED25519_FLAG);
    concatenated.append(public_key);

    sui::address::from_bytes(hash::blake2b256(&concatenated))
}

public fun verify_signature(
    message: vector<u8>,
    signature: vector<u8>,
    expected_address: address,
): bool {
    // Verify signature length
    let len = signature.length();

    assert!(len >= 1, EInvalidLen);

    let flag = signature[0];
    // Match pattern similar to switch case
    let (sig_len, pk_len) = match (flag) {
        ED25519_FLAG => (ED25519_SIG_LEN, ED25519_PK_LEN),
        _ => abort EUnsupportedScheme,
    };

    let expected_len = 1 + sig_len + pk_len;
    assert!(len == expected_len, EInvalidLen);

    // Extract signature bytes (from index 1 to 1 + sig_len)
    let raw_sig = extract_bytes(&signature, 1, 1 + sig_len);

    // Extract public key bytes (from index 1 + sig_len to expected_len)
    let raw_public_key = extract_bytes(&signature, 1 + sig_len, expected_len);

    // deserializes the message
    let message_bcs = bcs::to_bytes(&message);
    // Hash the message with intent
    // x"030000" based upon `Intent::personal_message()` in Sui's shared-crypto crate:
    // 0x03 = IntentScope::PersonalMessage intent scope in Sui protocol
    // 0x00 = IntentVersion::V0 intent version
    // 0x00 = AppId::Sui
    let mut message_with_intent = x"030000";
    message_with_intent.append(message_bcs);
    let digest = hash::blake2b256(&message_with_intent);

    let sig_address = derive_address_from_public_key(raw_public_key);
    if (sig_address != expected_address) {
        return false
    };

    match (flag) {
        ED25519_FLAG => {
            ed25519::ed25519_verify(&raw_sig, &raw_public_key, &digest)
        },
        _ => abort EUnsupportedScheme,
    }
}

// === Private Functions ===

/// Extracts a slice of bytes from a vector within the specified range [start, end).
///
/// # Returns
/// A new vector containing the bytes from `start` to `end - 1`
fun extract_bytes(source: &vector<u8>, start: u64, end: u64): vector<u8> {
    // Creates a vector of size (end-start) by mapping indices 0.. to source[start+i]
    vector::tabulate!(end - start, |i| source[start + i])
}
