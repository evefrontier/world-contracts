#[test_only]
module world::sig_verify_tests;

use std::bcs;
use world::sig_verify;

public struct Message has drop {
    from: address,
    custom_message: vector<u8>,
    distance: u64,
}

public fun message_to_bytes(msg: &Message): vector<u8> {
    bcs::to_bytes(msg)
}

#[test]
fun derive_address_from_ed25519_public_key() {
    let public_key = x"a94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";

    let result = sig_verify::derive_address_from_public_key(public_key);
    let expected = sui::address::from_bytes(
        x"93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef78295333",
    );

    assert!(result == expected);
}

#[test]
#[expected_failure(abort_code = sig_verify::EInvalidPublicKeyLen)]
fun derive_address_from_public_key_too_long() {
    let public_key = x"00c5f37062e0272cdf7382a01c61f0cf364b3ae54132978cdd12e5a5f958207b2f";

    let result = sig_verify::derive_address_from_public_key(public_key);
    let expected = sui::address::from_bytes(
        x"93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef78295333",
    );

    assert!(result == expected);
}

#[test]
#[expected_failure(abort_code = sig_verify::EInvalidPublicKeyLen)]
fun derive_address_from_public_key_too_short() {
    let public_key = x"f37062e0272cdf7382a01c61f0cf364b3ae54132978cdd12e5a5f958207b2f";

    let result = sig_verify::derive_address_from_public_key(public_key);
    let expected = sui::address::from_bytes(
        x"93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef78295333",
    );

    assert!(result == expected);
}

#[test]
fun verify_full_signature_correct_sig() {
    let message = b"Hello, World!";
    let full_sig =
        x"00f623a12f78cfdf7900a2686b574f443fe8714ea4af282e983467e8f197dc84d28a6db531d2292cbdca2055b74be6922aab28da710bf26b6ebc794c9cee162008a94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";
    let expected_address = sui::address::from_bytes(
        x"93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef78295333",
    );

    let result = sig_verify::verify_signature(message, full_sig, expected_address);

    assert!(result);
}

#[test]
fun verify_full_signature_formatted_message() {
    let message = Message {
        from: sui::address::from_bytes(
            x"93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef78295333",
        ),
        custom_message: b"I as a server attest this character is in this location",
        distance: 0,
    };
    let message_bytes = message_to_bytes(&message);

    let full_sig =
        x"001012b5f3a8da00a9edb04a49f5ed97f923807fa8fa39d8a3bfbadf7349eac9e3bdc1e1509b4639a50c1548db6094249a2c193c3b1b7a98267782a4defc304204a94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";
    let expected_address = message.from;

    let result = sig_verify::verify_signature(message_bytes, full_sig, expected_address);

    assert!(result);
}

#[test]
fun verify_full_signature_correct_sig_wrong_address() {
    let message = b"Hello, World!";
    let full_sig =
        x"006228f74ec83910e326a294b555f5d2f4183f3fd37335468a766d9ff3a04b82f8d7a8bff9908ab11f43d9c206ef6fa2743dc821b5059b6ac856e670c3dc45be0191dae31b6d33559fffd6092b5a3727b5d79c224e117cac59b57358003db9eefd";
    let expected_address = sui::address::from_bytes(
        x"5ddb44b7188932c0ee5cd5d9c6a01b50343e92d7e83e95154de5ff6475f16454",
    );

    let result = sig_verify::verify_signature(message, full_sig, expected_address);

    assert!(!result);
}

#[test]
fun verify_full_signature_wrong_sig() {
    let message = b"Hello, World!";
    let full_sig =
        x"007228f74ec83910e326a294b555f5d2f4183f3fd37335468a766d9ff3a04b82f8d7a8bff9908ab11f43d9c206ef6fa2743dc821b5059b6ac856e670c3dc45be0191dae31b6d33559fffd6092b5a3727b5d79c224e117cac59b57358003db9eefd";
    let expected_address = sui::address::from_bytes(
        x"4ddb44b7188932c0ee5cd5d9c6a01b50343e92d7e83e95154de5ff6475f16454",
    );

    let result = sig_verify::verify_signature(message, full_sig, expected_address);

    assert!(!result);
}

#[test]
#[expected_failure(abort_code = sig_verify::EUnsupportedScheme)]
fun verify_full_signature_unknown_scheme() {
    let message = b"Hello, World!";
    let full_sig =
        x"017228f74ec83910e326a294b555f5d2f4183f3fd37335468a766d9ff3a04b82f8d7a8bff9908ab11f43d9c206ef6fa2743dc821b5059b6ac856e670c3dc45be0191dae31b6d33559fffd6092b5a3727b5d79c224e117cac59b57358003db9eefd";
    let expected_address = sui::address::from_bytes(
        x"4ddb44b7188932c0ee5cd5d9c6a01b50343e92d7e83e95154de5ff6475f16454",
    );

    let result = sig_verify::verify_signature(message, full_sig, expected_address);

    assert!(result);
}

#[test]
#[expected_failure(abort_code = sig_verify::EInvalidLen)]
fun verify_full_signature_invalid_len_too_short() {
    let message = b"Hello, World!";
    let full_sig =
        x"0028f74ec83910e326a294b555f5d2f4183f3fd37335468a766d9ff3a04b82f8d7a8bff9908ab11f43d9c206ef6fa2743dc821b5059b6ac856e670c3dc45be0191dae31b6d33559fffd6092b5a3727b5d79c224e117cac59b57358003db9eefd";
    let expected_address = sui::address::from_bytes(
        x"4ddb44b7188932c0ee5cd5d9c6a01b50343e92d7e83e95154de5ff6475f16454",
    );

    let result = sig_verify::verify_signature(message, full_sig, expected_address);

    assert!(result);
}

#[test]
#[expected_failure(abort_code = sig_verify::EInvalidLen)]
fun verify_full_signature_invalid_len_too_long() {
    let message = b"Hello, World!";
    let full_sig =
        x"00007228f74ec83910e326a294b555f5d2f4183f3fd37335468a766d9ff3a04b82f8d7a8bff9908ab11f43d9c206ef6fa2743dc821b5059b6ac856e670c3dc45be0191dae31b6d33559fffd6092b5a3727b5d79c224e117cac59b57358003db9eefd";
    let expected_address = sui::address::from_bytes(
        x"4ddb44b7188932c0ee5cd5d9c6a01b50343e92d7e83e95154de5ff6475f16454",
    );

    let result = sig_verify::verify_signature(message, full_sig, expected_address);

    assert!(result);
}
