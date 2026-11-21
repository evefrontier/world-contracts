#[test_only]
module inventory::item_tests;

use inventory::item;
use std::string;
use sui::{event, test_scenario as ts};
use variant::variant::{Self, VariantKey};

const FUEL: u64 = 100;
const VOL: u64 = 10;
const COMPONENT: u64 = 7;
/// Decimals of a mass quantity: 1 kg is 10^9 base units.
const MASS: u8 = 9;
/// 0.0001 kg, the smallest whole mass step.
const STEP: u64 = 100_000;

fun tenant(): string::String { string::utf8(b"test") }

fun fuel_key(): VariantKey { variant::new_key(tenant(), FUEL, 0) }

fun source(): ID { object::id_from_address(@0x5) }

fun withdraw_item(
    bag: &mut item::ItemBag,
    key: VariantKey,
    quantity: u64,
    used: &mut u64,
    ctx: &mut TxContext,
): item::Item {
    item::mint(bag, key, quantity, VOL, 0, source(), COMPONENT, used);
    item::withdraw(bag, key, quantity, source(), COMPONENT, used, ctx)
}

#[test]
fun bag_mint_adds_balance() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;

    item::mint(&mut bag, key, 25, VOL, 0, source(), COMPONENT, &mut used);
    assert!(item::balance(&bag, key) == 25);

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
        let key = variant::new_key(tenant(), i + 1, 0);
        item::mint(&mut bag, key, i + 1, VOL, 0, source(), COMPONENT, &mut used);
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
        let (key, quantity, volume) = item::destroyed_balance_fields(&balances[i]);
        assert!(key.type_id() == expected && quantity == expected && volume == expected * VOL);
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
    item::deposit(&mut bag, item_a, source(), COMPONENT, &mut used);
    let item_b = withdraw_item(&mut bag, key, 20, &mut used, scenario.ctx());
    item::deposit(&mut bag, item_b, source(), COMPONENT, &mut used);
    assert!(item::balance(&bag, key) == 50);

    let out = item::withdraw(&mut bag, key, 15, source(), COMPONENT, &mut used, scenario.ctx());
    assert!(out.quantity() == 15);
    assert!(out.unit_volume() == VOL && out.volume() == 15 * VOL);
    assert!(item::balance(&bag, key) == 35);
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
    assert!(fuel.key() == key);
    assert!(fuel.quantity() == 50);
    assert!(fuel.unit_volume() == VOL && fuel.decimals() == 0);
    assert!(fuel.source() == source());
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
    item::mint(&mut bag, key, 10, VOL, 0, source(), COMPONENT, &mut used);
    // Must hit the balance check, not underflow `used`.
    let _out = item::withdraw(&mut bag, key, 11, source(), COMPONENT, &mut used, scenario.ctx());

    abort
}

/// Two variants of one type keep their own stacks, and a deposited `Item`
/// joins only its own variant's stack.
#[test]
fun variants_of_one_type_stay_separate() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let plain = fuel_key();
    let tuned = variant::new_key(tenant(), FUEL, 1);
    let mut used = 0;
    item::mint(&mut bag, plain, 10, VOL, 0, source(), COMPONENT, &mut used);
    item::mint(&mut bag, tuned, 5, VOL + 1, 0, source(), COMPONENT, &mut used);
    assert!(bag.balance_count() == 2);
    assert!(item::balance(&bag, plain) == 10 && item::balance(&bag, tuned) == 5);
    assert!(used == 10 * VOL + 5 * (VOL + 1));

    let mut other = item::new_bag(scenario.ctx());
    let mut other_used = 0;
    item::mint(&mut other, tuned, 2, VOL + 1, 0, source(), COMPONENT, &mut other_used);
    let item = item::withdraw(
        &mut other,
        tuned,
        2,
        source(),
        COMPONENT,
        &mut other_used,
        scenario.ctx(),
    );
    item::deposit(&mut bag, item, source(), COMPONENT, &mut used);
    assert!(bag.balance_count() == 2);
    assert!(item::balance(&bag, plain) == 10 && item::balance(&bag, tuned) == 7);
    assert!(item::volume_of(&bag, plain) == 10 * VOL);
    assert!(item::volume_of(&bag, tuned) == 7 * (VOL + 1));
    assert!(used == 10 * VOL + 7 * (VOL + 1));

    item::destroy_bag(other);
    item::destroy_bag(bag);
    scenario.end();
}

