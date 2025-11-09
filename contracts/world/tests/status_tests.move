#[test_only]

module world::status_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    authority::{Self, OwnerCap, AdminCap},
    status::{Self, AssemblyStatus},
    world::{Self, GovernorCap}
};

const GOVERNOR: address = @0xA;
const ADMIN: address = @0xB;
const USER_A: address = @0xC;
const USER_B: address = @0xD;

public struct StorageUnit has key {
    id: UID,
    status: AssemblyStatus,
    max_capacity: u64,
}

// Helper Functions
fun setup_world(ts: &mut ts::Scenario) {
    ts::next_tx(ts, GOVERNOR);
    {
        world::init_for_testing(ts.ctx());
    };

    ts::next_tx(ts, GOVERNOR);
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(ts);
        authority::create_admin_cap(&gov_cap, ADMIN, ts.ctx());
        ts::return_to_sender(ts, gov_cap);
    };
}

// An assembly implementation using the status primitive
fun create_storage_unit(ts: &mut ts::Scenario) {
    ts::next_tx(ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let uid = object::new(ts.ctx());
        let assembly_id = object::uid_to_inner(&uid);
        let storage_unit = StorageUnit {
            id: uid,
            status: status::anchor(&admin_cap, assembly_id),
            max_capacity: 10000,
        };
        // share storage unit object
        transfer::share_object(storage_unit);
        ts::return_to_sender(ts, admin_cap);
    }
}

fun destroy_storage_unit(ts: &mut ts::Scenario) {
    ts::next_tx(ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let storage_unit = ts::take_shared<StorageUnit>(ts);
        let StorageUnit { id, status, max_capacity: _ } = storage_unit;

        status::unanchor(status, &admin_cap);
        object::delete(id);

        ts::return_to_sender(ts, admin_cap);
    }
}

// Create a owner cap to access a assembly
fun setup_owner_cap(assembly_id: ID, ts: &mut ts::Scenario) {
    ts::next_tx(ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let owner_cap = authority::create_owner_cap(&admin_cap, assembly_id, ts.ctx());
        authority::transfer_owner_cap(owner_cap, &admin_cap, USER_A);
        ts::return_to_sender(ts, admin_cap);
    }
}

#[test]
fun create_assembly() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, ADMIN);
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        assert_eq!(storage_unit.status.status_to_u8(), 0);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}

#[test]
fun online() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, ADMIN);
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        setup_owner_cap(object::id(&storage_unit), &mut ts);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, USER_A);
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        status::online(&mut storage_unit.status, &owner_cap);

        assert_eq!(storage_unit.status.status_to_u8(), 1);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

#[test]
fun offline() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, ADMIN);
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        setup_owner_cap(object::id(&storage_unit), &mut ts);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, USER_A);
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        status::online(&mut storage_unit.status, &owner_cap);
        status::offline(&mut storage_unit.status, &owner_cap);

        assert_eq!(storage_unit.status.status_to_u8(), 0);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

#[test]
fun unanchor_destroy() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, ADMIN);
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        assert_eq!(storage_unit.status.status_to_u8(), 0);
        ts::return_shared(storage_unit);
        destroy_storage_unit(&mut ts);
    };
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = status::EAssemblyInvalidStatus)]
fun offline_without_online_fail() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, ADMIN);
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        setup_owner_cap(object::id(&storage_unit), &mut ts);
        ts::return_shared(storage_unit);
    };

    ts::next_tx(&mut ts, USER_A);
    {
        let mut storage_unit = ts::take_shared<StorageUnit>(&ts);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        status::offline(&mut storage_unit.status, &owner_cap);

        assert_eq!(storage_unit.status.status_to_u8(), 0);
        ts::return_shared(storage_unit);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

// Create 2 assemblies, give ownerCap to 2nd assembly and try to access 1st
#[test]
#[expected_failure(abort_code = status::EAssemblyNotAuthorized)]
fun online_fail_by_unauthorised_owner() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);

    // First assembly
    create_storage_unit(&mut ts);
    let assembly_1_id: ID;

    ts::next_tx(&mut ts, ADMIN);
    {
        let storage_unit_1 = ts::take_shared<StorageUnit>(&ts);
        assembly_1_id = object::id(&storage_unit_1);

        // Create second assembly
        let uid = object::new(ts.ctx());
        let assembly_2_id = object::uid_to_inner(&uid);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let storage_unit_2 = StorageUnit {
            id: uid,
            status: status::anchor(&admin_cap, assembly_2_id),
            max_capacity: 10000,
        };
        transfer::share_object(storage_unit_2);

        // Give USER_B cap for assembly_2
        let owner_cap = authority::create_owner_cap(&admin_cap, assembly_2_id, ts.ctx());
        authority::transfer_owner_cap(owner_cap, &admin_cap, USER_B);

        ts::return_shared(storage_unit_1);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::next_tx(&mut ts, USER_B);
    {
        // let mut storage_unit_1 = ts::take_shared<StorageUnit>(&ts);
        let mut storage_unit_1 = ts::take_shared_by_id<StorageUnit>(&ts, assembly_1_id);
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);

        // use assembly_2's cap on assembly_1, Should fail
        status::online(&mut storage_unit_1.status, &owner_cap);

        ts::return_shared(storage_unit_1);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

// try to access status using id after unanchoring
#[test]
#[expected_failure]
fun get_assembly_status_after_unanchor_fails() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    create_storage_unit(&mut ts);

    ts::next_tx(&mut ts, ADMIN);
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        assert_eq!(storage_unit.status.status_to_u8(), 0);
        ts::return_shared(storage_unit);
        destroy_storage_unit(&mut ts);
    };
    ts::next_tx(&mut ts, ADMIN);
    {
        let storage_unit = ts::take_shared<StorageUnit>(&ts);
        assert_eq!(storage_unit.status.status_to_u8(), 0);
        ts::return_shared(storage_unit);
    };
    ts::end(ts);
}
