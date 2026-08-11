#[test_only]
module core::object_registry_tests;

use core::{
    admin_service,
    entity,
    entity_key,
    object_registry::{Self, ObjectRegistry},
    test_helpers::{setup, tenant, take_registry, take_acl}
};
use std::string;
use sui::test_scenario as ts;

#[test]
fun init_shares_registry_with_stable_id() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let registry = take_registry(&scenario);
        assert!(object_registry::id(&registry) == object::id(&registry));
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test]
fun fresh_key_does_not_exist() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let registry = take_registry(&scenario);
        let key = entity_key::new(1, tenant());
        assert!(!registry.exists(key));
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test]
fun derive_id_is_deterministic() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let registry = take_registry(&scenario);
        let key = entity_key::new(5, tenant());
        assert!(registry.derive_id(key) == registry.derive_id(key));
        ts::return_shared(registry);
    };

    scenario.end();
}

#[test]
fun derive_id_differs_by_key() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let registry = take_registry(&scenario);
        let by_id_a = registry.derive_id(entity_key::new(1, tenant()));
        let by_id_b = registry.derive_id(entity_key::new(2, tenant()));
        let by_tenant = registry.derive_id(entity_key::new(1, string::utf8(b"other")));
        assert!(by_id_a != by_id_b);
        assert!(by_id_a != by_tenant);
        ts::return_shared(registry);
    };

    scenario.end();
}

/// Claiming an entity flips `exists` to true and the entity's ID matches the
/// pre-computed derived address.
#[test]
fun claim_marks_key_existing() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    {
        let mut registry = take_registry(&scenario);
        let acl = take_acl(&scenario);
        let key = entity_key::new(99, tenant());
        let precomputed = object::id_from_address(registry.derive_id(key));

        let (mut e, mut req) = entity::new(&mut registry, 99, tenant(), b"loc");
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);

        assert!(registry.exists(key));
        assert!(entity::id(&e) == precomputed);

        entity::share(e);
        ts::return_shared(acl);
        ts::return_shared(registry);
    };

    scenario.end();
}
