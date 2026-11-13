#[test_only]
module inventory::item_tests;

use core::entity_key;
use inventory::item;
use std::string;
use sui::{event, test_scenario as ts};

const FUEL: u64 = 100;
const VOL: u64 = 10;
const LENS: u64 = 200;
const LENS_VOL: u64 = 3;
const COMPONENT: u64 = 7;
// Bag-level tests don't track inventory volume; large enough never to underflow.
const USED: u64 = 1_000_000;

fun tenant(): string::String { string::utf8(b"test") }

fun fuel_key(): entity_key::EntityKey { entity_key::new(FUEL, tenant()) }

fun source(): ID { object::id_from_address(@0x5) }

fun withdraw_item(
    bag: &mut item::ItemBag,
    key: entity_key::EntityKey,
    quantity: u64,
    ctx: &mut TxContext,
): item::Item {
    item::mint(bag, key, quantity, VOL, source(), COMPONENT, USED);
    item::withdraw(bag, key, quantity, source(), COMPONENT, USED, ctx)
}

#[test]
fun bag_mint_adds_balance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    item::mint(&mut bag, key, 25, VOL, source(), COMPONENT, USED);
    assert!(item::balance(&bag, FUEL) == 25);

    item::destroy_bag(bag);
    scenario.end();
}

#[test]
fun burn_all_clears_bag() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    item::mint(&mut bag, key, 50, VOL, source(), COMPONENT, USED);
    item::mint(&mut bag, entity_key::new(LENS, tenant()), 2, LENS_VOL, source(), COMPONENT, USED);
    assert!(item::balance(&bag, FUEL) == 50);
    item::burn_all_and_destroy(bag, tenant(), source(), COMPONENT, 50 * VOL + 2 * LENS_VOL);

    let burned = event::events_by_type<item::ItemBurned>();
    assert!(burned.length() == 2);
    let (
        game_id,
        quantity,
        entity_id,
        component_id,
        balance_after,
        used_after,
    ) = item::burned_fields(
        &burned[0],
    );
    assert!(game_id == key && quantity == 50);
    assert!(entity_id == source() && component_id == COMPONENT);
    assert!(balance_after == 0 && used_after == 2 * LENS_VOL);
    let (game_id, quantity, _, _, balance_after, used_after) = item::burned_fields(&burned[1]);
    assert!(game_id == entity_key::new(LENS, tenant()) && quantity == 2);
    assert!(balance_after == 0 && used_after == 0);
    scenario.end();
}

#[test]
fun bag_deposit_merges_by_type() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();

    let item_a = withdraw_item(&mut bag, key, 30, scenario.ctx());
    item::deposit(&mut bag, item_a, tenant(), source(), COMPONENT, USED);
    let item_b = withdraw_item(&mut bag, key, 20, scenario.ctx());
    item::deposit(&mut bag, item_b, tenant(), source(), COMPONENT, USED);
    assert!(item::balance(&bag, FUEL) == 50);

    let out = item::withdraw(&mut bag, key, 15, source(), COMPONENT, USED, scenario.ctx());
    assert!(out.quantity() == 15);
    assert!(out.volume() == VOL);
    assert!(item::balance(&bag, FUEL) == 35);

    item::destroy(out);
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
    item::destroy(fuel);
    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun withdraw_over_balance_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    item::mint(&mut bag, key, 10, VOL, source(), COMPONENT, USED);
    let _out = item::withdraw(&mut bag, key, 11, source(), COMPONENT, USED, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = item::EVolumeMismatch)]
fun mint_mismatched_volume_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    item::mint(&mut bag, key, 10, VOL, source(), COMPONENT, USED);
    item::mint(&mut bag, key, 10, VOL + 1, source(), COMPONENT, USED);

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

    item::destroy(a);
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

#[test, expected_failure(abort_code = item::ESourceMismatch)]
fun merge_different_source_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    item::mint(&mut bag, key, 20, VOL, source(), COMPONENT, USED);
    let mut a = item::withdraw(&mut bag, key, 10, source(), COMPONENT, USED, scenario.ctx());
    let b = item::withdraw(
        &mut bag,
        key,
        10,
        object::id_from_address(@0x6),
        COMPONENT,
        USED,
        scenario.ctx(),
    );
    item::merge(&mut a, b);

    abort
}
