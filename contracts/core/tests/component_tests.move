#[test_only]
module core::component_tests;

use core::component;
use sui::{bcs, hash};

#[test]
fun id_from_name_returns_deterministic_u64() {
    let mut identity = bcs::new(hash::blake2b256(&b"identity"));
    let mut metadata = bcs::new(hash::blake2b256(&b"metadata"));
    assert!(component::id_from_name(b"identity") == identity.peel_u64());
    assert!(component::id_from_name(b"metadata") == metadata.peel_u64());
}
