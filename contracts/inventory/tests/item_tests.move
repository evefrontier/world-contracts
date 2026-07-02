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

fun withdraw_item(
    bag: &mut item::ItemBag,
    key: entity_key::EntityKey,
    quantity: u64,
    ctx: &mut TxContext,
): item::Item {
    item::mint(bag, key, quantity);
    item::withdraw(bag, key, quantity, VOL, ctx)
}

#[test]
fun bag_mint_adds_balance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    item::mint(&mut bag, key, 25);
    assert!(item::balance(&bag, FUEL) == 25);

    item::destroy_bag(bag);
    scenario.end();
}

#[test]
fun burn_all_clears_bag() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    item::mint(&mut bag, key, 50);
    item::burn_all_and_destroy(bag, tenant());
    scenario.end();
}

#[test]
fun bag_deposit_merges_by_type() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    let item_a = withdraw_item(&mut bag, key, 30, scenario.ctx());
    item::deposit(&mut bag, item_a, key);
    let item_b = withdraw_item(&mut bag, key, 20, scenario.ctx());
    item::deposit(&mut bag, item_b, key);
    assert!(item::balance(&bag, FUEL) == 50);

    let out = item::withdraw(&mut bag, key, 15, VOL, scenario.ctx());
    assert!(out.quantity() == 15);
    assert!(out.volume() == VOL);
    assert!(item::balance(&bag, FUEL) == 35);

    item::destroy(out, key);
    item::destroy_bag(bag);
    scenario.end();
}

#[test]
fun withdraw_records_fields() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let fuel = withdraw_item(&mut bag, key, 50, scenario.ctx());
    assert!(fuel.type_id() == FUEL);
    assert!(fuel.quantity() == 50);
    assert!(fuel.volume() == VOL);
    item::destroy(fuel, key);
    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun withdraw_over_balance_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    item::mint(&mut bag, key, 10);
    let _out = item::withdraw(&mut bag, key, 11, VOL, scenario.ctx());

    abort
}

#[test]
fun split_and_merge() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut a = withdraw_item(&mut bag, key, 100, scenario.ctx());
    let b = item::split(&mut a, 40, scenario.ctx());
    assert!(a.quantity() == 60);
    assert!(b.quantity() == 40);
    assert!(b.volume() == VOL);

    item::merge(&mut a, b);
    assert!(a.quantity() == 100);

    item::destroy(a, key);
    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EWrongType)]
fun merge_wrong_type_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key_a = fuel_key();
    let key_b = entity_key::new(FUEL + 1, tenant());
    let mut a = withdraw_item(&mut bag, key_a, 10, scenario.ctx());
    let b = withdraw_item(&mut bag, key_b, 10, scenario.ctx());
    item::merge(&mut a, b);

    abort
}
