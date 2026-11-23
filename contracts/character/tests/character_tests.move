#[test_only]
module character::character_tests;

use character::identity::{Self, CharacterCreated, CharacterUpdated};
use core::{
    access_cap::AccessCap,
    action,
    admin_service::{Self, AdminACL},
    component,
    entity::{Self, Entity, EntityCreated},
    entity_key,
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

/// Admin exposes `edit_character` on the shared character: the identity component's
/// `Edit` requirement, which itself requires the admin.
fun enable_edit_character(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    let mut e = ts::take_shared<Entity>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let act = action::new(vector[identity::edit_requirement()]);
    let mut req = e.enable_admin_action(string::utf8(b"edit_character"), act, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(e);
}

/// `sender` runs the `edit_character` action on the shared character.
fun edit_character(scenario: &mut ts::Scenario, sender: address, new_tribe_id: u32) {
    ts::next_tx(scenario, sender);
    let mut e = ts::take_shared<Entity>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let mut req = e.interact(string::utf8(b"edit_character"), scenario.ctx());
    identity::edit(&mut e, &mut req, new_tribe_id);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(e);
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
        assert!(e.has_component(identity::component_id()));
        assert!(identity::component_id() == component::id_from_name(b"identity"));
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
fun create_emits_character_created() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);

    assert!(event::events_by_type<CharacterCreated>().length() == 1);

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

        assert!(!e.has_component(identity::component_id()));
        ts::return_shared(acl);
        ts::return_shared(e);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = identity::EComponentMissing)]
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
fun admin_edits_character() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);
    enable_edit_character(&mut scenario);
    edit_character(&mut scenario, ADMIN, TRIBE_ID + 1);

    assert!(event::events_by_type<CharacterUpdated>().length() == 1);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let e = ts::take_shared<Entity>(&scenario);
        assert!(identity::tribe_id(&e) == TRIBE_ID + 1);
        assert!(identity::owner(&e) == OWNER);
        ts::return_shared(e);
    };

    scenario.end();
}

#[test]
fun edit_character_without_changes_skips_event() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);
    enable_edit_character(&mut scenario);
    edit_character(&mut scenario, ADMIN, TRIBE_ID);

    assert!(event::events_by_type<CharacterUpdated>().length() == 0);

    scenario.end();
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun non_admin_edit_character_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);
    enable_edit_character(&mut scenario);
    edit_character(&mut scenario, OWNER, TRIBE_ID + 1);

    abort
}

/// An owner-configured action with only `edit_requirement` still can't skip the
/// admin gate: `edit` enqueues it, so the request can't complete without it.
#[test, expected_failure(abort_code = core::request::ERequestNotComplete)]
fun owner_action_cannot_edit_without_admin() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, IN_GAME_ID, tenant(), TRIBE_ID, OWNER);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut e = ts::take_shared<Entity>(&scenario);
        let acl = ts::take_shared<AdminACL>(&scenario);
        let mut req = e.mint_access(OWNER, false, scenario.ctx());
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);
        ts::return_shared(acl);
        ts::return_shared(e);
    };

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut e = ts::take_shared<Entity>(&scenario);
        let cap = ts::take_from_sender<AccessCap>(&scenario);
        let act = action::new(vector[identity::edit_requirement()]);
        let mut req = e.enable_action(string::utf8(b"self_edit"), act, scenario.ctx());
        e.verify_owner(&mut req, &cap);
        e.complete_request(req);
        ts::return_to_sender(&scenario, cap);
        ts::return_shared(e);
    };

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared<Entity>(&scenario);
    let mut req = e.interact(string::utf8(b"self_edit"), scenario.ctx());
    identity::edit(&mut e, &mut req, TRIBE_ID + 1);
    e.complete_request(req);

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