/// A mass stack rounds its volume up once, not once per mint: two 0.0001 kg
/// mints at 3 nano-m³/kg take ceil(3 × 0.0002) = 1, not 2.
#[test]
fun mass_stack_volume_rounds_up_once() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    item::mint(&mut bag, key, STEP, 3, MASS, source(), COMPONENT, &mut used);
    assert!(used == 1);
    item::mint(&mut bag, key, STEP, 3, MASS, source(), COMPONENT, &mut used);
    assert!(item::balance(&bag, key) == 2 * STEP);
    assert!(item::volume_of(&bag, key) == 1 && used == 1);

    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EQuantityNotWholeStep)]
fun mint_mass_not_whole_step_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let mut used = 0;
    item::mint(&mut bag, fuel_key(), STEP + 1, 3, MASS, source(), COMPONENT, &mut used);

    abort
}

#[test, expected_failure(abort_code = item::EQuantityNotWholeStep)]
fun split_mass_not_whole_step_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    item::mint(&mut bag, key, 2 * STEP, 3, MASS, source(), COMPONENT, &mut used);
    let mut a = item::withdraw(
        &mut bag,
        key,
        2 * STEP,
        source(),
        COMPONENT,
        &mut used,
        scenario.ctx(),
    );
    let _b = item::split(&mut a, STEP / 2, scenario.ctx());

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
    assert!(b.key() == key && b.unit_volume() == VOL);

    item::merge(&mut a, b);
    assert!(a.quantity() == 100);

    item::destroy(a);
    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EWrongVariant)]
fun merge_wrong_type_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key_a = fuel_key();
    let key_b = variant::new_key(tenant(), FUEL + 1, 0);
    let mut used = 0;
    let mut a = withdraw_item(&mut bag, key_a, 10, &mut used, scenario.ctx());
    let b = withdraw_item(&mut bag, key_b, 10, &mut used, scenario.ctx());
    item::merge(&mut a, b);

    abort
}

#[test, expected_failure(abort_code = item::EWrongVariant)]
fun merge_different_variant_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let tuned = variant::new_key(tenant(), FUEL, 1);
    let mut used = 0;
    let mut a = withdraw_item(&mut bag, fuel_key(), 10, &mut used, scenario.ctx());
    let b = withdraw_item(&mut bag, tuned, 10, &mut used, scenario.ctx());
    item::merge(&mut a, b);

    abort
}

#[test, expected_failure(abort_code = item::ESourceMismatch)]
fun merge_different_source_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let key = fuel_key();
    let mut used = 0;
    item::mint(&mut bag, key, 20, VOL, 0, source(), COMPONENT, &mut used);
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
    item::mint(&mut bag, key, 10, VOL, 0, source(), COMPONENT, &mut used);
    item::burn(&mut bag, key, 11, source(), COMPONENT, &mut used);

    abort
}

#[test]
fun batches_split_withdrawals_and_deposits_at_batch_size() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let mut used = 0;
    let mut keys = vector[];
    let mut quantities = vector[];
    5u64.do!(|i| {
        let key = variant::new_key(tenant(), i + 1, 0);
        item::mint(&mut bag, key, 10, VOL, 0, source(), COMPONENT, &mut used);
        keys.push_back(key);
        quantities.push_back(i + 1);
    });

    let items = item::withdraw_batch(
        &mut bag,
        keys,
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
            let (key, quantity, transit_id, balance_after, _) = item::moved_balance_fields(
                entry,
            );
            assert!(key.type_id() == seen + 1 && quantity == seen + 1);
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
    let (key, _, _, balance_after, used_after) = item::moved_balance_fields(&entries[0]);
    assert!(key.type_id() == 5 && balance_after == 10 && used_after == 50 * VOL);
    assert!(used == 50 * VOL);

    item::destroy_bag(bag);
    scenario.end();
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun withdraw_batch_over_balance_aborts() {
    let mut scenario = ts::begin(@0xA);
    let mut bag = item::new_bag(scenario.ctx());
    let mut used = 0;
    item::mint(&mut bag, fuel_key(), 10, VOL, 0, source(), COMPONENT, &mut used);
    // Each entry fits alone; together they exceed the balance.
    let _items = item::withdraw_batch(
        &mut bag,
        vector[fuel_key(), fuel_key()],
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

#[test]
fun stack_volume_per_kg_and_per_item() {
    // 12.5 kg at 1/8000 m³ per kg (density 8,000 kg/m³) is 0.0015625 m³.
    assert!(item::stack_volume(125_000, 12_500_000_000, 9) == 1_562_500);
    // Three items of 0.00125 m³.
    assert!(item::stack_volume(1_250_000, 3, 0) == 3_750_000);
}

#[test, expected_failure(abort_code = item::EVolumeOverflow)]
fun stack_volume_overflow_aborts() {
    item::stack_volume(std::u64::max_value!(), 2, 0);
    abort
}
