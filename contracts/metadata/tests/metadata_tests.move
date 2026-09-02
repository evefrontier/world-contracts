#[test_only]
module metadata::metadata_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    location_service,
    mod,
    object_registry::ObjectRegistry,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use metadata::metadata::{Self, MetadataChanged};
use std::string;
use sui::{event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const NAME: vector<u8> = b"Alpha";
const DESC: vector<u8> = b"A test entity";
const URL: vector<u8> = b"https://example.com/a.png";
const NAME2: vector<u8> = b"Beta";
const DESC2: vector<u8> = b"Updated";
const URL2: vector<u8> = b"https://example.com/b.png";
const TYPE_ID: u64 = 1;

/// Install metadata on a fresh entity. No access caps yet.
fun build_entity(
    scenario: &mut ts::Scenario,
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    id: u64,
    name: vector<u8>,
    description: vector<u8>,
    url: vector<u8>,
): Entity {
    let mut e = claim(registry, acl, id, scenario.ctx());
    let mut req = metadata::install(
        &mut e,
        TYPE_ID,
        string::utf8(name),
        string::utf8(description),
        string::utf8(url),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    e
}

/// Create and share a bare character entity; return its id.
fun create_character(
    scenario: &mut ts::Scenario,
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
): ID {
    let character = claim(registry, acl, 2, scenario.ctx());
    let character_id = character.id();
    character.share();
    character_id
}

/// Mint `entity_id`'s AccessCap to `owner` (wallet or character object address).
fun mint_cap(scenario: &mut ts::Scenario, entity_id: ID, owner: address, transferable: bool) {
    ts::next_tx(scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = e.mint_access(owner, transferable, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(e);
    ts::return_shared(acl);
}

fun parked_cap_id(parent: ID): ID {
    ts::most_recent_id_for_address<AccessCap>(parent.to_address()).destroy_some()
}

/// Owner borrows the entity cap parked on their character, enables `edit_metadata`,
/// then returns the cap.
fun enable_edit(scenario: &mut ts::Scenario, entity_id: ID, character_id: ID) {
    ts::next_tx(scenario, OWNER);
    let mut character = ts::take_shared_by_id<Entity>(scenario, character_id);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let char_cap = ts::take_from_sender<AccessCap>(scenario);
    let ticket = ts::receiving_ticket_by_id<AccessCap>(parked_cap_id(character_id));
    let (owner_cap, receipt) = character.borrow_access(&char_cap, ticket);

    let act = action::new(vector[access_cap::owner_requirement(), metadata::edit_requirement()]);
    let mut req = e.enable_action(string::utf8(b"edit_metadata"), act, scenario.ctx());
    access_cap::verify(&mut req, &owner_cap);
    e.complete_request(req);

    character.return_access(owner_cap, receipt);
    ts::return_to_sender(scenario, char_cap);
    ts::return_shared(e);
    ts::return_shared(character);
}

/// Owner borrows the parked entity cap and runs `edit_metadata`.
fun edit_via_character(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    character_id: ID,
    name: vector<u8>,
    description: vector<u8>,
    url: vector<u8>,
) {
    ts::next_tx(scenario, OWNER);
    let mut character = ts::take_shared_by_id<Entity>(scenario, character_id);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let char_cap = ts::take_from_sender<AccessCap>(scenario);
    let ticket = ts::receiving_ticket_by_id<AccessCap>(parked_cap_id(character_id));
    let (owner_cap, receipt) = character.borrow_access(&char_cap, ticket);

    let mut req = e.interact(string::utf8(b"edit_metadata"), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify(&mut req, &owner_cap);
    metadata::edit(
        &mut e,
        &mut req,
        string::utf8(name),
        string::utf8(description),
        string::utf8(url),
    );
    e.complete_request(req);

    character.return_access(owner_cap, receipt);
    ts::return_to_sender(scenario, char_cap);
    ts::return_shared(e);
    ts::return_shared(character);
}

#[test]
fun install_sets_fields_and_emits() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);

    let e = build_entity(&mut scenario, &mut registry, &acl, 1, NAME, DESC, URL);
    assert!(e.has_module(metadata::module_id()));
    assert!(metadata::module_id() == mod::id_from_name(b"metadata"));
    assert!(metadata::name(&e) == string::utf8(NAME));
    assert!(metadata::description(&e) == string::utf8(DESC));
    assert!(metadata::url(&e) == string::utf8(URL));
    assert!(metadata::type_id(&e) == TYPE_ID);
    assert!(event::events_by_type<MetadataChanged>().length() == 1);

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun install_allows_empty_fields() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);

    let e = build_entity(&mut scenario, &mut registry, &acl, 1, b"", b"", b"");
    assert!(metadata::name(&e) == string::utf8(b""));
    assert!(metadata::description(&e) == string::utf8(b""));
    assert!(metadata::url(&e) == string::utf8(b""));

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun edit_via_character_borrow_replaces_fields() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity(&mut scenario, &mut registry, &acl, 1, NAME, DESC, URL);
    let entity_id = e.id();
    e.share();
    let character_id = create_character(&mut scenario, &mut registry, &acl);
    ts::return_shared(acl);
    ts::return_shared(registry);

    // Park entity owner cap on the character; character's own soulbound cap to OWNER.
    mint_cap(&mut scenario, entity_id, character_id.to_address(), true);
    mint_cap(&mut scenario, character_id, OWNER, false);

    enable_edit(&mut scenario, entity_id, character_id);
    edit_via_character(&mut scenario, entity_id, character_id, NAME2, DESC2, URL2);

    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        assert!(metadata::name(&e) == string::utf8(NAME2));
        assert!(metadata::description(&e) == string::utf8(DESC2));
        assert!(metadata::url(&e) == string::utf8(URL2));
        ts::return_shared(e);
    };
    // Cap is back on the character after borrow/return.
    assert!(ts::has_most_recent_for_address<AccessCap>(character_id.to_address()));

    scenario.end();
}

#[test]
fun uninstall_removes_module() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_entity(&mut scenario, &mut registry, &acl, 1, NAME, DESC, URL);

    let mut req = metadata::uninstall(&mut e, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(!e.has_module(metadata::module_id()));

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = metadata::EModuleMissing)]
fun uninstall_without_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    let _req = metadata::uninstall(&mut e, scenario.ctx());

    abort
}
