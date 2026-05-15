#[test_only]
module world::recipe_tests;

use std::string;
use std::unit_test::assert_eq;
use sui::test_scenario as ts;
use world::{
    access::AdminACL,
    recipe::{Self, RecipeRegistry},
    test_helpers::{Self, governor, admin}
};

const ORE_TYPE_ID: u64 = 1234;
const TRIT_TYPE_ID: u64 = 34;
const PYE_TYPE_ID: u64 = 35;
const MEX_TYPE_ID: u64 = 36;

fun setup(): ts::Scenario {
    let mut scenario = ts::begin(governor());
    test_helpers::setup_world(&mut scenario);
    // recipe::init runs at publish time via genesis. For tests we need a registry.
    ts::next_tx(&mut scenario, governor());
    recipe::init_for_testing(scenario.ctx());
    scenario
}

#[test]
fun register_and_lookup_recipe() {
    let mut scenario = setup();
    ts::next_tx(&mut scenario, admin());
    {
        let mut registry = ts::take_shared<RecipeRegistry>(&scenario);
        let admin_acl = ts::take_shared<AdminACL>(&scenario);
        recipe::register_recipe(
            &mut registry,
            &admin_acl,
            string::utf8(b"Common Ore Refining"),
            ORE_TYPE_ID,
            100,
            vector[TRIT_TYPE_ID, PYE_TYPE_ID, MEX_TYPE_ID],
            vector[60, 30, 10],
            60_000,
            scenario.ctx(),
        );

        assert_eq!(recipe::has_recipe(&registry, ORE_TYPE_ID), true);
        assert_eq!(recipe::has_recipe(&registry, 9999), false);

        let r = recipe::borrow_recipe(&registry, ORE_TYPE_ID);
        assert_eq!(recipe::input_type_id(r), ORE_TYPE_ID);
        assert_eq!(recipe::input_quantity(r), 100);
        assert_eq!(recipe::processing_time_ms(r), 60_000);
        assert_eq!(*recipe::output_type_ids(r), vector[TRIT_TYPE_ID, PYE_TYPE_ID, MEX_TYPE_ID]);
        assert_eq!(*recipe::output_quantities(r), vector[60, 30, 10]);

        ts::return_shared(registry);
        ts::return_shared(admin_acl);
    };
    ts::end(scenario);
}

#[test]
fun update_recipe_overwrites_existing() {
    let mut scenario = setup();
    ts::next_tx(&mut scenario, admin());
    {
        let mut registry = ts::take_shared<RecipeRegistry>(&scenario);
        let admin_acl = ts::take_shared<AdminACL>(&scenario);
        recipe::register_recipe(
            &mut registry,
            &admin_acl,
            string::utf8(b"v1"),
            ORE_TYPE_ID,
            100,
            vector[TRIT_TYPE_ID],
            vector[50],
            60_000,
            scenario.ctx(),
        );
        recipe::update_recipe(
            &mut registry,
            &admin_acl,
            string::utf8(b"v2"),
            ORE_TYPE_ID,
            200,
            vector[TRIT_TYPE_ID, PYE_TYPE_ID],
            vector[75, 25],
            30_000,
            scenario.ctx(),
        );
        let r = recipe::borrow_recipe(&registry, ORE_TYPE_ID);
        assert_eq!(recipe::input_quantity(r), 200);
        assert_eq!(recipe::processing_time_ms(r), 30_000);
        assert_eq!(vector::length(recipe::output_type_ids(r)), 2);
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
    };
    ts::end(scenario);
}

#[test]
fun remove_recipe_clears_entry() {
    let mut scenario = setup();
    ts::next_tx(&mut scenario, admin());
    {
        let mut registry = ts::take_shared<RecipeRegistry>(&scenario);
        let admin_acl = ts::take_shared<AdminACL>(&scenario);
        recipe::register_recipe(
            &mut registry,
            &admin_acl,
            string::utf8(b"to-remove"),
            ORE_TYPE_ID,
            10,
            vector[TRIT_TYPE_ID],
            vector[5],
            1_000,
            scenario.ctx(),
        );
        assert_eq!(recipe::has_recipe(&registry, ORE_TYPE_ID), true);
        recipe::remove_recipe(&mut registry, &admin_acl, ORE_TYPE_ID, scenario.ctx());
        assert_eq!(recipe::has_recipe(&registry, ORE_TYPE_ID), false);
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
    };
    ts::end(scenario);
}

#[test, expected_failure(abort_code = recipe::ERecipeAlreadyExists)]
fun double_register_aborts() {
    let mut scenario = setup();
    ts::next_tx(&mut scenario, admin());
    {
        let mut registry = ts::take_shared<RecipeRegistry>(&scenario);
        let admin_acl = ts::take_shared<AdminACL>(&scenario);
        recipe::register_recipe(
            &mut registry, &admin_acl,
            string::utf8(b"a"), ORE_TYPE_ID, 1, vector[TRIT_TYPE_ID], vector[1], 1, scenario.ctx(),
        );
        // Should abort:
        recipe::register_recipe(
            &mut registry, &admin_acl,
            string::utf8(b"b"), ORE_TYPE_ID, 1, vector[TRIT_TYPE_ID], vector[1], 1, scenario.ctx(),
        );
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
    };
    ts::end(scenario);
}

#[test, expected_failure(abort_code = recipe::ERecipeNotFound)]
fun borrow_missing_aborts() {
    let mut scenario = setup();
    ts::next_tx(&mut scenario, admin());
    {
        let registry = ts::take_shared<RecipeRegistry>(&scenario);
        let _ = recipe::borrow_recipe(&registry, 9999);
        ts::return_shared(registry);
    };
    ts::end(scenario);
}

#[test, expected_failure(abort_code = recipe::ERecipeInputTypeMismatch)]
fun input_in_outputs_aborts() {
    let mut scenario = setup();
    ts::next_tx(&mut scenario, admin());
    {
        let mut registry = ts::take_shared<RecipeRegistry>(&scenario);
        let admin_acl = ts::take_shared<AdminACL>(&scenario);
        // Output reuses input type_id — should abort
        recipe::register_recipe(
            &mut registry, &admin_acl,
            string::utf8(b"loop"), ORE_TYPE_ID, 1,
            vector[ORE_TYPE_ID], vector[1], 1, scenario.ctx(),
        );
        ts::return_shared(registry);
        ts::return_shared(admin_acl);
    };
    ts::end(scenario);
}
