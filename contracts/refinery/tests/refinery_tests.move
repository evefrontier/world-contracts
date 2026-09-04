#[test_only]
module refinery::refinery_tests;

use core::{
    entity::{Self, Entity},
    entity_key,
    location_service,
    object_registry::{Self, ObjectRegistry}
};
use refinery::{recipe, refinery::{Self, RefineryCreated}};
use std::string::{Self, String};
use sui::{clock, event, test_scenario as ts};

const ADMIN: address = @0xA;
const TENANT: vector<u8> = b"alpha";
const TENANT2: vector<u8> = b"beta";
const IN_GAME_ID: u64 = 99;
const LOC: vector<u8> = b"refinery-loc";

// Real Stillness schema #19 (docs/data/refinery_schemas.md):
// Hydrated Sulfide Matrix (77811) x40 -> Hydrocarbon Residue (89258) x20 +
// Water Ice (78423) x300, 3s processing.
const INPUT_TYPE: u64 = 77811;
const INPUT_QTY: u64 = 40;
const PROCESSING_MS: u64 = 3000;

fun tenant(): String { string::utf8(TENANT) }

fun fixture_recipe(): recipe::Recipe {
    recipe::new_recipe(INPUT_TYPE, INPUT_QTY, vector[89258, 78423], vector[20, 300], PROCESSING_MS)
}

fun setup_registry(scenario: &mut ts::Scenario) {
    object_registry::init_for_testing(scenario.ctx());
}

fun create_refinery(scenario: &mut ts::Scenario, in_game_id: u64, tenant: String) {
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    refinery::create(&mut registry, in_game_id, tenant, LOC, fixture_recipe(), scenario.ctx());
    ts::return_shared(registry);
}

/// Resolve the deterministic refinery object ID for `(in_game_id, tenant)`.
fun refinery_id(registry: &ObjectRegistry, in_game_id: u64, tenant: String): ID {
    object::id_from_address(registry.derive_id(entity_key::new(in_game_id, tenant)))
}

// === Construction ===

#[test]
fun create_installs_recipe() {
    let mut scenario = ts::begin(ADMIN);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_refinery(&mut scenario, IN_GAME_ID, tenant());

    ts::next_tx(&mut scenario, ADMIN);
    {
        let e = ts::take_shared<Entity>(&scenario);
        assert!(e.has_module(string::utf8(b"recipe")));
        assert!(e.location_hash() == LOC);
        assert!(e.key() == entity_key::new(IN_GAME_ID, tenant()));

        let r = refinery::recipe_of(&e);
        assert!(recipe::input_type_id(&r) == INPUT_TYPE);
        assert!(recipe::input_quantity(&r) == INPUT_QTY);
        assert!(recipe::output_type_ids(&r) == vector[89258, 78423]);
        assert!(recipe::output_quantities(&r) == vector[20, 300]);
        assert!(recipe::processing_ms(&r) == PROCESSING_MS);
        assert!(!refinery::has_active_job(&e));
        ts::return_shared(e);
    };

    scenario.end();
}

#[test]
fun create_emits_event() {
    let mut scenario = ts::begin(ADMIN);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_refinery(&mut scenario, IN_GAME_ID, tenant());

    assert!(event::events_by_type<RefineryCreated>().length() == 1);

    scenario.end();
}

#[test]
fun same_id_different_tenants_are_distinct() {
    let mut scenario = ts::begin(ADMIN);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_refinery(&mut scenario, IN_GAME_ID, tenant());

    ts::next_tx(&mut scenario, ADMIN);
    create_refinery(&mut scenario, IN_GAME_ID, string::utf8(TENANT2));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = ts::take_shared<ObjectRegistry>(&scenario);
        let id_a = refinery_id(&registry, IN_GAME_ID, tenant());
        let id_b = refinery_id(&registry, IN_GAME_ID, string::utf8(TENANT2));
        ts::return_shared(registry);
        assert!(id_a != id_b);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = entity::EEntityAlreadyExists)]
fun create_twice_same_key_fails() {
    let mut scenario = ts::begin(ADMIN);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    refinery::create(&mut registry, IN_GAME_ID, tenant(), LOC, fixture_recipe(), scenario.ctx());
    refinery::create(&mut registry, IN_GAME_ID, tenant(), LOC, fixture_recipe(), scenario.ctx());

    abort
}

// === Job lifecycle ===

