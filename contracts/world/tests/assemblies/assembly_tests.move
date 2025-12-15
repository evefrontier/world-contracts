#[test_only]
module world::assembly_tests;

use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    assembly::{Self, Assembly, AssemblyRegistry},
    authority::{AdminCap, OwnerCap},
    location,
    status,
    test_helpers::{Self, governor, admin, user_a, tenant, in_game_id}
};

const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const TYPE_ID: u64 = 1;
const ITEM_ID: u64 = 1001;
const VOLUME: u64 = 1000;
const STATUS_ONLINE: u8 = 1;
const STATUS_OFFLINE: u8 = 2;

// Helper to create assembly
fun create_assembly(ts: &mut ts::Scenario): ID {
    ts::next_tx(ts, admin());
    let mut assembly_registry = ts::take_shared<AssemblyRegistry>(ts);
    let admin_cap = ts::take_from_sender<AdminCap>(ts);

    let assembly = assembly::anchor(
        &mut assembly_registry,
        &admin_cap,
        user_a(),
        tenant(),
        ITEM_ID,
        TYPE_ID,
        VOLUME,
        LOCATION_HASH,
        ts.ctx(),
    );
    let id = object::id(&assembly);
    assembly::share_assembly(assembly, &admin_cap);

    ts::return_to_sender(ts, admin_cap);
    ts::return_shared(assembly_registry);
    id
}

#[test]
fun test_anchor_assembly() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    let assembly_id = create_assembly(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let assembly_registry = ts::take_shared<AssemblyRegistry>(&ts);
        assert!(assembly::assembly_exists(&assembly_registry, in_game_id(ITEM_ID)), 0);
        ts::return_shared(assembly_registry);
    };

    ts::next_tx(&mut ts, admin());
    {
        let assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let status = assembly::status(&assembly);
        assert_eq!(status::status_to_u8(status), STATUS_OFFLINE);

        let loc = assembly::location(&assembly);
        assert_eq!(location::hash(loc), LOCATION_HASH);

        ts::return_shared(assembly);
    };
    ts::end(ts);
}

#[test]
fun test_online_offline() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);
    let assembly_id = create_assembly(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let owner_cap = ts::take_from_sender<OwnerCap<Assembly>>(&ts);

        assembly::online(&mut assembly, &owner_cap);
        assert_eq!(status::status_to_u8(assembly::status(&assembly)), STATUS_ONLINE);

        ts::return_shared(assembly);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let mut assembly = ts::take_shared_by_id<Assembly>(&ts, assembly_id);
        let owner_cap = ts::take_from_sender<OwnerCap<Assembly>>(&ts);

        assembly::offline(&mut assembly, &owner_cap);
        assert_eq!(status::status_to_u8(assembly::status(&assembly)), STATUS_OFFLINE);

        ts::return_shared(assembly);
        ts::return_to_sender(&ts, owner_cap);
    };
    ts::end(ts);
}

#[test]
fun test_unanchor() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    let mut assembly_registry = ts::take_shared<AssemblyRegistry>(&ts);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let assembly = assembly::anchor(
        &mut assembly_registry,
        &admin_cap,
        user_a(),
        tenant(),
        ITEM_ID,
        TYPE_ID,
        VOLUME,
        LOCATION_HASH,
        ts.ctx(),
    );

    // Unanchor - consumes assembly
    assembly::unanchor(assembly, &admin_cap);

    // As per implementation, derived object is not reclaimed, so assembly_exists should be true
    // but object is gone.
    assert!(assembly::assembly_exists(&assembly_registry, in_game_id(ITEM_ID)), 0);

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(assembly_registry);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::EAssemblyAlreadyExists)]
fun test_anchor_duplicate_item_id() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    let mut assembly_registry = ts::take_shared<AssemblyRegistry>(&ts);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let assembly1 = assembly::anchor(
        &mut assembly_registry,
        &admin_cap,
        user_a(),
        tenant(),
        ITEM_ID,
        TYPE_ID,
        VOLUME,
        LOCATION_HASH,
        ts.ctx(),
    );
    assembly::share_assembly(assembly1, &admin_cap);

    // Second anchor with same ITEM_ID should fail
    let assembly2 = assembly::anchor(
        &mut assembly_registry,
        &admin_cap,
        user_a(),
        tenant(),
        ITEM_ID,
        TYPE_ID,
        VOLUME,
        LOCATION_HASH,
        ts.ctx(),
    );
    assembly::share_assembly(assembly2, &admin_cap);

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(assembly_registry);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::EAssemblyTypeIdEmpty)]
fun test_anchor_invalid_type_id() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    let mut assembly_registry = ts::take_shared<AssemblyRegistry>(&ts);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let assembly = assembly::anchor(
        &mut assembly_registry,
        &admin_cap,
        user_a(),
        tenant(),
        ITEM_ID,
        0, // Invalid Type ID
        VOLUME,
        LOCATION_HASH,
        ts.ctx(),
    );
    assembly::share_assembly(assembly, &admin_cap);

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(assembly_registry);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = assembly::EAssemblyItemIdEmpty)]
fun test_anchor_invalid_item_id() {
    let mut ts = ts::begin(governor());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    let mut assembly_registry = ts::take_shared<AssemblyRegistry>(&ts);
    let admin_cap = ts::take_from_sender<AdminCap>(&ts);

    let assembly = assembly::anchor(
        &mut assembly_registry,
        &admin_cap,
        user_a(),
        tenant(),
        0, // Invalid Item ID
        TYPE_ID,
        VOLUME,
        LOCATION_HASH,
        ts.ctx(),
    );
    assembly::share_assembly(assembly, &admin_cap);

    ts::return_to_sender(&ts, admin_cap);
    ts::return_shared(assembly_registry);
    ts::end(ts);
}
