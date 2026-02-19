#[test_only]
module world::gate_tests;

use std::{bcs, string::utf8};
use sui::{clock, test_scenario as ts};
use world::{
    access::{AdminACL, OwnerCap, ServerAddressRegistry},
    character::{Self, Character},
    energy::EnergyConfig,
    gate::{Self, Gate, GateConfig, JumpPermit},
    location,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, governor, server_admin, tenant, user_a, user_b}
};

// Gate constants
const GATE_TYPE_ID: u64 = 8888;
const GATE_ITEM_ID_1: u64 = 7001;
const GATE_ITEM_ID_2: u64 = 7002;

// TODO: Move to test_helpers
// Network node constants
const MS_PER_SECOND: u64 = 1000;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 100;
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

// Mock extension witness types
public struct GateAuth has drop {}
public struct WrongGateAuth has drop {}

/// TODO: Simulate a builder rule: submit a corpse, receive a ticket.
/// In tests, this just issues a ticket to `character.character_address()` via extension logic.
public fun claim_ticket(
    gate_a: &Gate,
    gate_b: &Gate,
    character: &Character,
    expires_at_timestamp_ms: u64,
    ctx: &mut TxContext,
) {
    // todo: add some requirements to claim a ticket
    gate::issue_jump_permit<GateAuth>(
        gate_a,
        gate_b,
        character,
        GateAuth {},
        expires_at_timestamp_ms,
        ctx,
    );
}

fun setup(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);
    test_helpers::register_server_address(ts);

    ts::next_tx(ts, governor());
    gate::init_for_testing(ts.ctx());

    // Configure max distance for our gate type
    ts::next_tx(ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(ts);
        let mut gate_config = ts::take_shared<GateConfig>(ts);
        gate::set_max_distance(&mut gate_config, &admin_acl, GATE_TYPE_ID, 1_000_000_000, ts.ctx());
        ts::return_shared(gate_config);
        ts::return_shared(admin_acl);
    };
}

fun create_character(ts: &mut ts::Scenario, user: address, item_id: u32): ID {
    ts::next_tx(ts, admin());
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = character::create_character(
        &mut registry,
        &admin_acl,
        item_id,
        tenant(),
        100,
        user,
        utf8(b"name"),
        ts.ctx(),
    );
    let character_id = object::id(&character);
    character.share_character(&admin_acl, ts.ctx());
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    character_id
}

fun create_network_node(ts: &mut ts::Scenario, character_id: ID): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_acl,
        NWN_ITEM_ID,
        NWN_TYPE_ID,
        test_helpers::get_verified_location_hash(),
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let nwn_id = object::id(&nwn);
    nwn.share_network_node(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    nwn_id
}

fun create_gate(ts: &mut ts::Scenario, character_id: ID, nwn_id: ID, item_id: u64): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let gate_obj = gate::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        item_id,
        GATE_TYPE_ID,
        test_helpers::get_verified_location_hash(),
        ts.ctx(),
    );
    let gate_id = object::id(&gate_obj);
    gate_obj.share_gate(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(nwn);
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    gate_id
}

