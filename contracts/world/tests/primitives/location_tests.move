module world::location_tests;

use std::{bcs, unit_test::assert_eq};
use sui::{clock, test_scenario as ts};
use world::{
    authority::{AdminCap, ServerAddressRegistry},
    location::{Self, Location},
    test_helpers::{Self, governor, admin, server_admin, user_a, user_b}
};

// Location hash representing coordinates near Planet A in Solar System 1
const LOCATION_HASH_PLANET_A_SYSTEM_1: vector<u8> =
    x"16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049";

// Location hash representing coordinates near Planet B in Solar System 2
const LOCATION_HASH_PLANET_B_SYSTEM_2: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";

public struct Gate has key {
    id: UID,
    location: Location,
    max_distance: u64,
}

public struct Storage has key {
    id: UID,
    location: Location,
}

fun create_storage_unit(ts: &mut ts::Scenario, storage_unit_id: ID, location_hash: vector<u8>) {
    ts::next_tx(ts, server_admin());
    {
        let uid = object::new(ts.ctx());
        let storage_unit = Storage {
            id: uid,
            location: location::attach(storage_unit_id, location_hash),
        };
        transfer::share_object(storage_unit);
    };
}

#[test]
fun create_assembly_with_location() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let max_distance: u64 = 1000000000;
        let gate = Gate {
            id: uid,
            location: location::attach(
                assembly_id,
                LOCATION_HASH_PLANET_B_SYSTEM_2,
            ),
            max_distance,
        };
        transfer::share_object(gate);
    };
    ts::end(ts);
}

