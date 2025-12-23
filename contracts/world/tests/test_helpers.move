#[test_only]
module world::test_helpers;

use std::string::String;
use sui::test_scenario as ts;
use world::{
    access::{Self, AdminCap, ServerAddressRegistry, AdminACL},
    assembly,
    character,
    fuel::{Self, FuelConfig},
    in_game_id::{Self, TenantItemId},
    location::{Self, LocationProof},
    world::{Self, GovernorCap}
};

const TEST: vector<u8> = b"TEST";

// Test fuel types and efficiencies
const FUEL_TYPE_1: u64 = 1;
const FUEL_TYPE_2: u64 = 2;
const FUEL_TYPE_3: u64 = 3;
const FUEL_EFFICIENCY_1: u64 = 100;
const FUEL_EFFICIENCY_2: u64 = 90;
const FUEL_EFFICIENCY_3: u64 = 75;

public struct TestObject has key {
    id: UID,
}

public fun tenant(): String {
    TEST.to_string()
}

public fun in_game_id(item_id: u64): TenantItemId {
    in_game_id::create_key(item_id, tenant())
}

public fun governor(): address { @0xA }

public fun admin(): address { @0xB }

public fun user_a(): address { @0x202d7d52ab5f8e8824e3e8066c0b7458f84e326c5d77b30254c69d807586a7b0 }

public fun user_b(): address { @0xD }

public fun user_a_character_id(): ID {
    object::id_from_bytes(x"0000000000000000000000000000000000000000000000000000000000000001")
}

public fun user_b_character_id(): ID {
    object::id_from_bytes(
        x"0000000000000000000000000000000000000000000000000000000000000002",
    )
}

public fun server_admin(): address {
    @0x93d3209c7f138aded41dcb008d066ae872ed558bd8dcb562da47d4ef78295333
}

public fun get_verified_location_hash(): vector<u8> {
    x"16217de8ec7330ec3eac32831df5c9cd9b21a255756a5fd5762dd7f49f6cc049"
}

public fun fuel_type_1(): u64 { FUEL_TYPE_1 }

public fun fuel_type_2(): u64 { FUEL_TYPE_2 }

public fun fuel_type_3(): u64 { FUEL_TYPE_3 }

public fun fuel_efficiency_1(): u64 { FUEL_EFFICIENCY_1 }

public fun fuel_efficiency_2(): u64 { FUEL_EFFICIENCY_2 }

public fun fuel_efficiency_3(): u64 { FUEL_EFFICIENCY_3 }

/// Initialize world and create admin cap for ADMIN
public fun setup_world(ts: &mut ts::Scenario) {
    ts::next_tx(ts, governor());
    {
        world::init_for_testing(ts.ctx());
        access::init_for_testing(ts.ctx());
        character::init_for_testing(ts::ctx(ts));
        assembly::init_for_testing(ts.ctx());
        fuel::init_for_testing(ts.ctx());
    };

    ts::next_tx(ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(ts);
        let mut admin_acl = ts::take_shared<AdminACL>(ts);
        access::create_admin_cap(&gov_cap, admin(), ts.ctx());
        access::add_sponsor_to_acl(&mut admin_acl, &gov_cap, admin()); // here admin and sponsor is the same
        ts::return_to_sender(ts, gov_cap);
        ts::return_shared(admin_acl);
    };
}

/// Create and transfer an owner cap for a specific object
public fun setup_owner_cap<T: key>(ts: &mut ts::Scenario, owner: address, object: &T) {
    ts::next_tx(ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        access::create_and_transfer_owner_cap<T>(
            &admin_cap,
            object::id(object),
            owner,
            ts.ctx(),
        );
        ts::return_to_sender(ts, admin_cap);
    };
}

public fun setup_owner_cap_for_user_a<T: key>(ts: &mut ts::Scenario, obj: &T) {
    setup_owner_cap<T>(ts, user_a(), obj);
}

public fun register_server_address(ts: &mut ts::Scenario) {
    ts::next_tx(ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(ts);
        let mut server_registry = ts::take_shared<ServerAddressRegistry>(ts);
        access::create_admin_cap(&gov_cap, server_admin(), ts.ctx());
        access::register_server_address(&mut server_registry, &gov_cap, server_admin());
        ts::return_to_sender(ts, gov_cap);
        ts::return_shared(server_registry);
    };
}

public fun get_storage_unit_id(): ID {
    let storage_unit_id_bytes = x"b78f2c84dbb71520c4698c4520bfca8da88ea8419b03d472561428cd1e3544e8";
    let storage_unit_id = object::id_from_bytes(storage_unit_id_bytes);
    storage_unit_id
}

// functions to get off-chain verified values for signaure proof
public fun construct_location_proof(location_hash: vector<u8>): LocationProof {
    let character_id = object::id_from_bytes(
        x"0000000000000000000000000000000000000000000000000000000000000002",
    );
    let data = x"";
    // Signature generated with user_a as the player address
    // To regenerate: run `npm run generate-test-signature` in examples/location/
    // Then update the signature hex below with the output from the script
    let signature =
        x"0085ee2824a8a3821be5d779ee912c6947acc36e8a6982024c994a3fdc88f450245e9a13ae23901b3c5b93acc34b0b314fe42a26742e16d3beac782360b65bff0ba94e21ea26cc336019c11a5e10c4b39160188dda0f6b4bfe198dd689db8f3df9";
    let deadline_ms: u64 = 1763408644339;
    let proof = location::create_location_proof(
        server_admin(), // authorized server
        user_a(), // player address
        character_id,
        location_hash,
        get_storage_unit_id(),
        location_hash,
        0u64,
        data,
        deadline_ms,
        signature,
    );
    proof
}

public fun create_test_object(ts: &mut ts::Scenario, owner: address): ID {
    ts::next_tx(ts, admin());
    let test_object_id;
    {
        let test_object = TestObject {
            id: object::new(ts.ctx()),
        };
        test_object_id = object::id(&test_object);
        transfer::share_object(test_object);
    };

    ts::next_tx(ts, admin());
    {
        let test_object = ts::take_shared_by_id<TestObject>(ts, test_object_id);
        setup_owner_cap(ts, owner, &test_object);
        ts::return_shared(test_object);
    };

    test_object_id
}

public fun configure_fuel(ts: &mut ts::Scenario) {
    ts::next_tx(ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let mut fuel_config = ts::take_shared<FuelConfig>(ts);

        fuel::set_fuel_efficiency(&mut fuel_config, &admin_cap, FUEL_TYPE_1, FUEL_EFFICIENCY_1);
        fuel::set_fuel_efficiency(&mut fuel_config, &admin_cap, FUEL_TYPE_2, FUEL_EFFICIENCY_2);
        fuel::set_fuel_efficiency(&mut fuel_config, &admin_cap, FUEL_TYPE_3, FUEL_EFFICIENCY_3);

        ts::return_shared(fuel_config);
        ts::return_to_sender(ts, admin_cap);
    }
}