fun bring_network_node_online(ts: &mut ts::Scenario, character_id: ID, nwn_id: ID) {
    ts::next_tx(ts, user_a());
    {
        let clock = clock::create_for_testing(ts.ctx());
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let mut character = ts::take_shared_by_id<Character>(ts, character_id);
        let nwn_owner_cap_id = nwn.owner_cap_id();
        let nwn_ticket = ts::receiving_ticket_by_id<OwnerCap<NetworkNode>>(nwn_owner_cap_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<NetworkNode>(nwn_ticket, ts.ctx());
        nwn.deposit_fuel_test(
            &owner_cap,
            FUEL_TYPE_ID,
            FUEL_VOLUME,
            10,
            &clock,
        );
        nwn.online(&owner_cap, &clock);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(nwn);
        ts::return_shared(character);
        clock.destroy_for_testing();
    };
}

fun link_and_online_gates(
    ts: &mut ts::Scenario,
    character_id: ID,
    nwn_id: ID,
    gate_a_id: ID,
    gate_b_id: ID,
) {
    ts::next_tx(ts, user_a());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(ts);
        let gate_config = ts::take_shared<GateConfig>(ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(ts);
        let mut gate_a = ts::take_shared_by_id<Gate>(ts, gate_a_id);
        let mut gate_b = ts::take_shared_by_id<Gate>(ts, gate_b_id);
        let mut character = ts::take_shared_by_id<Character>(ts, character_id);

        let owner_cap_a_id = gate_a.owner_cap_id();
        let owner_cap_b_id = gate_b.owner_cap_id();
        let gate_a_ticket = ts::receiving_ticket_by_id<OwnerCap<Gate>>(owner_cap_a_id);
        let gate_b_ticket = ts::receiving_ticket_by_id<OwnerCap<Gate>>(owner_cap_b_id);
        let (owner_cap_a, receipt_a) = character.borrow_owner_cap<Gate>(gate_a_ticket, ts.ctx());
        let (owner_cap_b, receipt_b) = character.borrow_owner_cap<Gate>(gate_b_ticket, ts.ctx());

        let proof = test_helpers::construct_location_proof(
            test_helpers::get_verified_location_hash(),
        );
        let proof_bytes = bcs::to_bytes(&proof);
        let clock = clock::create_for_testing(ts.ctx());
        gate_a.link_gates(
            &mut gate_b,
            &character,
            &gate_config,
            &server_registry,
            &owner_cap_a,
            &owner_cap_b,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        gate_a.online(&mut nwn, &energy_config, &owner_cap_a);
        gate_b.online(&mut nwn, &energy_config, &owner_cap_b);

        clock.destroy_for_testing();
        character.return_owner_cap(owner_cap_a, receipt_a);
        character.return_owner_cap(owner_cap_b, receipt_b);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_shared(gate_config);
        ts::return_shared(server_registry);
    };
}

fun authorize_gate_extension(ts: &mut ts::Scenario, character_id: ID, gate_id: ID) {
    ts::next_tx(ts, user_a());
    {
        let mut gate_obj = ts::take_shared_by_id<Gate>(ts, gate_id);
        let mut character = ts::take_shared_by_id<Character>(ts, character_id);
        let owner_cap_id = gate_obj.owner_cap_id();
        let gate_ticket = ts::receiving_ticket_by_id<OwnerCap<Gate>>(owner_cap_id);
        let (owner_cap, receipt) = character.borrow_owner_cap<Gate>(gate_ticket, ts.ctx());
        gate_obj.authorize_extension<GateAuth>(&owner_cap);
        character.return_owner_cap(owner_cap, receipt);
        ts::return_shared(character);
        ts::return_shared(gate_obj);
    };
}

fun distance_proof_bytes(distance: u64, player: address, target_hash: vector<u8>): vector<u8> {
    // Distance is checked BEFORE signature verification in `location::verify_distance`,
    // so a dummy signature is fine to deterministically hit `EOutOfRange`.
    let proof = world::location::create_location_proof(
        server_admin(),
        player,
        object::id_from_bytes(x"0000000000000000000000000000000000000000000000000000000000000001"),
        target_hash,
        object::id_from_bytes(x"0000000000000000000000000000000000000000000000000000000000000002"),
        target_hash,
        distance,
        b"",
        0,
        x"00",
    );
    bcs::to_bytes(&proof)
}

#[test]
fun default_jump_no_extension() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 101);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);

    ts::next_tx(&mut ts, user_a());
    {
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        gate_a.test_jump(&gate_b, &character);
        // Should also work from the other side
        gate_b.test_jump(&gate_a, &character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(character);
    };
    ts::end(ts);
}

