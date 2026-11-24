#[test_only]
module variant::variant_tests;

use core::{admin_service, request, test_helpers::{setup, take_acl, tenant}};
use std::string;
use sui::{event, test_scenario as ts};
use variant::variant::{Self, QuantityKind, Variant, VariantRegistered, VariantRegistry};

const ADMIN: address = @0xA;
const PLAYER: address = @0xB;

const TYPE_ID: u64 = 84210;
const VARIANT_ID: u64 = 7;
const UNIT_VOLUME: u64 = 1_250_000; // 0.00125 m³ per item, at 1e9
const MASS_UNIT_VOLUME: u64 = 125_000; // 1/8000 m³ per kg, at 1e9

const DENSITY: u32 = 4;
const HARDNESS: u32 = 12;
const IMPULSE: u32 = 208;
const LEAP_THRUST: u32 = 201;

/// A foreign issuer, to show registration accepts only its own requests.
public struct Other() has drop;

// === Helpers ===

fun tenant_of_length(len: u64): string::String {
    let mut bytes = vector[];
    len.do!(|_| bytes.push_back(0x61));
    bytes.to_string()
}

fun begin(): ts::Scenario {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    variant::init_for_testing(scenario.ctx());
    scenario
}

/// Full registration flow as `sender`: register, verify admin, complete.
fun register_full(
    scenario: &mut ts::Scenario,
    sender: address,
    variant_id: u64,
    kind: QuantityKind,
    unit_volume: u64,
    property_ids: vector<u32>,
    magnitudes: vector<u128>,
    negatives: vector<bool>,
) {
    ts::next_tx(scenario, sender);
    let mut registry = ts::take_shared<VariantRegistry>(scenario);
    let acl = take_acl(scenario);
    let (record, mut req) = registry.register(
        tenant(),
        TYPE_ID,
        variant_id,
        kind,
        unit_volume,
        property_ids,
        magnitudes,
        negatives,
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    record.complete_registration(req);
    ts::return_shared(acl);
    ts::return_shared(registry);
}

fun register_as(
    scenario: &mut ts::Scenario,
    sender: address,
    variant_id: u64,
    property_ids: vector<u32>,
    magnitudes: vector<u128>,
    negatives: vector<bool>,
) {
    register_full(
        scenario,
        sender,
        variant_id,
        variant::units(),
        UNIT_VOLUME,
        property_ids,
        magnitudes,
        negatives,
    );
}

/// A mass variant: density 8,000 kg/m³ (so 1/8000 m³ per kg from the service), leap
/// thrust 1e11, impulse 36.5.
fun register_default(scenario: &mut ts::Scenario) {
    register_full(
        scenario,
        ADMIN,
        VARIANT_ID,
        variant::mass(),
        MASS_UNIT_VOLUME,
        vector[DENSITY, LEAP_THRUST, IMPULSE],
        vector[8_000_000_000_000, 100_000_000_000_000_000_000, 36_500_000_000],
        vector[false, false, false],
    );
}

fun take_registry(scenario: &mut ts::Scenario): VariantRegistry {
    ts::next_tx(scenario, ADMIN);
    ts::take_shared<VariantRegistry>(scenario)
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
    assert!(record.decimals() == 9);
    assert!(record.unit_volume() == MASS_UNIT_VOLUME);
    assert!(record.property_ids() == vector[DENSITY, LEAP_THRUST, IMPULSE]);

    // Leap thrust at 1e9 overflows u64, so it is kept as u128.
    let thrust = record.value(LEAP_THRUST).destroy_some();
    assert!(thrust.magnitude() == 100_000_000_000_000_000_000);
    assert!(!thrust.negative());
    assert!(record.value_u64(IMPULSE) == option::some(36_500_000_000));
    assert!(record.value(HARDNESS).is_none());
    assert!(record.value_u64(HARDNESS).is_none());

    ts::return_immutable(record);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun register_plain_type_with_no_values() {
    let mut scenario = begin();
    register_full(
        &mut scenario,
        ADMIN,
        0,
        variant::units(),
        UNIT_VOLUME,
        vector[],
        vector[],
        vector[],
    );

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
    register_as(&mut scenario, ADMIN, VARIANT_ID, vector[HARDNESS], vector[5], vector[true]);

    ts::next_tx(&mut scenario, PLAYER);
    let record = ts::take_immutable<Variant>(&scenario);
    let hardness = record.value(HARDNESS).destroy_some();
    assert!(hardness.magnitude() == 5 && hardness.negative());
    ts::return_immutable(record);
    scenario.end();
}

#[test]
fun keys_differ_by_tenant_type_and_variant() {
    let mut scenario = begin();
    let registry = take_registry(&mut scenario);
    let key = variant::new_key(tenant(), TYPE_ID, VARIANT_ID);
    let other_tenant = variant::new_key(string::utf8(b"other"), TYPE_ID, VARIANT_ID);
    let other_type = variant::new_key(tenant(), TYPE_ID + 1, VARIANT_ID);
    let other_variant = variant::new_key(tenant(), TYPE_ID, VARIANT_ID + 1);
    assert!(registry.derive_id(key) != registry.derive_id(other_tenant));
    assert!(registry.derive_id(key) != registry.derive_id(other_type));
    assert!(registry.derive_id(key) != registry.derive_id(other_variant));
    assert!(!registry.exists(key));
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

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun register_by_non_admin_aborts() {
    let mut scenario = begin();
    register_as(&mut scenario, PLAYER, VARIANT_ID, vector[], vector[], vector[]);
    abort
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun complete_without_admin_check_aborts() {
    let mut scenario = begin();
    let mut registry = take_registry(&mut scenario);
    let (record, req) = registry.register(
        tenant(),
        TYPE_ID,
        VARIANT_ID,
        variant::units(),
        UNIT_VOLUME,
        vector[],
        vector[],
        vector[],
    );
    record.complete_registration(req);
    abort
}

#[test, expected_failure(abort_code = request::EWrongIssuer)]
fun complete_with_foreign_request_aborts() {
    let mut scenario = begin();
    let mut registry = take_registry(&mut scenario);
    let (record, _req) = registry.register(
        tenant(),
        TYPE_ID,
        VARIANT_ID,
        variant::units(),
        UNIT_VOLUME,
        vector[],
        vector[],
        vector[],
    );
    // An empty request another module issued can't stand in for the admin check.
    record.complete_registration(request::new_for(internal::permit<Other>(), vector[]));
    abort
}

#[test, expected_failure(abort_code = variant::EPropertyLengthMismatch)]
fun register_length_mismatch_aborts() {
    let mut scenario = begin();
    register_as(&mut scenario, ADMIN, VARIANT_ID, vector[HARDNESS], vector[], vector[false]);
    abort
}

#[test, expected_failure(abort_code = variant::EPropertyIdsNotAscending)]
fun register_unsorted_ids_aborts() {
    let mut scenario = begin();
    register_as(
        &mut scenario,
        ADMIN,
        VARIANT_ID,
        vector[IMPULSE, HARDNESS],
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
    register_as(&mut scenario, ADMIN, 0, vector[HARDNESS], vector[1], vector[false]);
    abort
}

#[test, expected_failure(abort_code = variant::ENegativeZero)]
fun register_negative_zero_aborts() {
    let mut scenario = begin();
    register_as(&mut scenario, ADMIN, VARIANT_ID, vector[HARDNESS], vector[0], vector[true]);
    abort
}

#[test, expected_failure(abort_code = variant::EZeroUnitVolume)]
fun register_zero_unit_volume_aborts() {
    let mut scenario = begin();
    register_full(
        &mut scenario,
        ADMIN,
        VARIANT_ID,
        variant::units(),
        0,
        vector[],
        vector[],
        vector[],
    );
    abort
}

#[test, expected_failure(abort_code = variant::ETenantEmpty)]
fun new_key_empty_tenant_aborts() {
    variant::new_key(string::utf8(b""), TYPE_ID, VARIANT_ID);
    abort
}

#[test]
fun new_key_accepts_max_tenant_length() {
    let key = variant::new_key(tenant_of_length(variant::max_tenant_length()), TYPE_ID, VARIANT_ID);
    assert!(key.tenant().length() == variant::max_tenant_length());
}

#[test, expected_failure(abort_code = variant::ETenantTooLong)]
fun new_key_tenant_too_long_aborts() {
    variant::new_key(tenant_of_length(variant::max_tenant_length() + 1), TYPE_ID, VARIANT_ID);
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
    register_as(&mut scenario, ADMIN, VARIANT_ID, vector[HARDNESS], vector[5], vector[true]);
    ts::next_tx(&mut scenario, PLAYER);
    let record = ts::take_immutable<Variant>(&scenario);
    record.value_u64(HARDNESS);
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
