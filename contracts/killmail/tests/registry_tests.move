#[test_only]
module killmail::registry_tests;

use core::test_helpers::tenant;
use killmail::registry::{Self, KillmailRegistry};
use std::string;
use sui::{derived_object, test_scenario as ts};

// Test Constants
const ADMIN: address = @0xA;

#[test]
fun init_shares_registry_with_stable_id() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = take_registry(&scenario);
        assert!(registry::id(&registry) == object::id(&registry));
        assert!(registry::version(&registry) == 1);
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test]
fun fresh_key_does_not_exist() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = take_registry(&scenario);
        let key = registry::new_key(tenant(), 1);
        assert!(!registry.exists(key));
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test]
fun derive_id_is_deterministic() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = take_registry(&scenario);
        let key = registry::new_key(tenant(), 5);
        assert!(registry.derive_id(key) == registry.derive_id(key));
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test]
fun derive_id_differs_by_key() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = take_registry(&scenario);
        let by_id_a = registry.derive_id(registry::new_key(tenant(), 1));
        let by_id_b = registry.derive_id(registry::new_key(tenant(), 2));
        let by_tenant = registry.derive_id(registry::new_key(string::utf8(b"other"), 1));
        assert!(by_id_a != by_id_b);
        assert!(by_id_a != by_tenant);
        ts::return_shared(registry);
    };

    scenario.end();
}

/// Claiming a key flips `exists` to true and the claimed UID matches the
/// pre-computed derived address.
#[test]
fun claim_marks_key_existing() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = take_registry(&scenario);
        let key = registry::new_key(tenant(), 99);
        let precomputed = object::id_from_address(registry.derive_id(key));

        let uid = derived_object::claim(registry.borrow_id(), key);

        assert!(registry.exists(key));
        assert!(uid.to_inner() == precomputed);

        uid.delete();
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test]
fun new_key_holds_tenant_and_id() {
    let key = registry::new_key(tenant(), 42);
    assert!(key.tenant() == tenant());
    assert!(key.killmail_id() == 42);
}

#[test, expected_failure(abort_code = registry::ETenantEmpty)]
fun new_key_empty_tenant_aborts() {
    registry::new_key(string::utf8(b""), 1);
    abort
}

#[test, expected_failure(abort_code = registry::EKillmailIdZero)]
fun new_key_zero_id_aborts() {
    registry::new_key(tenant(), 0);
    abort
}

// === Test Functions ===
fun setup(scenario: &mut ts::Scenario) {
    registry::init_for_testing(scenario.ctx());
}

public fun take_registry(scenario: &ts::Scenario): KillmailRegistry {
    ts::take_shared<KillmailRegistry>(scenario)
}
