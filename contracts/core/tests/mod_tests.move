#[test_only]
module core::mod_tests;

use core::mod;
use sui::{bcs, hash};

#[test]
fun id_from_name_is_first_8_le_bytes_of_blake2b256() {
    let mut identity = bcs::new(hash::blake2b256(&b"identity"));
    let mut metadata = bcs::new(hash::blake2b256(&b"metadata"));
    assert!(mod::id_from_name(b"identity") == identity.peel_u64());
    assert!(mod::id_from_name(b"metadata") == metadata.peel_u64());
}
