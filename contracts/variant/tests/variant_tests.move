#[test_only]
module variant::variant_tests;

use core::{admin_service::AdminACL, test_helpers::{setup, take_acl, tenant}};
use std::string;
use sui::{event, test_scenario as ts};
use variant::variant::{Self, Variant, VariantRegistered, VariantRegistry};

const ADMIN: address = @0xA;
const PLAYER: address = @0xB;

const TYPE_ID: u64 = 84210;
const VARIANT_ID: u64 = 7;
const UNIT_VOLUME: u64 = 1_250_000; // 0.00125 m³ per kg, at 1e9

const DENSITY: u32 = 12;
const IMPULSE: u32 = 208;
const LEAP_THRUST: u32 = 201;

// === Helpers ===

fun begin(): ts::Scenario {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    variant::init_for_testing(scenario.ctx());
    scenario
}

fun register_as(
    scenario: &mut ts::Scenario,
    sender: address,
    variant_id: u64,
    property_ids: vector<u32>,
    magnitudes: vector<u128>,
    negatives: vector<bool>,
) {
    ts::next_tx(scenario, sender);
    let mut registry = ts::take_shared<VariantRegistry>(scenario);
    let acl = take_acl(scenario);
    registry.register(
        &acl,
        tenant(),
        TYPE_ID,
        variant_id,
        variant::mass(),
        UNIT_VOLUME,
        property_ids,
        magnitudes,
        negatives,
        scenario.ctx(),
    );
    ts::return_shared(acl);
    ts::return_shared(registry);
}

fun register_default(scenario: &mut ts::Scenario) {
    register_as(
        scenario,
        ADMIN,
        VARIANT_ID,
        vector[LEAP_THRUST, IMPULSE],
        vector[100_000_000_000_000_000_000, 36_500_000_000],
        vector[false, false],
    );
}

fun take_registry_and_acl(scenario: &mut ts::Scenario): (VariantRegistry, AdminACL) {
    ts::next_tx(scenario, ADMIN);
    (ts::take_shared<VariantRegistry>(scenario), take_acl(scenario))
}

// === Success ===

#[test]
fun register_freezes_record_at_derived_address() {
    let mut scenario = begin();
    register_default(&mut scenario);

    let events = event::events_by_type<VariantRegistered>();
    assert!(events.length() == 1);
    let key = variant::new_key(tenant(), TYPE_ID, VARIANT_ID);
    assert!(events[0].registered_key() == key);

    ts::next_tx(&mut scenario, PLAYER);
    let registry = ts::take_shared<VariantRegistry>(&scenario);
    let record = ts::take_immutable<Variant>(&scenario);
    assert!(registry.exists(key));
    assert!(registry.derive_id(key) == object::id(&record).to_address());
    assert!(events[0].registered_id() == object::id(&record));

    assert!(record.key() == key);
    assert!(record.kind() == variant::mass());
    assert!(record.decimals() == 4);
    assert!(record.unit_volume() == UNIT_VOLUME);
    assert!(record.property_ids() == vector[LEAP_THRUST, IMPULSE]);

    // Leap thrust at 1e9 overflows u64, so it is kept as u128.
    let thrust = record.value(LEAP_THRUST).destroy_some();
    assert!(thrust.magnitude() == 100_000_000_000_000_000_000);
    assert!(!thrust.negative());
    assert!(record.value_u64(IMPULSE) == option::some(36_500_000_000));
    assert!(record.value(DENSITY).is_none());
    assert!(record.value_u64(DENSITY).is_none());

    ts::return_immutable(record);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun register_plain_type_with_no_values() {
    let mut scenario = begin();
    let (mut registry, acl) = take_registry_and_acl(&mut scenario);
    registry.register(
        &acl,
        tenant(),
        TYPE_ID,
        0,
        variant::units(),
        UNIT_VOLUME,
        vector[],
        vector[],
        vector[],
        scenario.ctx(),
    );
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, PLAYER);
    let record = ts::take_immutable<Variant>(&scenario);
    assert!(record.key().variant_id() == 0);
    assert!(record.kind() == variant::units());
    assert!(record.decimals() == 0);
    assert!(record.values().is_empty());
    ts::return_immutable(record);
    scenario.end();
}

#[test]
fun register_keeps_negative_values() {
    let mut scenario = begin();
    register_as(&mut scenario, ADMIN, VARIANT_ID, vector[DENSITY], vector[5], vector[true]);

    ts::next_tx(&mut scenario, PLAYER);
    let record = ts::take_immutable<Variant>(&scenario);
    let density = record.value(DENSITY).destroy_some();
    assert!(density.magnitude() == 5 && density.negative());
    ts::return_immutable(record);
    scenario.end();
}

