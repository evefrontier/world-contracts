#[test_only]
module core::owner_cap_tests;

use core::{
    action,
    admin_service,
    entity,
    location_service,
    owner_cap::{Self, AccessCap},
    test_helpers::{setup, take_acl, create_entity}
};
use std::string;
use sui::test_scenario as ts;

const ADMIN: address = @0xA;
const STRANGER: address = @0xC;
const OWNER: address = @0xB;

/// Mint a cap for the shared entity to `owner`.
fun mint_cap_for(scenario: &mut ts::Scenario, owner: address, transferable: bool) {
    ts::next_tx(scenario, ADMIN);
    let mut e = ts::take_shared<entity::Entity>(scenario);
    let acl = take_acl(scenario);
    let mut req = e.mint_access(owner, transferable, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(e);
    ts::return_shared(acl);
}

const OWNER_ACTION: vector<u8> = b"deposit_by_owner";

/// Enable an owner-gated action on the shared entity.
fun enable_owner_action(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    let mut e = ts::take_shared<entity::Entity>(scenario);
    let act = action::new(vector[owner_cap::owner_requirement()]);
    let req = e.enable_action(string::utf8(OWNER_ACTION), act, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(e);
}

#[test]
fun mint_access_grants_cap_to_owner() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let entity_id = create_entity(&mut scenario, 1);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut e = ts::take_shared<entity::Entity>(&scenario);
        let acl = take_acl(&scenario);
        let mut req = e.mint_access(OWNER, false, scenario.ctx());
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);
        ts::return_shared(e);
        ts::return_shared(acl);
    };

    ts::next_tx(&mut scenario, OWNER);
    {
        let cap = ts::take_from_sender<AccessCap>(&scenario);
        assert!(cap.entity() == entity_id);
        assert!(!cap.is_transferable());
        ts::return_to_sender(&scenario, cap);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun mint_access_by_non_admin_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    create_entity(&mut scenario, 1);

    ts::next_tx(&mut scenario, STRANGER);
    let mut e = ts::take_shared<entity::Entity>(&scenario);
    let acl = take_acl(&scenario);
    let mut req = e.mint_access(OWNER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());

    abort
}

#[test]
fun verify_passes_with_matching_cap() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    create_entity(&mut scenario, 1);
    mint_cap_for(&mut scenario, OWNER, false);
    enable_owner_action(&mut scenario);

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut e = ts::take_shared<entity::Entity>(&scenario);
        let cap = ts::take_from_sender<AccessCap>(&scenario);
        let mut req = e.interact(string::utf8(OWNER_ACTION), scenario.ctx());
        location_service::verify_proximity(&mut req, vector[]);
        owner_cap::verify(&mut req, &cap);
        e.complete_request(req);
        ts::return_shared(e);
        ts::return_to_sender(&scenario, cap);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = owner_cap::ENotOwner)]
fun verify_aborts_with_wrong_entity_cap() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let one = create_entity(&mut scenario, 1);
    let two = create_entity(&mut scenario, 2);

    // Mint a cap for entity two to OWNER, and enable the owner action on entity one.
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut e2 = ts::take_shared_by_id<entity::Entity>(&scenario, two);
        let acl = take_acl(&scenario);
        let mut req = e2.mint_access(OWNER, false, scenario.ctx());
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e2.complete_request(req);
        ts::return_shared(e2);
        ts::return_shared(acl);

        let mut e1 = ts::take_shared_by_id<entity::Entity>(&scenario, one);
        let act = action::new(vector[owner_cap::owner_requirement()]);
        let req = e1.enable_action(string::utf8(OWNER_ACTION), act, scenario.ctx());
        e1.complete_request(req);
        ts::return_shared(e1);
    };

    // Interact with entity one using the cap bound to entity two.
    ts::next_tx(&mut scenario, OWNER);
    let mut e1 = ts::take_shared_by_id<entity::Entity>(&scenario, one);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e1.interact(string::utf8(OWNER_ACTION), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    owner_cap::verify(&mut req, &cap);

    abort
}

#[test]
fun transfer_access_moves_transferable_cap() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    create_entity(&mut scenario, 1);
    mint_cap_for(&mut scenario, OWNER, true);

    ts::next_tx(&mut scenario, OWNER);
    {
        let cap = ts::take_from_sender<AccessCap>(&scenario);
        owner_cap::transfer_access(cap, STRANGER);
    };

    ts::next_tx(&mut scenario, STRANGER);
    {
        let cap = ts::take_from_sender<AccessCap>(&scenario);
        ts::return_to_sender(&scenario, cap);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = owner_cap::ENotTransferable)]
fun transfer_access_aborts_on_soulbound_cap() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    create_entity(&mut scenario, 1);
    mint_cap_for(&mut scenario, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    owner_cap::transfer_access(cap, STRANGER);

    abort
}