#[test]
fun test_jump_with_permit_succeeds() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 103);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);
    authorize_gate_extension(&mut ts, character_id, gate_a_id);
    authorize_gate_extension(&mut ts, character_id, gate_b_id);

    ts::next_tx(&mut ts, user_a());
    let clock = clock::create_for_testing(ts.ctx());
    let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
    let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
    let character = ts::take_shared_by_id<Character>(&ts, character_id);

    ts::next_tx(&mut ts, user_a());
    {
        let expires_at_timestamp_ms = clock.timestamp_ms() + 10_000;
        claim_ticket(&gate_a, &gate_b, &character, expires_at_timestamp_ms, ts.ctx());
    };

    // Jump A -> B (consume one ticket)
    ts::next_tx(&mut ts, user_a());
    {
        let permit = ts::take_from_sender<JumpPermit>(&ts);
        gate::test_jump_with_permit(&gate_a, &gate_b, &character, permit, &clock);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let expires_at_timestamp_ms = clock.timestamp_ms() + 10_000;
        claim_ticket(&gate_b, &gate_a, &character, expires_at_timestamp_ms, ts.ctx());
    };

    // Jump B -> A (consume the second ticket)
    ts::next_tx(&mut ts, user_a());
    {
        let permit = ts::take_from_sender<JumpPermit>(&ts);
        gate::test_jump_with_permit(&gate_b, &gate_a, &character, permit, &clock);
    };
    ts::return_shared(character);
    ts::return_shared(gate_a);
    ts::return_shared(gate_b);
    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
fun unanchor_orphan_gate() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 101);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let orphaned_assemblies = nwn.unanchor(&admin_acl, ts.ctx());
        let mut gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let mut gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let updated_orphaned_assemblies = gate_a.offline_orphaned_gate(
            orphaned_assemblies,
            &mut nwn,
            &energy_config,
        );
        let updated_orphaned_assemblies = gate_b.offline_orphaned_gate(
            updated_orphaned_assemblies,
            &mut nwn,
            &energy_config,
        );
        nwn.destroy_network_node(updated_orphaned_assemblies, &admin_acl, ts.ctx());
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(energy_config);
        ts::return_shared(admin_acl);
    };
    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        gate_a.unanchor_orphan(&admin_acl, ts.ctx());
        gate_b.unanchor_orphan(&admin_acl, ts.ctx());
        ts::return_shared(admin_acl);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::EExtensionNotAuthorized)]
fun default_jump_fails_when_extension_configured() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 102);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);
    authorize_gate_extension(&mut ts, character_id, gate_a_id);
    authorize_gate_extension(&mut ts, character_id, gate_b_id);

    ts::next_tx(&mut ts, user_a());
    {
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        gate_a.test_jump(&gate_b, &character);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::EExtensionNotAuthorized)]
fun issue_jump_permit_fails_without_extension() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 200);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);

    ts::next_tx(&mut ts, user_a());
    {
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        // No authorize_extension call here, should abort
        claim_ticket(&gate_a, &gate_b, &character, 123, ts.ctx());
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::EExtensionNotAuthorized)]
fun issue_jump_permit_fails_wrong_auth() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 201);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);
    authorize_gate_extension(&mut ts, character_id, gate_a_id);

    ts::next_tx(&mut ts, user_a());
    {
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        gate_a.issue_jump_permit<WrongGateAuth>(
            &gate_b,
            &character,
            WrongGateAuth {},
            123,
            ts.ctx(),
        );
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
    };
    ts::end(ts);
}

#[test]
#[expected_failure]
fun test_jump_with_permit_consumes_permit() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 105);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);
    authorize_gate_extension(&mut ts, character_id, gate_a_id);

    ts::next_tx(&mut ts, user_a());
    let clock = clock::create_for_testing(ts.ctx());
    let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
    let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
    let character = ts::take_shared_by_id<Character>(&ts, character_id);

    ts::next_tx(&mut ts, user_a());
    {
        let expires_at_timestamp_ms = clock.timestamp_ms() + 10_000;
        claim_ticket(
            &gate_a,
            &gate_b,
            &character,
            expires_at_timestamp_ms,
            ts.ctx(),
        );
    };
    ts::next_tx(&mut ts, user_a());
    {
        let permit = ts::take_from_sender<JumpPermit>(&ts);

        // First jump succeeds
        gate::test_jump_with_permit(&gate_a, &gate_b, &character, permit, &clock);

        // Permit is deleted, taking another should fail.
        let unexpected = ts::take_from_sender<JumpPermit>(&ts);
        ts::return_to_sender(&ts, unexpected);
    };

    ts::return_shared(character);
    ts::return_shared(gate_a);
    ts::return_shared(gate_b);
    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::EJumpPermitExpired)]
