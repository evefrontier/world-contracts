#[test_only]
module inventory::item_tests;

use core::entity_key;
use inventory::item;
use std::string;
use sui::{event, test_scenario as ts};

const FUEL: u64 = 100;
const BLUE_PRINT: u64 = 200;
const VOL: u64 = 10;
const BLUE_PRINT_VOL: u64 = 500;

fun tenant(): string::String { string::utf8(b"test") }

fun fuel_key(): entity_key::EntityKey { entity_key::new(FUEL, tenant()) }

fun blueprint_key(): entity_key::EntityKey { entity_key::new(BLUE_PRINT, tenant()) }

fun withdraw_item(
    bag: &mut item::ItemBag,
    key: entity_key::EntityKey,
    quantity: u64,
    ctx: &mut TxContext,
): item::Item {
    item::mint(bag, key, quantity, VOL);
    item::withdraw(bag, key, quantity, ctx)
}

#[test]
fun bag_mint_adds_balance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    item::mint(&mut bag, key, 25, VOL);
    assert!(item::balance(&bag, FUEL) == 25);

    item::destroy_bag(bag);
    scenario.end();
}

#[test]
fun burn_all_clears_bag() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    item::mint(&mut bag, key, 50, VOL);
    assert!(item::balance(&bag, FUEL) == 50);
    item::burn_all_and_destroy(bag, tenant());
    assert!(event::events_by_type<item::ItemBurned>().length() == 1);
    scenario.end();
}

#[test]
fun bag_deposit_merges_by_type() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    let item_a = withdraw_item(&mut bag, key, 30, scenario.ctx());
    item::deposit(&mut bag, item_a, tenant());
    let item_b = withdraw_item(&mut bag, key, 20, scenario.ctx());
    item::deposit(&mut bag, item_b, tenant());
    assert!(item::balance(&bag, FUEL) == 50);

    let out = item::withdraw(&mut bag, key, 15, scenario.ctx());
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
    item::mint(&mut bag, key, 10, VOL);
    let _out = item::withdraw(&mut bag, key, 11, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = item::EVolumeMismatch)]
fun mint_mismatched_volume_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    item::mint(&mut bag, key, 10, VOL);
    item::mint(&mut bag, key, 10, VOL + 1);

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

#[test]
fun mint_singleton_stores_instance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    assert!(item::has_singleton(&bag, 1));
    assert!(item::singleton_volume(&bag, 1) == BLUE_PRINT_VOL);
    assert!(!item::has_singleton(&bag, 2));

    item::burn_all_and_destroy(bag, tenant());
    scenario.end();
}

#[test, expected_failure(abort_code = item::EItemIdExists)]
fun mint_singleton_duplicate_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());

    abort
}

#[test]
fun singleton_distinct_from_same_type_non_singleton() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    // A non-singleton balance and a singleton of the same `type_id` (BLUE_PRINT) coexist
    // independently — minting one never touches the other.
    item::mint(&mut bag, blueprint_key(), 5, VOL);
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());

    assert!(item::balance(&bag, BLUE_PRINT) == 5);
    assert!(item::has_singleton(&bag, 1));

    item::burn(&mut bag, blueprint_key(), 5);
    assert!(item::balance(&bag, BLUE_PRINT) == 0);
    assert!(item::has_singleton(&bag, 1));

    item::burn_all_and_destroy(bag, tenant());
    scenario.end();
}

#[test]
fun withdraw_singleton_then_deposit_round_trip() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());

    let ship = item::withdraw_singleton(&mut bag, 1, blueprint_key());
    assert!(!item::has_singleton(&bag, 1));
    assert!(ship.item_id() == option::some(1));
    assert!(ship.quantity() == 1);
    assert!(ship.type_id() == BLUE_PRINT);
    assert!(ship.volume() == BLUE_PRINT_VOL);

    item::deposit(&mut bag, ship, tenant());
    assert!(item::has_singleton(&bag, 1));
    assert!(item::singleton_volume(&bag, 1) == BLUE_PRINT_VOL);

    item::burn_all_and_destroy(bag, tenant());
    scenario.end();
}

#[test, expected_failure(abort_code = item::EItemIdExists)]
fun deposit_singleton_duplicate_id_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    let ship = item::withdraw_singleton(&mut bag, 1, blueprint_key());
    // Re-mint the same id while the withdrawn copy is still in hand, then try
    // to deposit it back — the bag already has id 1.
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    item::deposit(&mut bag, ship, tenant());

    abort
}

#[test, expected_failure(abort_code = item::EItemIdNotFound)]
fun burn_singleton_absent_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::burn_singleton(&mut bag, 1, blueprint_key());

    abort
}

#[test, expected_failure(abort_code = item::EWrongType)]
fun withdraw_singleton_wrong_type_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    let _ship = item::withdraw_singleton(&mut bag, 1, fuel_key());

    abort
}

#[test, expected_failure(abort_code = item::EIsSingleton)]
fun split_singleton_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    let mut ship = item::withdraw_singleton(&mut bag, 1, blueprint_key());
    let _piece = item::split(&mut ship, 1, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = item::EIsSingleton)]
fun merge_singleton_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    item::mint_singleton(&mut bag, 2, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    let mut ship_a = item::withdraw_singleton(&mut bag, 1, blueprint_key());
    let ship_b = item::withdraw_singleton(&mut bag, 2, blueprint_key());
    item::merge(&mut ship_a, ship_b);

    abort
}

#[test]
fun burn_all_and_destroy_clears_singletons() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    item::mint_singleton(&mut bag, 1, blueprint_key(), BLUE_PRINT_VOL, scenario.ctx());
    item::mint(&mut bag, fuel_key(), 10, VOL);

    item::burn_all_and_destroy(bag, tenant());
    assert!(event::events_by_type<item::ItemBurned>().length() == 2);
    scenario.end();
}
