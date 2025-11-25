module world::location_tests;

use std::{bcs, unit_test::assert_eq};
use sui::{clock, test_scenario as ts};
use world::{
    authority::{AdminCap, ServerAddressRegistry},
    location::{Self, Location},
    test_helpers::{Self, governor, admin, server_admin}
};

const LOCATION_HASH: vector<u8> =
    x"16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";

public struct Gate has key {
    id: UID,
    location: Location,
    max_distance: u64,
}

public struct Storage has key {
    id: UID,
    location: Location,
}

fun create_storage_unit(ts: &mut ts::Scenario, storage_unit_id: ID) {
    ts::next_tx(ts, server_admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let uid = object::new(ts.ctx());
        let storage_unit = Storage {
            id: uid,
            location: location::attach_location(&admin_cap, storage_unit_id, LOCATION_HASH),
        };
        transfer::share_object(storage_unit);
        ts::return_to_sender(ts, admin_cap);
    };
}

#[test]
fun create_assembly_with_location() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let location_hash: vector<u8> =
            x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
        let max_distance: u64 = 1000000000;
        let gate = Gate {
            id: uid,
            location: location::attach_location(&admin_cap, assembly_id, location_hash),
            max_distance,
        };
        transfer::share_object(gate);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

#[test]
fun update_assembly_location() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let location_hash: vector<u8> =
            x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
        let max_distance: u64 = 1000000000;
        let gate = Gate {
            id: uid,
            location: location::attach_location(&admin_cap, assembly_id, location_hash),
            max_distance,
        };
        transfer::share_object(gate);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut gate = ts::take_shared<Gate>(&ts);
        let location_hash: vector<u8> =
            x"7a8f5b1e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
        location::update_location(&mut gate.location, &admin_cap, location_hash);

        assert_eq!(location::hash(&gate.location), location_hash);
        ts::return_shared(gate);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

#[test]
fun verify_same_location() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let gate_id_1: ID;
    let gate_id_2: ID;

    // Create assembly 1
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let uid = object::new(ts.ctx());
        gate_id_1 = object::uid_to_inner(&uid);
        let location_hash: vector<u8> =
            x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
        let max_distance: u64 = 1000000000;
        let gate_1 = Gate {
            id: uid,
            location: location::attach_location(&admin_cap, gate_id_1, location_hash),
            max_distance,
        };
        transfer::share_object(gate_1);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Create assembly 2
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let uid = object::new(ts.ctx());
        gate_id_2 = object::uid_to_inner(&uid);
        let location_hash: vector<u8> =
            x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
        let max_distance: u64 = 5000000000;
        let gate_2 = Gate {
            id: uid,
            location: location::attach_location(&admin_cap, gate_id_2, location_hash),
            max_distance,
        };
        transfer::share_object(gate_2);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::next_tx(&mut ts, admin());
    {
        let gate_1 = ts::take_shared_by_id<Gate>(&ts, gate_id_1);
        let gate_2 = ts::take_shared_by_id<Gate>(&ts, gate_id_2);
        location::verify_same_location(
            gate_1.location.hash(),
            gate_2.location.hash(),
        );
        ts::return_shared(gate_1);
        ts::return_shared(gate_2);
    };
    ts::end(ts);
}

#[test]
fun verify_proximity_with_signature_proof() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    create_storage_unit(&mut ts, test_helpers::get_storage_unit_id());

    ts::next_tx(&mut ts, server_admin());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let proof = test_helpers::construct_location_proof(LOCATION_HASH);

        location::verify_location_proof_as_struct_without_deadline(
            &storage_unit.location,
            proof,
            &server_registry,
            ts.ctx(),
        );

        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
    };

    ts::end(ts);
}

#[test]
fun verify_proximity_proof_with_bytes() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    create_storage_unit(&mut ts, test_helpers::get_storage_unit_id());

    ts::next_tx(&mut ts, server_admin());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let proof = test_helpers::construct_location_proof(LOCATION_HASH);

        // Serialize the proof to bytes
        let proof_bytes = bcs::to_bytes(&proof);

        // Verify using the bytes version
        location::verify_location_proof_as_bytes_without_deadline(
            &storage_unit.location,
            proof_bytes,
            &server_registry,
            ts.ctx(),
        );

        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = location::EInvalidHashLength)]
