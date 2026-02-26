#[test_only]
module assets::EVE_tests;

use assets::EVE::{Self, AdminCap, EveTreasury, EVE as EVEToken};
use std::unit_test::assert_eq;
use sui::{coin, test_scenario as ts};

const SCALE: u64 = 1_000_000_000;
const TOTAL_SUPPLY: u64 = 10_000_000_000;
const INITIAL_DEPLOYER_ALLOCATION: u64 = 10_000_000; // 10M tokens
const DEPLOYER_AMOUNT: u64 = INITIAL_DEPLOYER_ALLOCATION * SCALE;
const TREASURY_AMOUNT: u64 = (TOTAL_SUPPLY - INITIAL_DEPLOYER_ALLOCATION) * SCALE;

fun deployer(): address {
    @0x0
}

fun recipient(): address {
    @0x1
}

/// Init: deployer receives 10M EVE, EveTreasury (rest), AdminCap, MetadataCap, Receiving<Currency<EVE>>.
#[test]
fun test_init_deployer_receives_allocations() {
    let mut ts = ts::begin(deployer());

    ts::next_tx(&mut ts, deployer());
    {
        EVE::init_for_testing(ts.ctx());
    };

    ts::next_tx(&mut ts, deployer());
    {
        let deployer_coins = ts::take_from_sender<coin::Coin<EVEToken>>(&ts);
        assert_eq!(coin::value(&deployer_coins), DEPLOYER_AMOUNT);
        ts::return_to_sender(&ts, deployer_coins);

        let treasury = ts::take_from_sender<EveTreasury>(&ts);
        assert_eq!(EVE::treasury_balance(&treasury), TREASURY_AMOUNT);
        ts::return_to_sender(&ts, treasury);

        let admin = ts::take_from_sender<AdminCap>(&ts);
        ts::return_to_sender(&ts, admin);
    };

    ts::end(ts);
}

/// Admin can transfer EVE from treasury to a recipient.
#[test]
fun test_transfer_from_treasury() {
    let mut ts = ts::begin(deployer());

    ts::next_tx(&mut ts, deployer());
    {
        EVE::init_for_testing(ts.ctx());
    };

    let transfer_amount = 1_000_000 * SCALE; // 1M EVE

    ts::next_tx(&mut ts, deployer());
    {
        let coins = ts::take_from_sender<coin::Coin<EVEToken>>(&ts);
        ts::return_to_sender(&ts, coins);

        let mut treasury = ts::take_from_sender<EveTreasury>(&ts);
        assert_eq!(EVE::treasury_balance(&treasury), TREASURY_AMOUNT);
        let admin = ts::take_from_sender<AdminCap>(&ts);

        EVE::transfer_from_treasury(&mut treasury, &admin, transfer_amount, recipient(), ts.ctx());
        assert_eq!(EVE::treasury_balance(&treasury), TREASURY_AMOUNT - transfer_amount);

        ts::return_to_sender(&ts, treasury);
        ts::return_to_sender(&ts, admin);
    };

    ts::next_tx(&mut ts, recipient());
    {
        let received = ts::take_from_sender<coin::Coin<EVEToken>>(&ts);
        assert_eq!(coin::value(&received), transfer_amount);
        ts::return_to_sender(&ts, received);
    };

    ts::end(ts);
}

#[test]
fun test_deployer_can_transfer_coins_to_recipient() {
    let mut ts = ts::begin(deployer());

    ts::next_tx(&mut ts, deployer());
    {
        EVE::init_for_testing(ts.ctx());
    };

    let transfer_amount = 1_000 * SCALE; // 1k EVE

    ts::next_tx(&mut ts, deployer());
    {
        let mut coins = ts::take_from_sender<coin::Coin<EVEToken>>(&ts);
        let sent = coin::split(&mut coins, transfer_amount, ts.ctx());
        transfer::public_transfer(sent, recipient());
        ts::return_to_sender(&ts, coins);
    };

    ts::next_tx(&mut ts, recipient());
    {
        let received = ts::take_from_sender<coin::Coin<EVEToken>>(&ts);
        assert_eq!(coin::value(&received), transfer_amount);
        ts::return_to_sender(&ts, received);
    };

    ts::end(ts);
}

/// Non-admin (recipient) does not have AdminCap; take_from_sender<AdminCap> aborts.
#[test]
#[expected_failure]
fun test_non_admin_cannot_transfer_from_treasury() {
    let mut ts = ts::begin(deployer());

    ts::next_tx(&mut ts, deployer());
    {
        EVE::init_for_testing(ts.ctx());
    };

    ts::next_tx(&mut ts, recipient());
    {
        let cap = ts::take_from_sender<AdminCap>(&ts);
        ts::return_to_sender(&ts, cap);
    };

    ts::end(ts);
}

/// Non-admin does not have AdminCap; take_from_sender<AdminCap> aborts.
#[test]
#[expected_failure]
fun test_non_admin_cannot_burn_from_treasury() {
    let mut ts = ts::begin(deployer());

    ts::next_tx(&mut ts, deployer());
    {
        EVE::init_for_testing(ts.ctx());
    };

    ts::next_tx(&mut ts, recipient());
    {
        let cap = ts::take_from_sender<AdminCap>(&ts);
        ts::return_to_sender(&ts, cap);
    };

    ts::end(ts);
}
