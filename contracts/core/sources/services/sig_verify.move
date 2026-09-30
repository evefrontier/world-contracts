/// Ed25519 personal-message signatures: `[flag][signature][publicKey]`.
///
/// The signed digest is blake2b256 of `x"030000" || message`. `x"030000"` is
/// Sui's PersonalMessage intent (scope, version 0, AppId::Sui). The message is
/// raw bytes, not BCS-wrapped again.
module core::sig_verify;

use sui::{ed25519, hash};

// === Errors ===

#[error(code = 0)]
const EInvalidPublicKeyLen: vector<u8> = b"Invalid public key length";
#[error(code = 1)]
const EUnsupportedScheme: vector<u8> = b"Unsupported signature scheme";
#[error(code = 2)]
const EInvalidLen: vector<u8> = b"Invalid signature length";

// === Constants ===

const ED25519_FLAG: u8 = 0x00;
const ED25519_SIG_LEN: u64 = 64;
const ED25519_PK_LEN: u64 = 32;

// === Public Functions ===

/// Sui address of an Ed25519 public key: blake2b256(`0x00 || public_key`).
public fun derive_address_from_public_key(public_key: vector<u8>): address {
    assert!(public_key.length() == ED25519_PK_LEN, EInvalidPublicKeyLen);
    let mut flagged = vector[ED25519_FLAG];
    flagged.append(public_key);
    sui::address::from_bytes(hash::blake2b256(&flagged))
}

/// True when `signature` is `expected_address`'s personal-message signature over `message`.
public fun verify_signature(
    message: vector<u8>,
    signature: vector<u8>,
    expected_address: address,
): bool {
    assert!(signature.length() >= 1, EInvalidLen);
    let flag = signature[0];
    assert!(flag == ED25519_FLAG, EUnsupportedScheme);
    let expected_len = 1 + ED25519_SIG_LEN + ED25519_PK_LEN;
    assert!(signature.length() == expected_len, EInvalidLen);

    let raw_signature = slice(&signature, 1, 1 + ED25519_SIG_LEN);
    let public_key = slice(&signature, 1 + ED25519_SIG_LEN, expected_len);
    if (derive_address_from_public_key(public_key) != expected_address) {
        return false
    };

    // Hash the message with the Sui PersonalMessage intent prefix.
    // x"030000" is based on `Intent::personal_message()` from Sui's shared-crypto crate:
    //   0x03 = IntentScope::PersonalMessage intent scope in the Sui protocol
    //   0x00 = IntentVersion::V0 intent version
    //   0x00 = AppId::Sui
    //
    // Note: The raw `message` bytes are appended directly (no BCS serialization). This
    // matches the Go backend's `SignPersonalMessage` implementation and intentionally
    // differs from the original behaviour, which BCS-serializes the message.
    let mut intent_message = x"030000";
    intent_message.append(message);
    ed25519::ed25519_verify(&raw_signature, &public_key, &hash::blake2b256(&intent_message))
}

// === Private Functions ===

fun slice(packed: &vector<u8>, start: u64, end: u64): vector<u8> {
    vector::tabulate!(end - start, |i| packed[start + i])
}
