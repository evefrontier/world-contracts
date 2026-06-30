#[test_only]
module inventory::item_tests;

use inventory::item;
use sui::test_scenario as ts;

const FUEL: u64 = 100;
const VOL: u64 = 10;

#[test]
fun new_records_fields() {
    let mut scenario = ts::begin(@0xA);
    let fuel = item::new(FUEL, 50, VOL, scenario.ctx());
    assert!(fuel.type_id() == FUEL);
    assert!(fuel.quantity() == 50);
    assert!(fuel.volume() == VOL);
    item::destroy(fuel);
    scenario.end();
}

#[test]
fun bag_deposit_merges_by_type() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());

    bag.deposit(item::new(FUEL, 30, VOL, scenario.ctx()));
    bag.deposit(item::new(FUEL, 20, VOL, scenario.ctx()));
    assert!(bag.balance(FUEL) == 50);

    let out = bag.withdraw(FUEL, 15, VOL, scenario.ctx());
    assert!(out.quantity() == 15);
    assert!(out.volume() == VOL);
    assert!(bag.balance(FUEL) == 35);

    item::destroy(out);
    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun withdraw_over_balance_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    bag.deposit(item::new(FUEL, 10, VOL, scenario.ctx()));
    let _out = bag.withdraw(FUEL, 11, VOL, scenario.ctx());

    abort
}

#[test]
fun split_and_merge() {
    let mut scenario = ts::begin(@0xA);
    let mut a = item::new(FUEL, 100, VOL, scenario.ctx());
    let b = a.split(40, scenario.ctx());
    assert!(a.quantity() == 60);
    assert!(b.quantity() == 40);
    assert!(b.volume() == VOL);

    a.merge(b);
    assert!(a.quantity() == 100);

    item::destroy(a);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EWrongType)]
fun merge_wrong_type_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut a = item::new(FUEL, 10, VOL, scenario.ctx());
    let b = item::new(FUEL + 1, 10, VOL, scenario.ctx());
    a.merge(b);

    abort
}
