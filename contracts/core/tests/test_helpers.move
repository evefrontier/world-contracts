#[test_only]
module core::test_helpers;

use core::{
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    object_registry::{Self, ObjectRegistry}
};
use std::string::{Self, String};
use sui::test_scenario as ts;

const ADMIN: address = @0xA;
const TENANT: vector<u8> = b"test";

public fun admin(): address { ADMIN }

public fun tenant(): String { string::utf8(TENANT) }

/// Init the object registry and admin service, seeding the deployer as admin.
public fun setup(scenario: &mut ts::Scenario) {
    object_registry::init_for_testing(scenario.ctx());
    admin_service::init_for_testing(scenario.ctx());
}

public fun take_acl(scenario: &ts::Scenario): AdminACL {
    ts::take_shared<AdminACL>(scenario)
}

public fun take_registry(scenario: &ts::Scenario): ObjectRegistry {
    ts::take_shared<ObjectRegistry>(scenario)
}

/// Claim and admin-approve an entity, returning it unlocked (not shared).
public fun claim(
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    id: u64,
    ctx: &mut TxContext,
): Entity {
    let (mut e, mut req) = entity::new(registry, id, tenant(), vector[]);
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
    e
}

/// Claim, admin-approve, and share an entity in an ADMIN tx, returning its id.
public fun create_entity(scenario: &mut ts::Scenario, id: u64): ID {
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let e = claim(&mut registry, &acl, id, scenario.ctx());
    let entity_id = entity::id(&e);
    entity::share(e);
    ts::return_shared(acl);
    ts::return_shared(registry);
    entity_id
}
