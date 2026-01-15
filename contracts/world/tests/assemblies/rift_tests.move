#[test_only]

module world::rift_tests;

use std::unit_test::assert_eq;
use sui::{clock, test_scenario as ts};
use world::{
    access::AdminCap,
    rift::{Self, Rift},
    test_helpers,
    test_helpers::admin
};

const INITIAL_CRUDE_AMOUNT: u64 = 1000;
const REMOVE_AMOUNT: u64 = 100;
const LOCATION_HASH: vector<u8> = x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";

// Test rift IDs for testing
const CRUDE_LIFT_ID_1: address = @0x1;
const CRUDE_LIFT_ID_2: address = @0x2;

fun create_shared_rift(ts: &mut ts::Scenario, crude_amount: u64): ID {
    test_helpers::setup_world(ts);
    ts::next_tx(ts, admin());
    let rift_id = {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let rift_id = rift::create_and_share_test_rift(&admin_cap, crude_amount, LOCATION_HASH, ts.ctx());
        ts::return_to_sender(ts, admin_cap);
        rift_id
    };
    rift_id
}

fun destroy_shared_rift(ts: &mut ts::Scenario, rift_id: ID) {
    ts::next_tx(ts, admin());
    let rift = ts::take_shared_by_id<Rift>(ts, rift_id);
    rift::destroy_test_rift(rift);
}

// === Test Functions ===

// Test creating a rift
#[test]
fun test_create_rift() {
    let mut ts = ts::begin(admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        assert_eq!(rift.crude_amount(), INITIAL_CRUDE_AMOUNT);
        assert_eq!(rift.is_collapsed(), false);
        assert_eq!(rift.is_being_mined(), false);
        assert_eq!(rift.location_hash(), LOCATION_HASH);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);
    ts::end(ts);
}