#[test]
fun update_assembly_location() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let max_distance: u64 = 1000000000;
        let gate = Gate {
            id: uid,
            location: location::attach(
                assembly_id,
                LOCATION_HASH_PLANET_B_SYSTEM_2,
            ),
            max_distance,
        };
        transfer::share_object(gate);
    };
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut gate = ts::take_shared<Gate>(&ts);
        let location_hash: vector<u8> =
            x"7a8f5b1e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
        location::update(&mut gate.location, &admin_cap, location_hash);

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
        let uid = object::new(ts.ctx());
        gate_id_1 = object::uid_to_inner(&uid);
        let location_hash: vector<u8> = LOCATION_HASH_PLANET_B_SYSTEM_2;
        let max_distance: u64 = 1000000000;
        let gate_1 = Gate {
            id: uid,
            location: location::attach(gate_id_1, location_hash),
            max_distance,
        };
        transfer::share_object(gate_1);
    };

    // Create assembly 2
    ts::next_tx(&mut ts, admin());
    {
        let uid = object::new(ts.ctx());
        gate_id_2 = object::uid_to_inner(&uid);
        let max_distance: u64 = 5000000000;
        let gate_2 = Gate {
            id: uid,
            location: location::attach(
                gate_id_2,
                LOCATION_HASH_PLANET_B_SYSTEM_2,
            ),
            max_distance,
        };
        transfer::share_object(gate_2);
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
    create_storage_unit(
        &mut ts,
        test_helpers::get_storage_unit_id(),
        LOCATION_HASH_PLANET_A_SYSTEM_1,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let proof = test_helpers::construct_location_proof(LOCATION_HASH_PLANET_A_SYSTEM_1);

        location::verify_proximity_without_deadline(
            &server_registry,
            &storage_unit.location,
            proof,
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
    create_storage_unit(
        &mut ts,
        test_helpers::get_storage_unit_id(),
        LOCATION_HASH_PLANET_A_SYSTEM_1,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let proof = test_helpers::construct_location_proof(LOCATION_HASH_PLANET_A_SYSTEM_1);

        // Serialize the proof to bytes
        let proof_bytes = bcs::to_bytes(&proof);

        // Verify using the bytes version
        location::verify_proximity_proof_from_bytes_without_deadline(
            &server_registry,
            &storage_unit.location,
            proof_bytes,
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
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);

        // Invalid Hash
        let location_hash: vector<u8> = x"7a8f3b2e";

        let gate = Gate {
            id: uid,
            location: location::attach(assembly_id, location_hash),
            max_distance: 1000,
        };

        transfer::share_object(gate);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = location::EUnverifiedSender)]
fun verify_proximity_with_signature_proof_invalid_sender() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    create_storage_unit(
        &mut ts,
        test_helpers::get_storage_unit_id(),
        LOCATION_HASH_PLANET_A_SYSTEM_1,
    );

    // Call with server_admin() but the proof is for user_a(), so it should fail
    ts::next_tx(&mut ts, user_b());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let proof = test_helpers::construct_location_proof(LOCATION_HASH_PLANET_A_SYSTEM_1);

        location::verify_proximity_without_deadline(
            &server_registry,
            &storage_unit.location,
            proof,
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
    create_storage_unit(
        &mut ts,
        test_helpers::get_storage_unit_id(),
        LOCATION_HASH_PLANET_A_SYSTEM_1,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);

        // Using a different location hash (Planet B) than the storage unit (Planet A) to error
        let proof = test_helpers::construct_location_proof(LOCATION_HASH_PLANET_B_SYSTEM_2);

        location::verify_proximity_without_deadline(
            &server_registry,
            &storage_unit.location,
            proof,
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
    // Only server_admin() address is registered as an authorized server
    test_helpers::register_server_address(&mut ts);
    create_storage_unit(
        &mut ts,
        test_helpers::get_storage_unit_id(),
        LOCATION_HASH_PLANET_A_SYSTEM_1,
    );

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
        let deadline_ms: u64 = 1763408644339;
        // The proof claims to be from admin(), but only server_admin() is registered
        // as an authorized server, so this should fail with EUnauthorizedServer
        let proof = location::create_location_proof(
            admin(), // UNAUTHORIZED - not in server registry
            server_admin(), // to address (player)
            character_id,
            LOCATION_HASH_PLANET_A_SYSTEM_1,
            test_helpers::get_storage_unit_id(),
            LOCATION_HASH_PLANET_A_SYSTEM_1,
            0u64,
            data,
            deadline_ms,
            signature,
        );

        location::verify_proximity_without_deadline(
            &server_registry,
            &storage_unit.location,
            proof,
            ts.ctx(),
        );

        ts::return_shared(server_registry);
        ts::return_shared(storage_unit);
    };

    ts::end(ts);
}

// The test fails due to deadline
#[test]
#[expected_failure(abort_code = location::EDeadlineExpired)]
fun verify_proximity_proof_with_bytes_fail_by_deadline() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    test_helpers::register_server_address(&mut ts);
    create_storage_unit(
        &mut ts,
        test_helpers::get_storage_unit_id(),
        LOCATION_HASH_PLANET_A_SYSTEM_1,
    );

    ts::next_tx(&mut ts, user_a());
    {
        let storage_unit = ts::take_shared<Storage>(&ts);
        let server_registry = ts::take_shared<ServerAddressRegistry>(&ts);
        let mut clock = clock::create_for_testing(ts.ctx());

        // This deadline matches the one in the signature
        let deadline_ms: u64 = 1763408644339u64;

        let current_time = deadline_ms + 5; // some millisecond after deadline
        clock.set_for_testing(current_time);

        let character_id = object::id_from_bytes(
            x"0000000000000000000000000000000000000000000000000000000000000002",
        );
        let data = x"";
        let signature =
            x"0026ce00ad44629213f249ec3ee833aaf28bc115d3b781ca0a146a6e22a4016205f992d07c62f8d067d0baecb397bcc5a692a3bae5ff2e33eb6b42fdb94db6f50ba94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";

        let proof = location::create_location_proof(
            server_admin(),
            user_a(), // player address
            character_id,
            LOCATION_HASH_PLANET_A_SYSTEM_1,
            test_helpers::get_storage_unit_id(),
            LOCATION_HASH_PLANET_A_SYSTEM_1,
            0u64,
            data,
            deadline_ms,
            signature,
        );

        // Serialize the proof to bytes
        let proof_bytes = bcs::to_bytes(&proof);

        // Verify using the bytes version
        location::verify_proximity_proof_from_bytes(
            &server_registry,
            &storage_unit.location,
            proof_bytes,
            &clock,
            ts.ctx(),
        );

        clock.destroy_for_testing();
        ts::return_shared(storage_unit);
        ts::return_shared(server_registry);
    };

    ts::end(ts);
}
