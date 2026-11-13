#[test_only]
module inventory::item_tests;

use core::entity_key;
use inventory::item;
use std::string;
use sui::{event, test_scenario as ts};

const FUEL: u64 = 100;
const VOL: u64 = 10;
const COMPONENT: u64 = 7;

fun tenant(): string::String { string::utf8(b"test") }

fun fuel_key(): entity_key::EntityKey { entity_key::new(FUEL, tenant()) }

fun source(): ID { object::id_from_address(@0x5) }

fun withdraw_item(
    bag: &mut item::ItemBag,
    key: entity_key::EntityKey,
    quantity: u64,
    used: &mut u64,
    ctx: &mut TxContext,
): item::Item {
    item::mint(bag, key, quantity, VOL, source(), COMPONENT, used);
    item::withdraw(bag, key, quantity, source(), COMPONENT, used, ctx)
}

#[test]
fun bag_mint_adds_balance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;

    item::mint(&mut bag, key, 25, VOL, source(), COMPONENT, &mut used);
    assert!(item::balance(&bag, FUEL) == 25);

    item::destroy_bag(bag);
    scenario.end();
}

/// Mint `count` types (ids 1..=count, quantity = id) into a fresh bag, then
/// drain it at `batch_size`. Returns the batches emitted.
fun drain_types(count: u64, batch_size: u64): vector<item::ItemsDestroyed> {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let mut used = 0;
    count.do!(|i| {
        let key = entity_key::new(i + 1, tenant());
        item::mint(&mut bag, key, i + 1, VOL, source(), COMPONENT, &mut used);
    });
    assert!(bag.balance_count() == count);
    item::drain_and_destroy(bag, source(), COMPONENT, batch_size);
    let batches = event::events_by_type<item::ItemsDestroyed>();
    scenario.end();
    batches
}

/// Batch `batch_index` holds `len` balances, continuing the 1..=count sequence.
fun assert_batch(batch: &item::ItemsDestroyed, batch_index: u64, len: u64, batch_size: u64) {
    let (entity_id, component_id, index, balances) = item::items_destroyed_fields(batch);
    assert!(entity_id == source() && component_id == COMPONENT);
    assert!(index == batch_index && balances.length() == len);
    len.do!(|i| {
        let expected = batch_index * batch_size + i + 1;
        let (type_id, quantity, volume) = item::destroyed_balance_fields(&balances[i]);
        assert!(type_id == expected && quantity == expected && volume == VOL);
    });
}

#[test]
fun drain_lists_balances_in_batches() {
    let batches = drain_types(5, 2);
    assert!(batches.length() == 3);
    assert_batch(&batches[0], 0, 2, 2);
    assert_batch(&batches[1], 1, 2, 2);
    assert_batch(&batches[2], 2, 1, 2);
    assert!(event::events_by_type<item::ItemBurned>().is_empty());
}

#[test]
fun drain_fills_batches_exactly() {
    let batches = drain_types(4, 2);
    assert!(batches.length() == 2);
    assert_batch(&batches[0], 0, 2, 2);
    assert_batch(&batches[1], 1, 2, 2);
}

#[test]
fun drain_under_one_batch() {
    let batches = drain_types(3, 1000);
    assert!(batches.length() == 1);
    assert_batch(&batches[0], 0, 3, 1000);
}

#[test]
fun drain_empty_bag_emits_nothing() {
    assert!(drain_types(0, 2).is_empty());
}

#[test]
fun full_batch_fits_the_event_size_limit() {
    // Sui's `max_event_emit_size`.
    assert!(item::full_batch_bcs_size(inventory::inventory::event_batch_size()) < 256_000);
}

#[test]
fun bag_deposit_merges_by_type() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;

    let item_a = withdraw_item(&mut bag, key, 30, &mut used, scenario.ctx());
    item::deposit(&mut bag, item_a, tenant(), source(), COMPONENT, &mut used);
    let item_b = withdraw_item(&mut bag, key, 20, &mut used, scenario.ctx());
    item::deposit(&mut bag, item_b, tenant(), source(), COMPONENT, &mut used);
    assert!(item::balance(&bag, FUEL) == 50);

    let out = item::withdraw(&mut bag, key, 15, source(), COMPONENT, &mut used, scenario.ctx());
    assert!(out.quantity() == 15);
    assert!(out.volume() == VOL);
    assert!(item::balance(&bag, FUEL) == 35);
    assert!(used == 35 * VOL);

    item::destroy(out);
    item::destroy_bag(bag);
    scenario.end();
}

