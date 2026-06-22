#[test_only]
module core::entity_key_tests;

use core::entity_key;
use std::string;

const TENANT: vector<u8> = b"test";

#[test]
fun new_exposes_id_and_tenant() {
    let key = entity_key::new(42, string::utf8(TENANT));
    assert!(key.id() == 42);
    assert!(key.tenant() == string::utf8(TENANT));
}

#[test]
fun keys_with_same_inputs_are_equal() {
    let a = entity_key::new(7, string::utf8(TENANT));
    let b = entity_key::new(7, string::utf8(TENANT));
    assert!(a == b);
}

#[test]
fun keys_differ_by_id() {
    let a = entity_key::new(1, string::utf8(TENANT));
    let b = entity_key::new(2, string::utf8(TENANT));
    assert!(a != b);
}

#[test]
fun keys_differ_by_tenant() {
    let a = entity_key::new(1, string::utf8(b"prod"));
    let b = entity_key::new(1, string::utf8(b"dev"));
    assert!(a != b);
}

#[test, expected_failure(abort_code = entity_key::EIdEmpty)]
fun new_zero_id_aborts() {
    entity_key::new(0, string::utf8(TENANT));
    abort
}

#[test, expected_failure(abort_code = entity_key::ETenantEmpty)]
fun new_empty_tenant_aborts() {
    entity_key::new(1, string::utf8(b""));
    abort
}
