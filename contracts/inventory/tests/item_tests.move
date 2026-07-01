#[test_only]
module inventory::item_tests;

use core::entity_key;
use inventory::item;
use std::string;
use sui::test_scenario as ts;

const FUEL: u64 = 100;
const VOL: u64 = 10;

fun tenant(): string::String { string::utf8(b"test") }

fun fuel_key(): entity_key::EntityKey { entity_key::new(FUEL, tenant()) }

#[test]
fun new_records_fields() {
    let mut scenario = ts::begin(@0xA);
    let fuel = item::new(fuel_key(), 50, VOL, scenario.ctx());
    assert!(fuel.type_id() == FUEL);
    assert!(fuel.quantity() == 50);
    assert!(fuel.volume() == VOL);
    item::destroy(fuel, fuel_key());
    scenario.end();
}

#[test]
fun bag_deposit_merges_by_type() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    bag.deposit(item::new(key, 30, VOL, scenario.ctx()), key);
    bag.deposit(item::new(key, 20, VOL, scenario.ctx()), key);
    assert!(bag.balance(FUEL) == 50);

    let out = bag.withdraw(key, 15, VOL, scenario.ctx());
    assert!(out.quantity() == 15);
    assert!(out.volume() == VOL);
    assert!(bag.balance(FUEL) == 35);

    item::destroy(out, key);
    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun withdraw_over_balance_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    bag.deposit(item::new(key, 10, VOL, scenario.ctx()), key);
    let _out = bag.withdraw(key, 11, VOL, scenario.ctx());

    abort
}

#[test]
fun split_and_merge() {
    let mut scenario = ts::begin(@0xA);
    let key = fuel_key();
    let mut a = item::new(key, 100, VOL, scenario.ctx());
    let b = a.split(40, scenario.ctx());
    assert!(a.quantity() == 60);
    assert!(b.quantity() == 40);
    assert!(b.volume() == VOL);

    a.merge(b);
    assert!(a.quantity() == 100);

    item::destroy(a, key);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EWrongType)]
fun merge_wrong_type_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut a = item::new(fuel_key(), 10, VOL, scenario.ctx());
    let b = item::new(entity_key::new(FUEL + 1, tenant()), 10, VOL, scenario.ctx());
    a.merge(b);

    abort
}