fun test_jump_with_permit_fails_expired_permit() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 106);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);
    authorize_gate_extension(&mut ts, character_id, gate_a_id);
    authorize_gate_extension(&mut ts, character_id, gate_b_id);

    ts::next_tx(&mut ts, user_a());
    let clock = clock::create_for_testing(ts.ctx());
    let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
    let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
    let character = ts::take_shared_by_id<Character>(&ts, character_id);

    ts::next_tx(&mut ts, user_a());
    {
        // Issue already-expired ticket
        claim_ticket(&gate_a, &gate_b, &character, 0, ts.ctx());
    };
    ts::next_tx(&mut ts, user_a());
    {
        let permit = ts::take_from_sender<JumpPermit>(&ts);
        gate::test_jump_with_permit(&gate_a, &gate_b, &character, permit, &clock);
    };
    ts::return_shared(character);
    ts::return_shared(gate_a);
    ts::return_shared(gate_b);
    clock.destroy_for_testing();
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::EGateNotAuthorized)]
fun authorize_extension_fails_unauthorized_owner_cap() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_a_id = create_character(&mut ts, user_a(), 601);
    let character_b_id = create_character(&mut ts, user_b(), 602);
    let nwn_id = create_network_node(&mut ts, character_a_id);
    let gate_a_id = create_gate(&mut ts, character_a_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_b_id, nwn_id, GATE_ITEM_ID_2);

    ts::next_tx(&mut ts, user_b());
    {
        let mut gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let mut character_b = ts::take_shared_by_id<Character>(&ts, character_b_id);
        let (owner_cap_b, receipt_b) = character_b.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_b.owner_cap_id()),
            ts.ctx(),
        );
        gate_a.authorize_extension<GateAuth>(&owner_cap_b);
        character_b.return_owner_cap(owner_cap_b, receipt_b);
        ts::return_shared(character_b);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::ENotOnline)]
fun jump_fails_when_gate_is_offline() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 603);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    // Link, but don't online
    ts::next_tx(&mut ts, user_a());
    {
        let gate_config = ts::take_shared<GateConfig>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let mut gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let mut gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap_a, receipt_a) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_a.owner_cap_id()),
            ts.ctx(),
        );
        let (owner_cap_b, receipt_b) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_b.owner_cap_id()),
            ts.ctx(),
        );
        let proof_bytes = bcs::to_bytes(
            &test_helpers::construct_location_proof(test_helpers::get_verified_location_hash()),
        );
        let clock = clock::create_for_testing(ts.ctx());
        gate_a.link_gates(
            &mut gate_b,
            &character,
            &gate_config,
            &server_registry,
            &owner_cap_a,
            &owner_cap_b,
            proof_bytes,
            &clock,
            ts.ctx(),
        );
        gate_a.test_jump(&gate_b, &character);

        character.return_owner_cap(owner_cap_a, receipt_a);
        character.return_owner_cap(owner_cap_b, receipt_b);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(gate_config);
        ts::return_shared(server_registry);
        clock.destroy_for_testing();
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::ENotOnline)]
fun jump_fails_after_gate_offlined() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 609);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);

    // Offline gate_a
    ts::next_tx(&mut ts, user_a());
    {
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let mut gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap_a, receipt_a) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_a.owner_cap_id()),
            ts.ctx(),
        );
        gate_a.offline(&mut nwn, &energy_config, &owner_cap_a);
        character.return_owner_cap(owner_cap_a, receipt_a);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    // Jump should now fail because source gate is offline
    ts::next_tx(&mut ts, user_a());
    {
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        gate_a.test_jump(&gate_b, &character);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::EGatesNotLinked)]
fun unlink_fails_when_gates_not_linked() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 604);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    ts::next_tx(&mut ts, user_a());
    {
        let mut gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let mut gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap_a, receipt_a) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_a.owner_cap_id()),
            ts.ctx(),
        );
        let (owner_cap_b, receipt_b) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_b.owner_cap_id()),
            ts.ctx(),
        );
        gate_a.unlink_gates(&mut gate_b, &owner_cap_a, &owner_cap_b);

        character.return_owner_cap(owner_cap_a, receipt_a);
        character.return_owner_cap(owner_cap_b, receipt_b);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
    };
    ts::end(ts);
}

