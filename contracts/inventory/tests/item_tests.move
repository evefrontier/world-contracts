#[test_only]
module inventory::item_tests;

use core::entity_key;
use inventory::item;
use std::string;
use sui::test_scenario as ts;

const FUEL: u64 = 100;
const LENS: u64 = 101;
const VOL: u64 = 10;

fun tenant(): string::String { string::utf8(b"test") }

fun fuel_key(): entity_key::EntityKey { entity_key::new(FUEL, tenant()) }

fun lens_key(): entity_key::EntityKey { entity_key::new(LENS, tenant()) }

fun source(): ID { object::id_from_address(@0x5) }

fun withdraw_item(
    bag: &mut item::ItemBag,
    key: entity_key::EntityKey,
    quantity: u64,
    ctx: &mut TxContext,
): item::Item {
    item::mint(bag, key, quantity, VOL);
    item::withdraw(bag, key, quantity, source(), ctx)
}

/// Empty a bag the way teardown does; the drained balances are the caller's to
/// announce, and a test has nothing to say about them.
fun drop_bag(bag: item::ItemBag) {
    item::burn_all_and_destroy(bag);
}

#[test]
fun bag_mint_adds_balance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());

    item::mint(&mut bag, fuel_key(), 25, VOL);
    assert!(item::balance(&bag, FUEL) == 25);

    drop_bag(bag);
    scenario.end();
}

#[test]
fun burn_all_reports_every_balance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());

    item::mint(&mut bag, fuel_key(), 50, VOL);
    item::mint(&mut bag, lens_key(), 3, VOL + 1);
    assert!(item::balance(&bag, FUEL) == 50);

    // Drained in insertion order, each carrying what the caller needs to emit.
    let drained = item::burn_all_and_destroy(bag);
    assert!(drained.length() == 2);
    assert!(drained[0].type_id() == FUEL);
    assert!(drained[0].quantity() == 50);
    assert!(drained[0].volume() == VOL);
    assert!(drained[1].type_id() == LENS);
    assert!(drained[1].quantity() == 3);
    assert!(drained[1].volume() == VOL + 1);

    scenario.end();
}

#[test]
fun bag_deposit_merges_by_type() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());

    let item_a = withdraw_item(&mut bag, fuel_key(), 30, scenario.ctx());
    item::deposit(&mut bag, item_a);
    let item_b = withdraw_item(&mut bag, fuel_key(), 20, scenario.ctx());
    item::deposit(&mut bag, item_b);
    assert!(item::balance(&bag, FUEL) == 50);

    let out = item::withdraw(&mut bag, fuel_key(), 15, source(), scenario.ctx());
    assert!(out.quantity() == 15);
    assert!(out.volume() == VOL);
    assert!(item::balance(&bag, FUEL) == 35);

    item::destroy_for_testing(out);
    drop_bag(bag);
    scenario.end();
}

#[test]
fun withdraw_records_fields() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let fuel = withdraw_item(&mut bag, fuel_key(), 50, scenario.ctx());
    assert!(fuel.type_id() == FUEL);
    assert!(fuel.quantity() == 50);
    assert!(fuel.volume() == VOL);
    item::destroy_for_testing(fuel);
    drop_bag(bag);
    scenario.end();
}

#[test]
fun withdraw_mints_a_fresh_transit_id() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint(&mut bag, fuel_key(), 100, VOL);

    // The id `ItemWithdrawn` / `ItemDeposited` correlate on is per-withdrawal,
    // so two moves of the same type stay distinguishable.
    let a = item::withdraw(&mut bag, fuel_key(), 40, source(), scenario.ctx());
    let b = item::withdraw(&mut bag, fuel_key(), 40, source(), scenario.ctx());
    assert!(object::id(&a) != object::id(&b));

    item::deposit(&mut bag, a);
    item::deposit(&mut bag, b);
    assert!(item::balance(&bag, FUEL) == 100);

    drop_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun withdraw_over_balance_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint(&mut bag, fuel_key(), 10, VOL);
    let _out = item::withdraw(&mut bag, fuel_key(), 11, source(), scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = item::EZeroQuantity)]
fun mint_zero_quantity_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint(&mut bag, fuel_key(), 0, VOL);

    abort
}

#[test, expected_failure(abort_code = item::EVolumeMismatch)]
fun mint_mismatched_volume_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint(&mut bag, fuel_key(), 10, VOL);
    item::mint(&mut bag, fuel_key(), 10, VOL + 1);

    abort
}