fun attach_location_with_invalid_hash_length() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);

        // Invalid Hash
        let location_hash: vector<u8> = x"7a8f3b2e";

        let gate = Gate {
            id: uid,
            location: location::attach_location(&admin_cap, assembly_id, location_hash),
            max_distance: 1000,
        };

        transfer::share_object(gate);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = location::EUnverifiedSender)]
fun verify_proximity_with_signature_proof_invalid_sender() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    create_storage_unit(&mut ts, test_helpers::get_storage_unit_id());

    ts::next_tx(&mut ts, admin());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let proof = test_helpers::construct_location_proof(LOCATION_HASH);

        location::verify_location_proof_as_struct_without_deadline(
            &storage_unit.location,
            proof,
            &server_registry,
            ts.ctx(),
        );

        ts::return_shared(server_registry);
        ts::return_shared(storage_unit);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = location::EInvalidLocationHash)]
fun verify_proximity_with_signature_proof_invalid_location_hash() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    create_storage_unit(&mut ts, test_helpers::get_storage_unit_id());

    ts::next_tx(&mut ts, server_admin());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);

        let wrong_location_hash =
            x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
        let proof = test_helpers::construct_location_proof(wrong_location_hash);

        location::verify_location_proof_as_struct_without_deadline(
            &storage_unit.location,
            proof,
            &server_registry,
            ts.ctx(),
        );

        ts::return_shared(server_registry);
        ts::return_shared(storage_unit);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = location::EUnauthorizedServer)]
fun verify_proximity_with_signature_proof_invalid_from_address() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    create_storage_unit(&mut ts, test_helpers::get_storage_unit_id());

    ts::next_tx(&mut ts, server_admin());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let character_id = object::id_from_bytes(
            x"0000000000000000000000000000000000000000000000000000000000000002",
        );
        let data = x"";
        let signature =
            x"0026ce00ad44629213f249ec3ee833aaf28bc115d3b781ca0a146a6e22a4016205f992d07c62f8d067d0baecb397bcc5a692a3bae5ff2e33eb6b42fdb94db6f50ba94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";
        let timestamp_ms: u64 = 1763408644339;
        let proof = location::create_location_proof(
            admin(), // sending unauthorized admin
            server_admin(), // ideally this is the player
            character_id,
            LOCATION_HASH,
            test_helpers::get_storage_unit_id(),
            LOCATION_HASH,
            0u64,
            data,
            timestamp_ms,
            signature,
        );

        location::verify_location_proof_as_struct_without_deadline(
            &storage_unit.location,
            proof,
            &server_registry,
            ts.ctx(),
        );

        ts::return_shared(server_registry);
        ts::return_shared(storage_unit);
    };

    ts::end(ts);
}

// The test fails due to deadline
#[test]
#[expected_failure(abort_code = location::ESignatureVerificationFailed)]
fun verify_proximity_proof_with_bytes_fail_by_deadline() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    create_storage_unit(&mut ts, test_helpers::get_storage_unit_id());

    ts::next_tx(&mut ts, server_admin());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);

        // Create a proof with a future deadline
        let mut clock = clock::create_for_testing(ts.ctx());
        let current_time = 1000000u64; // 1 second in milliseconds
        clock.set_for_testing(current_time);

        let timestamp_ms: u64 = current_time + 1763408644339; // Far future deadline
        let character_id = object::id_from_bytes(
            x"0000000000000000000000000000000000000000000000000000000000000002",
        );
        let data = x"";
        let signature =
            x"0026ce00ad44629213f249ec3ee833aaf28bc115d3b781ca0a146a6e22a4016205f992d07c62f8d067d0baecb397bcc5a692a3bae5ff2e33eb6b42fdb94db6f50ba94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";

        let proof = location::create_location_proof(
            server_admin(),
            server_admin(), // player address
            character_id,
            LOCATION_HASH,
            test_helpers::get_storage_unit_id(),
            LOCATION_HASH,
            0u64,
            data,
            timestamp_ms,
            signature,
        );

        // Serialize the proof to bytes
        let proof_bytes = bcs::to_bytes(&proof);

        // Verify using the bytes version
        location::verify_location_proof_as_bytes(
            &storage_unit.location,
            proof_bytes,
            &server_registry,
            &clock,
            ts.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
    };

    ts::end(ts);
}