#[test]
fun unlink_gates_by_admin_succeeds() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 611);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);

    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let mut gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let mut gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);

        gate::unlink_gates_by_admin(&mut gate_a, &mut gate_b, &admin_acl, ts.ctx());

        assert!(!gate::are_gates_linked(&gate_a, &gate_b), 0);
        let linked_a = gate_a.linked_gate_id();
        let linked_b = gate_b.linked_gate_id();
        assert!(option::is_none(&linked_a), 0);
        assert!(option::is_none(&linked_b), 0);

        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(admin_acl);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::EGatesAlreadyLinked)]
fun link_fails_when_gates_already_linked() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 610);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);

    // Attempt to link again
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_b_id, gate_a_id);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = location::EOutOfRange)]
fun link_fails_when_distance_exceeds_max() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 605);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    // Set max distance to 1 for our type
    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let mut gate_config = ts::take_shared<GateConfig>(&ts);
        gate::set_max_distance(&mut gate_config, &admin_acl, GATE_TYPE_ID, 1, ts.ctx());
        ts::return_shared(gate_config);
        ts::return_shared(admin_acl);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let gate_config = ts::take_shared<GateConfig>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let mut gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let mut gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap_a, receipt_a) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_a.owner_cap_id()),
            ts.ctx(),
        );
        let (owner_cap_b, receipt_b) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_b.owner_cap_id()),
            ts.ctx(),
        );
        let proof_bytes = distance_proof_bytes(
            2,
            user_a(),
            test_helpers::get_verified_location_hash(),
        );
        let clock = clock::create_for_testing(ts.ctx());
        gate_a.link_gates(
            &mut gate_b,
            &character,
            &gate_config,
            &server_registry,
            &owner_cap_a,
            &owner_cap_b,
            proof_bytes,
            &clock,
            ts.ctx(),
        );
        character.return_owner_cap(owner_cap_a, receipt_a);
        character.return_owner_cap(owner_cap_b, receipt_b);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(gate_config);
        ts::return_shared(server_registry);
        clock.destroy_for_testing();
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = gate::EInvalidJumpPermit)]
fun jump_fails_when_ticket_issued_for_user_a_used_by_user_b() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_a_id = create_character(&mut ts, user_a(), 606);
    let character_b_id = create_character(&mut ts, user_b(), 607);
    let nwn_id = create_network_node(&mut ts, character_a_id);
    let gate_a_id = create_gate(&mut ts, character_a_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_a_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_a_id, nwn_id);
    link_and_online_gates(&mut ts, character_a_id, nwn_id, gate_a_id, gate_b_id);
    authorize_gate_extension(&mut ts, character_a_id, gate_a_id);
    authorize_gate_extension(&mut ts, character_a_id, gate_b_id);

    // Issue ticket to user_a in one tx
    ts::next_tx(&mut ts, user_a());
    {
        let clock = clock::create_for_testing(ts.ctx());
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character_a = ts::take_shared_by_id<Character>(&ts, character_a_id);
        let expires_at_timestamp_ms = clock.timestamp_ms() + 10_000;
        claim_ticket(&gate_a, &gate_b, &character_a, expires_at_timestamp_ms, ts.ctx());
        ts::return_shared(character_a);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        clock.destroy_for_testing();
    };

    // Move ticket to user_b
    ts::next_tx(&mut ts, user_a());
    {
        let permit = ts::take_from_sender<JumpPermit>(&ts);
        transfer::public_transfer(permit, user_b());
    };

    // user_b attempts to use it with their own character, should fail EInvalidJumpPermit
    ts::next_tx(&mut ts, user_b());
    {
        let clock = clock::create_for_testing(ts.ctx());
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character_b = ts::take_shared_by_id<Character>(&ts, character_b_id);
        let permit = ts::take_from_sender<JumpPermit>(&ts);
        gate::test_jump_with_permit(&gate_a, &gate_b, &character_b, permit, &clock);
        ts::return_shared(character_b);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        clock.destroy_for_testing();
    };
    ts::end(ts);
}

