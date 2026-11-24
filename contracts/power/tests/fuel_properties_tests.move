#[test_only]
module power::fuel_properties_tests;

use core::{access_cap::AccessCap, entity::Entity, test_helpers::{setup, tenant}};
use power::{
    fuel_math,
    fuel_properties,
    grid_fuel,
    grid_scenario::{Self, admin, fuel_bay_id, kg, owner, setup_entity}
};
use std::string::{Self, String};
use sui::{clock, test_scenario as ts};
use variant::variant::{Self, QuantityKind, Variant, VariantRegistry};

const FUEL_TYPE: u64 = 7;

// === Helpers ===

/// Register a variant in `tenant` and return it, frozen, in a fresh tx.
fun register(
    scenario: &mut ts::Scenario,
    tenant: String,
    kind: QuantityKind,
    property_ids: vector<u32>,
    magnitudes: vector<u128>,
): Variant {
    let negatives = magnitudes.map_ref!(|_| false);
    register_signed(scenario, tenant, kind, property_ids, magnitudes, negatives)
}

/// `register` with signs.
fun register_signed(
    scenario: &mut ts::Scenario,
    tenant: String,
    kind: QuantityKind,
    property_ids: vector<u32>,
    magnitudes: vector<u128>,
    negatives: vector<bool>,
): Variant {
    ts::next_tx(scenario, admin());
    if (!ts::has_most_recent_shared<VariantRegistry>()) {
        variant::init_for_testing(scenario.ctx());
        ts::next_tx(scenario, admin());
    };
    let mut registry = ts::take_shared<VariantRegistry>(scenario);
    let id = registry.register_for_testing(
        tenant,
        FUEL_TYPE,
        1,
        kind,
        1,
        property_ids,
        magnitudes,
        negatives,
    );
    ts::return_shared(registry);
    ts::next_tx(scenario, admin());
    ts::take_immutable_by_id<Variant>(scenario, id)
}

/// A fuel variant: impulse 90.123456789, thermal 20, burden 14, volatility 1.
fun fuel(scenario: &mut ts::Scenario, tenant: String): Variant {
    register(
        scenario,
        tenant,
        variant::mass(),
        vector[208, 209, 210, 211],
        vector[90_123_456_789, 20_000_000_000, 14_000_000_000, 1_000_000_000],
    )
}

// === from_variant ===

#[test]
fun from_variant_loads_values_unchanged() {
    let mut scenario = ts::begin(admin());
    let record = fuel(&mut scenario, tenant());
    let (impulse, burden, volatility, thermal) = fuel_properties::from_variant(&record);
    assert!(impulse == 90_123_456_789);
    assert!(burden == 14_000_000_000);
    assert!(volatility == 1_000_000_000);
    assert!(thermal == 20_000_000_000);
    ts::return_immutable(record);
    scenario.end();
}

#[test, expected_failure(abort_code = fuel_properties::EMissingFuelProperty)]
fun from_variant_missing_property_aborts() {
    let mut scenario = ts::begin(admin());
    let record = register(
        &mut scenario,
        tenant(),
        variant::mass(),
        vector[208, 209, 210],
        vector[1, 1, 1],
    );
    fuel_properties::from_variant(&record);
    abort
}

#[test, expected_failure(abort_code = fuel_properties::ENotMass)]
fun from_variant_units_aborts() {
    let mut scenario = ts::begin(admin());
    let record = register(
        &mut scenario,
        tenant(),
        variant::units(),
        vector[208, 209, 210, 211],
        vector[1, 1, 1, 1],
    );
    fuel_properties::from_variant(&record);
    abort
}

#[test]
fun from_variant_loads_u64_max() {
    let mut scenario = ts::begin(admin());
    let max = std::u64::max_value!();
    let record = register(
        &mut scenario,
        tenant(),
        variant::mass(),
        vector[208, 209, 210, 211],
        vector[max as u128, 1, 1, 1_000_000_000],
    );
    let (impulse, _, _, _) = fuel_properties::from_variant(&record);
    assert!(impulse == max);
    ts::return_immutable(record);
    scenario.end();
}

#[test, expected_failure(abort_code = fuel_properties::EFuelPropertyTooLarge)]
fun from_variant_above_u64_aborts() {
    let mut scenario = ts::begin(admin());
    let too_large = (std::u64::max_value!() as u128) + 1;
    let record = register(
        &mut scenario,
        tenant(),
        variant::mass(),
        vector[208, 209, 210, 211],
        vector[too_large, 1, 1, 1],
    );
    fuel_properties::from_variant(&record);
    abort
}

#[test, expected_failure(abort_code = fuel_properties::ENegativeFuelProperty)]
fun from_variant_negative_aborts() {
    let mut scenario = ts::begin(admin());
    let record = register_signed(
        &mut scenario,
        tenant(),
        variant::mass(),
        vector[208, 209, 210, 211],
        vector[1, 1, 1, 1],
        vector[false, true, false, false],
    );
    fuel_properties::from_variant(&record);
    abort
}

// === assert_whole_step ===

#[test]
fun whole_steps_pass_and_scale_matches_variants() {
    fuel_properties::assert_whole_step(12_500_000_000);
    fuel_properties::assert_whole_step(fuel_properties::mass_step());
    assert!((fuel_math::scale() as u128) == variant::value_scale());
}

#[test, expected_failure(abort_code = fuel_properties::EAmountNotWholeStep)]
fun amount_below_step_aborts() {
    fuel_properties::assert_whole_step(12_500_000_001);
    abort
}

// === deposit ===

#[test, expected_failure(abort_code = grid_fuel::EVariantWrongTenant)]
fun deposit_variant_of_other_tenant_aborts() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, vector[], vector[], &clock);
    let record = fuel(&mut scenario, string::utf8(b"other"));

    ts::next_tx(&mut scenario, owner());
    let mut entity = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let _cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = entity.interact(
        string::utf8(grid_scenario::deposit_action_name()),
        scenario.ctx(),
    );
    grid_fuel::deposit_fuel(&mut entity, &mut req, fuel_bay_id(), &record, kg(), &clock);
    abort
}
