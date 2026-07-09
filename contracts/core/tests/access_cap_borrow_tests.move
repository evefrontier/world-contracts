#[test_only]
module core::access_cap_borrow_tests;

use core::{
    access_cap::{Self, AccessCap},
    admin_service,
    entity::{Self, Entity},
    test_helpers::{setup, take_acl, create_entity}
};
use sui::test_scenario as ts;

const ADMIN: address = @0xA;
const OWNER: address = @0xB;

/// Mint the cap of `entity_id` to `owner` in an ADMIN tx. `owner` may be a plain
/// address or an entity object address (to park the cap on that entity).
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

/// Object id of the (single) `AccessCap` parked on `parent`.
fun parked_cap_id(parent: ID): ID {
    ts::most_recent_id_for_address<AccessCap>(parent.to_address()).destroy_some()
}

#[test]
fun borrow_then_return_reparks_cap_on_character() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su = create_entity(&mut scenario, 2);

    // Park the SU owner cap on the character; give the character's own cap to OWNER.
    mint_cap(&mut scenario, su, character.to_address(), true);
    mint_cap(&mut scenario, character, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    {
        let su_cap_id = parked_cap_id(character);
        let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
        let char_cap = ts::take_from_sender<AccessCap>(&scenario);
        let ticket = ts::receiving_ticket_by_id<AccessCap>(su_cap_id);

        let (su_cap, receipt) = c.borrow_access(&char_cap, ticket);
        assert!(su_cap.entity() == su);
        c.return_access(su_cap, receipt);

        ts::return_to_sender(&scenario, char_cap);
        ts::return_shared(c);
    };

    // The SU cap is back on the character.
    ts::next_tx(&mut scenario, OWNER);
    assert!(ts::has_most_recent_for_address<AccessCap>(character.to_address()));

    scenario.end();
}

#[test, expected_failure(abort_code = access_cap::ENotOwner)]
fun borrow_with_foreign_cap_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su = create_entity(&mut scenario, 2);
    let other = create_entity(&mut scenario, 3);

    mint_cap(&mut scenario, su, character.to_address(), true);
    // OWNER holds a cap for `other`, not the character.
    mint_cap(&mut scenario, other, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    let su_cap_id = parked_cap_id(character);
    let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
    let foreign_cap = ts::take_from_sender<AccessCap>(&scenario);
    let ticket = ts::receiving_ticket_by_id<AccessCap>(su_cap_id);

    let (_su_cap, _receipt) = c.borrow_access(&foreign_cap, ticket);

    abort
}

#[test]
fun transfer_with_receipt_relocates_cap_to_another_entity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su = create_entity(&mut scenario, 2);
    let other_character = create_entity(&mut scenario, 3);

    mint_cap(&mut scenario, su, character.to_address(), true);
    mint_cap(&mut scenario, character, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    {
        let su_cap_id = parked_cap_id(character);
        let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
        let char_cap = ts::take_from_sender<AccessCap>(&scenario);
        let ticket = ts::receiving_ticket_by_id<AccessCap>(su_cap_id);

        let (su_cap, receipt) = c.borrow_access(&char_cap, ticket);
        access_cap::transfer_with_receipt(su_cap, receipt, other_character.to_address());

        ts::return_to_sender(&scenario, char_cap);
        ts::return_shared(c);
    };

    // The cap now lives on the other character, not the original.
    ts::next_tx(&mut scenario, OWNER);
    assert!(ts::has_most_recent_for_address<AccessCap>(other_character.to_address()));
    assert!(!ts::has_most_recent_for_address<AccessCap>(character.to_address()));

    scenario.end();
}

#[test, expected_failure(abort_code = access_cap::ENotTransferable)]
fun transfer_with_receipt_soulbound_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su = create_entity(&mut scenario, 2);
    let other_character = create_entity(&mut scenario, 3);

    // A soulbound SU cap can be parked but never relocated.
    mint_cap(&mut scenario, su, character.to_address(), false);
    mint_cap(&mut scenario, character, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    let su_cap_id = parked_cap_id(character);
    let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
    let char_cap = ts::take_from_sender<AccessCap>(&scenario);
    let ticket = ts::receiving_ticket_by_id<AccessCap>(su_cap_id);

    let (su_cap, receipt) = c.borrow_access(&char_cap, ticket);
    access_cap::transfer_with_receipt(su_cap, receipt, other_character.to_address());

    abort
}

#[test, expected_failure(abort_code = access_cap::EReceiptMismatch)]
fun return_with_mismatched_receipt_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let character = create_entity(&mut scenario, 1);
    let su_one = create_entity(&mut scenario, 2);
    let su_two = create_entity(&mut scenario, 3);

    // Park two SU caps on the character.
    mint_cap(&mut scenario, su_one, character.to_address(), true);
    mint_cap(&mut scenario, su_two, character.to_address(), true);
    mint_cap(&mut scenario, character, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    let ids = ts::ids_for_address<AccessCap>(character.to_address());
    let mut c = ts::take_shared_by_id<Entity>(&scenario, character);
    let char_cap = ts::take_from_sender<AccessCap>(&scenario);

    let (cap_a, _receipt_a) = c.borrow_access(
        &char_cap,
        ts::receiving_ticket_by_id<AccessCap>(ids[0]),
    );
    let (_cap_b, receipt_b) = c.borrow_access(
        &char_cap,
        ts::receiving_ticket_by_id<AccessCap>(ids[1]),
    );

    // Returning cap_a with cap_b's receipt aborts on the cap-id check.
    c.return_access(cap_a, receipt_b);

    abort
}