#[test]
fun withdraw_records_fields() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    let fuel = withdraw_item(&mut bag, key, 50, &mut used, scenario.ctx());
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
    let mut used = 0;
    item::mint(&mut bag, key, 10, VOL, source(), COMPONENT, &mut used);
    // Must hit the balance check, not underflow `used`.
    let _out = item::withdraw(&mut bag, key, 11, source(), COMPONENT, &mut used, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = item::EVolumeMismatch)]
fun mint_mismatched_volume_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    item::mint(&mut bag, key, 10, VOL, source(), COMPONENT, &mut used);
    item::mint(&mut bag, key, 10, VOL + 1, source(), COMPONENT, &mut used);

    abort
}

#[test]
fun split_and_merge() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    let mut a = withdraw_item(&mut bag, key, 100, &mut used, scenario.ctx());
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
    let mut used = 0;
    let mut a = withdraw_item(&mut bag, key_a, 10, &mut used, scenario.ctx());
    let b = withdraw_item(&mut bag, key_b, 10, &mut used, scenario.ctx());
    item::merge(&mut a, b);

    abort
}

#[test, expected_failure(abort_code = item::ESourceMismatch)]
fun merge_different_source_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    item::mint(&mut bag, key, 20, VOL, source(), COMPONENT, &mut used);
    let mut a = item::withdraw(&mut bag, key, 10, source(), COMPONENT, &mut used, scenario.ctx());
    let b = item::withdraw(
        &mut bag,
        key,
        10,
        object::id_from_address(@0x6),
        COMPONENT,
        &mut used,
        scenario.ctx(),
    );
    item::merge(&mut a, b);

    abort
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun burn_over_balance_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    item::mint(&mut bag, key, 10, VOL, source(), COMPONENT, &mut used);
    item::burn(&mut bag, key, 11, source(), COMPONENT, &mut used);

    abort
}

#[test]
fun batches_split_withdrawals_and_deposits_at_batch_size() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let mut used = 0;
    let mut type_ids = vector[];
    let mut quantities = vector[];
    5u64.do!(|i| {
        item::mint(
            &mut bag,
            entity_key::new(i + 1, tenant()),
            10,
            VOL,
            source(),
            COMPONENT,
            &mut used,
        );
        type_ids.push_back(i + 1);
        quantities.push_back(i + 1);
    });

    let items = item::withdraw_batch(
        &mut bag,
        type_ids,
        quantities,
        source(),
        COMPONENT,
        &mut used,
        2,
        scenario.ctx(),
    );
    assert!(items.length() == 5);
    let withdrawn = event::events_by_type<item::ItemsWithdrawn>();
    assert!(withdrawn.length() == 3);
    let mut seen = 0;
    withdrawn.length().do!(|b| {
        let (
            entity_id,
            component_id,
            batch_index,
            batch_count,
            entries,
        ) = item::items_withdrawn_fields(
            &withdrawn[b],
        );
        assert!(entity_id == source() && component_id == COMPONENT);
        assert!(batch_index == b && batch_count == 3);
        assert!(entries.length() == if (b < 2) 2 else 1);
        entries.do_ref!(|entry| {
            let (type_id, quantity, transit_id, balance_after, _) = item::moved_balance_fields(
                entry,
            );
            assert!(type_id == seen + 1 && quantity == seen + 1);
            assert!(transit_id == object::id(&items[seen]) && balance_after == 10 - quantity);
            seen = seen + 1;
        });
    });
    assert!(seen == 5);

    item::deposit_batch(&mut bag, items, source(), COMPONENT, &mut used, 2);
    let deposited = event::events_by_type<item::ItemsDeposited>();
    assert!(deposited.length() == 3);
    let (_, _, _, batch_count, entries) = item::items_deposited_fields(&deposited[2]);
    assert!(batch_count == 3 && entries.length() == 1);
    let (type_id, _, _, balance_after, used_after) = item::moved_balance_fields(&entries[0]);
    assert!(type_id == 5 && balance_after == 10 && used_after == 50 * VOL);
    assert!(used == 50 * VOL);

    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun withdraw_batch_over_balance_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let mut used = 0;
    item::mint(&mut bag, fuel_key(), 10, VOL, source(), COMPONENT, &mut used);
    // Each entry fits alone; together they exceed the balance.
    let _items = item::withdraw_batch(
        &mut bag,
        vector[FUEL, FUEL],
        vector[6, 6],
        source(),
        COMPONENT,
        &mut used,
        2,
        scenario.ctx(),
    );

    abort
}

#[test]
fun full_moved_batch_fits_the_event_size_limit() {
    let size = item::full_moved_batch_bcs_size(inventory::inventory::event_batch_size());
    assert!(size < 256_000);
}