#[test]
#[expected_failure]
fun cannot_jump_after_unanchor() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 608);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);

    // Jump before unanchor (should succeed)
    ts::next_tx(&mut ts, user_a());
    {
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        gate_a.test_jump(&gate_b, &character);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
    };

    // Unlink first (unanchor requires not linked)
    ts::next_tx(&mut ts, user_a());
    {
        let mut gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let mut gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap_a, receipt_a) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_a.owner_cap_id()),
            ts.ctx(),
        );
        let (owner_cap_b, receipt_b) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_b.owner_cap_id()),
            ts.ctx(),
        );
        gate_a.unlink_gates(&mut gate_b, &owner_cap_a, &owner_cap_b);
        character.return_owner_cap(owner_cap_a, receipt_a);
        character.return_owner_cap(owner_cap_b, receipt_b);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
    };

    // Unanchor gate_a
    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        gate_a.unanchor(&mut nwn, &energy_config, &admin_acl, ts.ctx());
        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_shared(admin_acl);
    };

    // Now jump cannot happen
    ts::next_tx(&mut ts, user_a());
    {
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let character = ts::take_shared_by_id<Character>(&ts, character_id);
        gate_a.test_jump(&gate_b, &character);
        ts::return_shared(character);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
    };
    ts::end(ts);
}

// unanchor fails when gate has energy source
#[test]
#[expected_failure(abort_code = gate::EGateHasEnergySource)]
fun unanchor_orphan_gate_fails_when_energy_source_set() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let character_id = create_character(&mut ts, user_a(), 101);
    let nwn_id = create_network_node(&mut ts, character_id);
    let gate_a_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_1);
    let gate_b_id = create_gate(&mut ts, character_id, nwn_id, GATE_ITEM_ID_2);

    bring_network_node_online(&mut ts, character_id, nwn_id);
    link_and_online_gates(&mut ts, character_id, nwn_id, gate_a_id, gate_b_id);

    // unlink the gates
    ts::next_tx(&mut ts, user_a());
    {
        let mut gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let mut gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        let mut character = ts::take_shared_by_id<Character>(&ts, character_id);
        let (owner_cap_a, receipt_a) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_a.owner_cap_id()),
            ts.ctx(),
        );
        let (owner_cap_b, receipt_b) = character.borrow_owner_cap<Gate>(
            ts::receiving_ticket_by_id<OwnerCap<Gate>>(gate_b.owner_cap_id()),
            ts.ctx(),
        );
        gate_a.unlink_gates(&mut gate_b, &owner_cap_a, &owner_cap_b);
        character.return_owner_cap(owner_cap_a, receipt_a);
        character.return_owner_cap(owner_cap_b, receipt_b);
        ts::return_shared(gate_a);
        ts::return_shared(gate_b);
        ts::return_shared(character);
    };
    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let gate_a = ts::take_shared_by_id<Gate>(&ts, gate_a_id);
        let gate_b = ts::take_shared_by_id<Gate>(&ts, gate_b_id);
        gate_a.unanchor_orphan(&admin_acl, ts.ctx());
        gate_b.unanchor_orphan(&admin_acl, ts.ctx());
        ts::return_shared(admin_acl);
    };
    ts::end(ts);
}