#[test]
fun keys_differ_by_tenant_type_and_variant() {
    let mut scenario = begin();
    let (registry, acl) = take_registry_and_acl(&mut scenario);
    let key = variant::new_key(tenant(), TYPE_ID, VARIANT_ID);
    let other_tenant = variant::new_key(string::utf8(b"other"), TYPE_ID, VARIANT_ID);
    let other_type = variant::new_key(tenant(), TYPE_ID + 1, VARIANT_ID);
    let other_variant = variant::new_key(tenant(), TYPE_ID, VARIANT_ID + 1);
    assert!(registry.derive_id(key) != registry.derive_id(other_tenant));
    assert!(registry.derive_id(key) != registry.derive_id(other_type));
    assert!(registry.derive_id(key) != registry.derive_id(other_variant));
    assert!(!registry.exists(key));
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

// === Failure ===

#[test, expected_failure(abort_code = variant::EVariantAlreadyRegistered)]
fun register_twice_aborts() {
    let mut scenario = begin();
    register_default(&mut scenario);
    register_as(&mut scenario, ADMIN, VARIANT_ID, vector[], vector[], vector[]);
    abort
}

#[test, expected_failure(abort_code = variant::EUnauthorizedAdmin)]
fun register_by_non_admin_aborts() {
    let mut scenario = begin();
    register_as(&mut scenario, PLAYER, VARIANT_ID, vector[], vector[], vector[]);
    abort
}

#[test, expected_failure(abort_code = variant::EPropertyLengthMismatch)]
fun register_length_mismatch_aborts() {
    let mut scenario = begin();
    register_as(&mut scenario, ADMIN, VARIANT_ID, vector[DENSITY], vector[], vector[false]);
    abort
}

#[test, expected_failure(abort_code = variant::EPropertyIdsNotAscending)]
fun register_unsorted_ids_aborts() {
    let mut scenario = begin();
    register_as(
        &mut scenario,
        ADMIN,
        VARIANT_ID,
        vector[IMPULSE, DENSITY],
        vector[1, 1],
        vector[false, false],
    );
    abort
}

#[test, expected_failure(abort_code = variant::EPropertyIdsNotAscending)]
fun register_duplicate_ids_aborts() {
    let mut scenario = begin();
    register_as(
        &mut scenario,
        ADMIN,
        VARIANT_ID,
        vector[IMPULSE, IMPULSE],
        vector[1, 1],
        vector[false, false],
    );
    abort
}

#[test, expected_failure(abort_code = variant::EValuesWithoutVariant)]
fun register_values_without_variant_aborts() {
    let mut scenario = begin();
    register_as(&mut scenario, ADMIN, 0, vector[DENSITY], vector[1], vector[false]);
    abort
}

#[test, expected_failure(abort_code = variant::ENegativeZero)]
fun register_negative_zero_aborts() {
    let mut scenario = begin();
    register_as(&mut scenario, ADMIN, VARIANT_ID, vector[DENSITY], vector[0], vector[true]);
    abort
}

#[test, expected_failure(abort_code = variant::EZeroUnitVolume)]
fun register_zero_unit_volume_aborts() {
    let mut scenario = begin();
    let (mut registry, acl) = take_registry_and_acl(&mut scenario);
    registry.register(
        &acl,
        tenant(),
        TYPE_ID,
        VARIANT_ID,
        variant::mass(),
        0,
        vector[],
        vector[],
        vector[],
        scenario.ctx(),
    );
    abort
}

#[test, expected_failure(abort_code = variant::ETenantEmpty)]
fun new_key_empty_tenant_aborts() {
    variant::new_key(string::utf8(b""), TYPE_ID, VARIANT_ID);
    abort
}

#[test, expected_failure(abort_code = variant::ETypeIdZero)]
fun new_key_zero_type_aborts() {
    variant::new_key(tenant(), 0, VARIANT_ID);
    abort
}

#[test, expected_failure(abort_code = variant::ENegativeValue)]
fun value_u64_negative_aborts() {
    let mut scenario = begin();
    register_as(&mut scenario, ADMIN, VARIANT_ID, vector[DENSITY], vector[5], vector[true]);
    ts::next_tx(&mut scenario, PLAYER);
    let record = ts::take_immutable<Variant>(&scenario);
    record.value_u64(DENSITY);
    abort
}

#[test, expected_failure(abort_code = variant::EValueTooLarge)]
fun value_u64_too_large_aborts() {
    let mut scenario = begin();
    register_default(&mut scenario);
    ts::next_tx(&mut scenario, PLAYER);
    let record = ts::take_immutable<Variant>(&scenario);
    record.value_u64(LEAP_THRUST);
    abort
}
