#[test_only]
module character::character_tests;

use character::identity;
use core::{
    admin_service::{Self, AdminACL},
    entity::{Self, Entity, EntityCreated},
    entity_key,
    mod,
    object_registry::{Self, ObjectRegistry}
};
use std::string::{Self, String};
use sui::{event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const OWNER2: address = @0xC;
const TENANT: vector<u8> = b"alpha";
const TENANT2: vector<u8> = b"beta";
const IN_GAME_ID: u64 = 42;
const TRIBE_ID: u32 = 7;

fun tenant(): String { string::utf8(TENANT) }

fun setup(scenario: &mut ts::Scenario) {
    object_registry::init_for_testing(scenario.ctx());
    admin_service::init_for_testing(scenario.ctx());
}

/// Full character-creation flow, as a client PTB would issue it:
fun create_character(
    scenario: &mut ts::Scenario,
    in_game_id: u64,
    tenant: String,
    tribe_id: u32,
    owner: address,
) {
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);

    let (mut character, mut req) = entity::new(&mut registry, in_game_id, tenant);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    character.complete_request(req);

    let mut req = identity::install(&mut character, tribe_id, owner, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    character.complete_request(req);

    character.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
}

/// Resolve the deterministic character object ID for `(in_game_id, tenant)`.
fun character_id(registry: &ObjectRegistry, in_game_id: u64, tenant: String): ID {
    object::id_from_address(registry.derive_id(entity_key::new(in_game_id, tenant)))
}

#[test]
fun create_installs_identity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let e = ts::take_shared<Entity>(&scenario);
        assert!(e.has_module(identity::module_id()));
        assert!(identity::module_id() == mod::id_from_name(b"identity"));
        assert!(identity::tribe_id(&e) == TRIBE_ID);
        assert!(identity::owner(&e) == OWNER);
        assert!(e.key() == entity_key::new(IN_GAME_ID, tenant()));
        ts::return_shared(e);
    };

    scenario.end();
}

#[test]
fun create_emits_entity_created() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);

    assert!(event::events_by_type<EntityCreated>().length() == 1);

    scenario.end();
}

#[test]
fun uninstall_identity_removes_module() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut e = ts::take_shared<Entity>(&scenario);
        let acl = ts::take_shared<AdminACL>(&scenario);
        let mut req = identity::uninstall(&mut e, scenario.ctx());
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);

        assert!(!e.has_module(identity::module_id()));
        ts::return_shared(acl);
        ts::return_shared(e);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = identity::EModuleMissing)]
fun uninstall_without_identity_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    // Claim an entity but never install identity.
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let (mut e, mut req) = entity::new(&mut registry, IN_GAME_ID, tenant());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    let _req = identity::uninstall(&mut e, scenario.ctx());

    abort
}

#[test]
fun same_id_different_tenants_are_distinct() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, string::utf8(TENANT2), TRIBE_ID + 1, OWNER2);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = ts::take_shared<ObjectRegistry>(&scenario);
        let id_a = character_id(&registry, IN_GAME_ID, tenant());
        let id_b = character_id(&registry, IN_GAME_ID, string::utf8(TENANT2));
        ts::return_shared(registry);
        assert!(id_a != id_b);

        let a = ts::take_shared_by_id<Entity>(&scenario, id_a);
        let b = ts::take_shared_by_id<Entity>(&scenario, id_b);
        assert!(identity::owner(&a) == OWNER);
        assert!(identity::owner(&b) == OWNER2);
        assert!(identity::tribe_id(&b) == TRIBE_ID + 1);
        ts::return_shared(a);
        ts::return_shared(b);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = entity::EEntityAlreadyExists)]
fun create_twice_same_key_fails() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);

    abort
}