#[test]
fun start_then_claim_completes_job() {
    let mut scenario = ts::begin(ADMIN);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_refinery(&mut scenario, IN_GAME_ID, tenant());

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut e = ts::take_shared<Entity>(&scenario);
        let mut c = clock::create_for_testing(scenario.ctx());

        // Start: interact -> proximity -> start_refine -> complete.
        let mut req = e.interact(string::utf8(b"start_refine"), scenario.ctx());
        location_service::verify_proximity(&mut req, LOC);
        recipe::start_refine(&mut e, &mut req, &c, scenario.ctx());
        e.complete_request(req);

        assert!(refinery::has_active_job(&e));
        assert!(recipe::job_finishes_at(&e) == PROCESSING_MS); // clock started at 0

        // Advance past the snapshotted finish time.
        c.increment_for_testing(PROCESSING_MS);

        // Claim: interact -> proximity -> claim -> complete.
        let mut req = e.interact(string::utf8(b"claim"), scenario.ctx());
        location_service::verify_proximity(&mut req, LOC);
        recipe::claim(&mut e, &mut req, &c, scenario.ctx());
        e.complete_request(req);

        assert!(!refinery::has_active_job(&e));

        c.destroy_for_testing();
        ts::return_shared(e);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = recipe::EJobNotComplete)]
fun claim_before_finish_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_refinery(&mut scenario, IN_GAME_ID, tenant());

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared<Entity>(&scenario);
    let c = clock::create_for_testing(scenario.ctx());

    let mut req = e.interact(string::utf8(b"start_refine"), scenario.ctx());
    location_service::verify_proximity(&mut req, LOC);
    recipe::start_refine(&mut e, &mut req, &c, scenario.ctx());
    e.complete_request(req);

    // Claim immediately (clock still at 0, before finish): must abort.
    let mut req = e.interact(string::utf8(b"claim"), scenario.ctx());
    location_service::verify_proximity(&mut req, LOC);
    recipe::claim(&mut e, &mut req, &c, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = recipe::EJobInProgress)]
fun double_start_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_refinery(&mut scenario, IN_GAME_ID, tenant());

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared<Entity>(&scenario);
    let c = clock::create_for_testing(scenario.ctx());

    let mut req = e.interact(string::utf8(b"start_refine"), scenario.ctx());
    location_service::verify_proximity(&mut req, LOC);
    recipe::start_refine(&mut e, &mut req, &c, scenario.ctx());
    e.complete_request(req);

    // Second start while a job is in flight: must abort.
    let mut req = e.interact(string::utf8(b"start_refine"), scenario.ctx());
    location_service::verify_proximity(&mut req, LOC);
    recipe::start_refine(&mut e, &mut req, &c, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = recipe::ENoActiveJob)]
fun claim_without_job_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_refinery(&mut scenario, IN_GAME_ID, tenant());

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared<Entity>(&scenario);
    let c = clock::create_for_testing(scenario.ctx());

    // Claim with no job started: must abort.
    let mut req = e.interact(string::utf8(b"claim"), scenario.ctx());
    location_service::verify_proximity(&mut req, LOC);
    recipe::claim(&mut e, &mut req, &c, scenario.ctx());

    abort
}

// === Recipe validation ===

#[test, expected_failure(abort_code = recipe::ERecipeOutputsLengthMismatch)]
fun new_recipe_length_mismatch_aborts() {
    // 2 output type ids but only 1 quantity.
    let _r = recipe::new_recipe(
        INPUT_TYPE,
        INPUT_QTY,
        vector[89258, 78423],
        vector[20],
        PROCESSING_MS,
    );
    abort
}

#[test, expected_failure(abort_code = recipe::ERecipeOutputsEmpty)]
fun new_recipe_empty_outputs_aborts() {
    let _r = recipe::new_recipe(INPUT_TYPE, INPUT_QTY, vector[], vector[], PROCESSING_MS);
    abort
}

#[test, expected_failure(abort_code = recipe::ERecipeZeroInput)]
fun new_recipe_zero_input_qty_aborts() {
    let _r = recipe::new_recipe(INPUT_TYPE, 0, vector[89258], vector[20], PROCESSING_MS);
    abort
}

#[test, expected_failure(abort_code = recipe::ERecipeZeroOutput)]
fun new_recipe_zero_output_qty_aborts() {
    let _r = recipe::new_recipe(INPUT_TYPE, INPUT_QTY, vector[89258], vector[0], PROCESSING_MS);
    abort
}

#[test, expected_failure(abort_code = location_service::EProximityMismatch)]
fun interact_wrong_proximity_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup_registry(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_refinery(&mut scenario, IN_GAME_ID, tenant());

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared<Entity>(&scenario);

    // Wrong proximity proof: must abort before the handler runs.
    let mut req = e.interact(string::utf8(b"start_refine"), scenario.ctx());
    location_service::verify_proximity(&mut req, b"wrong-loc");

    abort
}
