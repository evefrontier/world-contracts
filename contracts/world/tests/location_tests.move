module world::location_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{authority::AdminCap, location::{Self, Location}, test_helpers::{Self, governor, admin}};

public struct Gate has key {
    id: UID,
    location: Location,
    max_distance: u64,
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

        assert_eq!(location::get_hash(&gate.location), location_hash);
        ts::return_shared(gate);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::end(ts);
}

#[test]
fun verify_proximity() {
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
        let proof: vector<u8> = x"5a2f1b0e7c4d1a6f5e8b2d9c3f7a1e5b";
        location::verify_proximity(&gate_1.location, &gate_2.location, proof);
        ts::return_shared(gate_1);
        ts::return_shared(gate_2);
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