// Test creating a rift with zero crude amount fails
#[test]
#[expected_failure(abort_code = rift::EInvalidCrudeAmount)]
fun test_create_rift_zero_crude_fails() {
    let mut ts = ts::begin(admin());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let rift = rift::create_test_rift(&admin_cap, 0, LOCATION_HASH, ts.ctx());
        rift::destroy_test_rift(rift);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

// Test starting and stopping mining
#[test]
fun test_start_stop_mining() {
    let mut ts = ts::begin(admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        // Start mining
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        assert_eq!(rift.can_start_mining(), true);
        rift.start_mining(object::id_from_address(CRUDE_LIFT_ID_1));
        assert_eq!(rift.is_being_mined(), true);
        let mining_id = *rift.mining_crude_lift_id().borrow();
        assert_eq!(mining_id, object::id_from_address(CRUDE_LIFT_ID_1));
        assert_eq!(rift.can_start_mining(), false);
        ts::return_shared(rift);
    };

    ts::next_tx(&mut ts, admin());
    {
        // Stop mining
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        rift.stop_mining(object::id_from_address(CRUDE_LIFT_ID_1));
        assert_eq!(rift.is_being_mined(), false);
        assert_eq!(rift.can_start_mining(), true);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    ts::end(ts);
}

// Test starting mining on already being mined rift fails
#[test]
#[expected_failure(abort_code = rift::ERiftAlreadyBeingMined)]
fun test_start_mining_already_mined_fails() {
    let mut ts = ts::begin(admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        // Start mining with first lift
        rift.start_mining(object::id_from_address(CRUDE_LIFT_ID_1));
        // Try to start mining with second lift - should fail
        rift.start_mining(object::id_from_address(CRUDE_LIFT_ID_2));
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    ts::end(ts);
}

// Test stopping mining on rift not being mined fails
#[test]
#[expected_failure(abort_code = rift::ERiftNotBeingMined)]
fun test_stop_mining_not_mined_fails() {
    let mut ts = ts::begin(admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        // Try to stop mining on rift that's not being mined
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        rift.stop_mining(object::id_from_address(CRUDE_LIFT_ID_1));
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    ts::end(ts);
}

// Test stopping mining with wrong crude lift ID fails
#[test]
#[expected_failure(abort_code = rift::ERiftNotBeingMined)]
fun test_stop_mining_wrong_lift_fails() {
    let mut ts = ts::begin(admin());

    ts::next_tx(&mut ts, admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        // Start mining with first lift
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        rift.start_mining(object::id_from_address(CRUDE_LIFT_ID_1));
        // Try to stop mining with different lift - should fail
        rift.stop_mining(object::id_from_address(CRUDE_LIFT_ID_2));
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    ts::end(ts);
}

// Test removing crude matter
#[test]
fun test_remove_crude() {
    let mut ts = ts::begin(admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        let removed = rift.remove_crude(REMOVE_AMOUNT);
        assert_eq!(removed, REMOVE_AMOUNT);
        assert_eq!(rift.crude_amount(), INITIAL_CRUDE_AMOUNT - REMOVE_AMOUNT);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    ts::end(ts);
}

// Test removing all crude matter
#[test]
fun test_remove_all_crude() {
    let mut ts = ts::begin(admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        let removed = rift.remove_crude(INITIAL_CRUDE_AMOUNT);
        assert_eq!(removed, INITIAL_CRUDE_AMOUNT);
        assert_eq!(rift.crude_amount(), 0);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    ts::end(ts);
}

// Test removing more crude than available fails
#[test]
#[expected_failure(abort_code = rift::EInsufficientCrude)]
fun test_remove_insufficient_crude_fails() {
    let mut ts = ts::begin(admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        let _removed = rift.remove_crude(INITIAL_CRUDE_AMOUNT + 100);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    ts::end(ts);
}

// Test collapsing a rift
#[test]
fun test_collapse_rift() {
    let mut ts = ts::begin(admin());
    let clock = clock::create_for_testing(ts.ctx());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        assert_eq!(rift.is_collapsed(), false);
        let collapse_time = clock.timestamp_ms();
        rift.collapse_rift(&clock);
        assert_eq!(rift.is_collapsed(), true);
        let recorded_collapse = *rift.collapsed_at().borrow();
        assert_eq!(recorded_collapse, collapse_time);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);
    clock.destroy_for_testing();
    ts::end(ts);
}

// Test operations on collapsed rift fail
#[test]
#[expected_failure(abort_code = rift::ERiftCollapsed)]
fun test_operations_on_collapsed_rift_fail() {
    let mut ts = ts::begin(admin());
    let clock = clock::create_for_testing(ts.ctx());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        rift.collapse_rift(&clock);
        // These should all fail
        rift.start_mining(object::id_from_address(CRUDE_LIFT_ID_1));
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);
    clock.destroy_for_testing();
    ts::end(ts);
}

// Test removing crude from collapsed rift fails
#[test]
#[expected_failure(abort_code = rift::ERiftCollapsed)]
fun test_remove_crude_from_collapsed_rift_fails() {
    let mut ts = ts::begin(admin());
    let clock = clock::create_for_testing(ts.ctx());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        rift.collapse_rift(&clock);
        let _removed = rift.remove_crude(REMOVE_AMOUNT);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    clock.destroy_for_testing();
    ts::end(ts);
}

// Test collapsing already collapsed rift does nothing
#[test]
fun test_collapse_already_collapsed_rift() {
    let mut ts = ts::begin(admin());
    let mut clock = clock::create_for_testing(ts.ctx());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        let first_collapse_time = clock.timestamp_ms();
        rift.collapse_rift(&clock);
        let recorded_first = *rift.collapsed_at().borrow();
        assert_eq!(recorded_first, first_collapse_time);

        // Advance time and collapse again - should not change collapse time
        clock.increment_for_testing(1000);
        rift.collapse_rift(&clock);
        let recorded_second = *rift.collapsed_at().borrow();
        assert_eq!(recorded_second, first_collapse_time);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);
    clock.destroy_for_testing();
    ts::end(ts);
}

// Test view functions on fresh rift
#[test]
fun test_view_functions_fresh_rift() {
    let mut ts = ts::begin(admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        assert_eq!(rift.crude_amount(), INITIAL_CRUDE_AMOUNT);
        assert_eq!(rift.is_collapsed(), false);
        assert_eq!(rift.is_being_mined(), false);
        assert_eq!(rift.collapsed_at().is_none(), true);
        assert_eq!(rift.mining_crude_lift_id().is_none(), true);
        assert_eq!(rift.location_hash(), LOCATION_HASH);
        assert_eq!(rift.can_start_mining(), true);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    ts::end(ts);
}

// Test view functions on collapsed rift
#[test]
fun test_view_functions_collapsed_rift() {
    let mut ts = ts::begin(admin());
    let clock = clock::create_for_testing(ts.ctx());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        rift.collapse_rift(&clock);
        assert_eq!(rift.crude_amount(), INITIAL_CRUDE_AMOUNT);
        assert_eq!(rift.is_collapsed(), true);
        assert_eq!(rift.is_being_mined(), false);
        assert_eq!(rift.collapsed_at().is_some(), true);
        assert_eq!(rift.can_start_mining(), false);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    clock.destroy_for_testing();
    ts::end(ts);
}

// Test view functions on mining rift
#[test]
fun test_view_functions_mining_rift() {
    let mut ts = ts::begin(admin());
    let rift_id = create_shared_rift(&mut ts, INITIAL_CRUDE_AMOUNT);

    ts::next_tx(&mut ts, admin());
    {
        let mut rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        rift.start_mining(object::id_from_address(CRUDE_LIFT_ID_1));
        assert_eq!(rift.crude_amount(), INITIAL_CRUDE_AMOUNT);
        assert_eq!(rift.is_collapsed(), false);
        assert_eq!(rift.is_being_mined(), true);
        assert_eq!(rift.mining_crude_lift_id().is_some(), true);
        assert_eq!(rift.can_start_mining(), false);
        ts::return_shared(rift);
    };

    destroy_shared_rift(&mut ts, rift_id);

    ts::end(ts);
}
