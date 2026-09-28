#[test_only]
module core::docking_tests;

use core::{docking::{Self, Docking}, proof, test_helpers::{setup, take_acl}};
use std::type_name;
use sui::{bcs, clock, test_scenario as ts};

const PILOT: address = @0xA;
const SHIP: address = @0x5;
const TARGET: address = @0x6;
const NON_PLAYER: address = @0x7;
const CHARACTER: address = @0x8;
const DEADLINE: u64 = 1000;

fun entity_id(entity: address): ID { object::id_from_address(entity) }

fun docking_kind(): vector<u8> {
    type_name::with_original_ids<Docking>().into_string().into_bytes()
}

fun payload(ship: address, target: address): vector<u8> {
    let mut docking_proof_payload = bcs::to_bytes(&ship);
    docking_proof_payload.append(bcs::to_bytes(&target));
    let character = CHARACTER;
    docking_proof_payload.append(bcs::to_bytes(&character));
    docking_proof_payload
}

fun docking_proof(sender: address, kind: vector<u8>, deadline_ms: u64): vector<u8> {
    proof::proof_bytes_for_testing(sender, kind, deadline_ms, payload(SHIP, TARGET))
}

#[test]
fun verify_decodes_the_payload() {
    let mut scenario = ts::begin(PILOT);
    let clock = clock::create_for_testing(scenario.ctx());
    docking::verify(docking_proof(PILOT, docking_kind(), DEADLINE), &clock, scenario.ctx());
    let verified_docking = docking::cached(scenario.ctx()).signed_docking();
    assert!(
        verified_docking.ship() == entity_id(SHIP) && verified_docking.target() == entity_id(TARGET) && verified_docking.character() == entity_id(CHARACTER),
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = proof::EWrongKind)]
fun proof_of_another_kind_aborts() {
    let mut scenario = ts::begin(PILOT);
    let clock = clock::create_for_testing(scenario.ctx());
    docking::verify(
        docking_proof(PILOT, b"0::gate::GateDistance", DEADLINE),
        &clock,
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = proof::EWrongSender)]
fun proof_for_another_sender_aborts() {
    let mut scenario = ts::begin(PILOT);
    let clock = clock::create_for_testing(scenario.ctx());
    docking::verify(docking_proof(NON_PLAYER, docking_kind(), DEADLINE), &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = proof::EDeadlineExpired)]
fun expired_proof_aborts() {
    let mut scenario = ts::begin(PILOT);
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(DEADLINE);
    docking::verify(docking_proof(PILOT, docking_kind(), DEADLINE), &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = docking::ESameCreation)]
fun ship_docked_at_itself_aborts() {
    let mut scenario = ts::begin(PILOT);
    let clock = clock::create_for_testing(scenario.ctx());
    let bytes = proof::proof_bytes_for_testing(
        PILOT,
        docking_kind(),
        DEADLINE,
        payload(SHIP, SHIP),
    );
    docking::verify(bytes, &clock, scenario.ctx());
    abort
}

#[test]
fun both_sides_pass_with_one_docking() {
    let mut ctx = tx_context::dummy();
    docking::dock_for_testing(entity_id(SHIP), entity_id(TARGET), entity_id(CHARACTER), &mut ctx);
    docking::assert_docked(entity_id(SHIP), option::none(), &mut ctx);
    docking::assert_docked(entity_id(TARGET), option::some(entity_id(SHIP)), &mut ctx);
    docking::assert_docked(entity_id(TARGET), option::some(entity_id(TARGET)), &mut ctx);
}

#[test, expected_failure(abort_code = docking::EAlreadyDocked)]
fun second_docking_in_a_transaction_aborts() {
    let mut scenario = ts::begin(PILOT);
    let clock = clock::create_for_testing(scenario.ctx());
    docking::verify(docking_proof(PILOT, docking_kind(), DEADLINE), &clock, scenario.ctx());
    docking::verify(docking_proof(PILOT, docking_kind(), DEADLINE), &clock, scenario.ctx());
    abort
}

#[test, expected_failure(abort_code = docking::ENoDocking)]
fun check_without_docking_aborts() {
    let mut ctx = tx_context::dummy();
    docking::assert_docked(entity_id(SHIP), option::none(), &mut ctx);
}

#[test, expected_failure(abort_code = docking::ENotDocked)]
fun entity_outside_docking_aborts() {
    let mut ctx = tx_context::dummy();
    docking::dock_for_testing(entity_id(SHIP), entity_id(TARGET), entity_id(CHARACTER), &mut ctx);
    docking::assert_docked(entity_id(NON_PLAYER), option::none(), &mut ctx);
}

#[test, expected_failure(abort_code = docking::EWrongSource)]
fun source_outside_docking_aborts() {
    let mut ctx = tx_context::dummy();
    docking::dock_for_testing(entity_id(SHIP), entity_id(TARGET), entity_id(CHARACTER), &mut ctx);
    docking::assert_docked(entity_id(TARGET), option::some(entity_id(NON_PLAYER)), &mut ctx);
}

#[test]
fun admin_attests_any_docking() {
    let mut scenario = ts::begin(PILOT);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, PILOT);
    let acl = take_acl(&scenario);
    docking::attest(&acl, scenario.ctx());
    docking::assert_docked(entity_id(NON_PLAYER), option::some(entity_id(SHIP)), scenario.ctx());
    ts::return_shared(acl);
    scenario.end();
}

#[test, expected_failure(abort_code = docking::ENotAttester)]
fun non_admin_cannot_attest() {
    let mut scenario = ts::begin(PILOT);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, NON_PLAYER);
    let acl = take_acl(&scenario);
    docking::attest(&acl, scenario.ctx());
    abort
}

/// Bytes from the SDK's `dockingProof` (ship 0x5, target 0x6, character 0x8,
/// sender 0xa, deadline 1000), so the two encoders stay in step.
#[test]
fun verify_decodes_sdk_bytes() {
    let mut scenario = ts::begin(@0xA);
    let clock = clock::create_for_testing(scenario.ctx());
    let docking_proof_bytes =
        x"0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a52303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303030303a3a646f636b696e673a3a446f636b696e67e8030000000000006000000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000800";
    docking::verify(docking_proof_bytes, &clock, scenario.ctx());
    let verified_docking = docking::cached(scenario.ctx()).signed_docking();
    assert!(
        verified_docking.ship() == entity_id(SHIP) && verified_docking.target() == entity_id(TARGET) && verified_docking.character() == entity_id(CHARACTER),
    );
    clock.destroy_for_testing();
    scenario.end();
}
