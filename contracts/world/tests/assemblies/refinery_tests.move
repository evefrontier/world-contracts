#[test_only]
module world::refinery_tests;

// Integration tests for the refinery module. Covers happy-path job lifecycle
// (anchor → online → mint input → start_job → advance clock → claim_outputs)
// plus the key abort conditions (EJobInProgress, EJobNotComplete, ENoActiveJob,
// ENotOnline, ERecipeNotFound).
//
// Pattern mirrors `storage_unit_tests.move` for setup (character + network
// node + fuel + energy). Refinery-specific helpers live in this file.

use std::string::{utf8, String};
use std::unit_test::assert_eq;
use sui::{clock::{Self, Clock}, derived_object, test_scenario as ts};
use world::{
    access::{Self, OwnerCap, AdminACL},
    character::{Self, Character},
    energy::EnergyConfig,
    fuel::FuelConfig,
    in_game_id,
    network_node::{Self, NetworkNode},
    object_registry::ObjectRegistry,
    recipe::{Self, RecipeRegistry},
    refinery::{Self, Refinery},
    test_helpers::{Self, admin, user_a, tenant}
};

// === Test constants ===

const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const MAX_CAPACITY: u64 = 100000;

// Character / Network Node
const CHARACTER_ITEM_ID: u32 = 1234u32;
const MS_PER_SECOND: u64 = 1000;
const NWN_TYPE_ID: u64 = 111000;
const NWN_ITEM_ID: u64 = 5000;
const FUEL_MAX_CAPACITY: u64 = 1000;
const FUEL_BURN_RATE_IN_MS: u64 = 3600 * MS_PER_SECOND;
const MAX_PRODUCTION: u64 = 100;
const FUEL_TYPE_ID: u64 = 1;
const FUEL_VOLUME: u64 = 10;

// Refinery — uses ASSEMBLY_TYPE_1 from test_helpers so EnergyConfig already covers it
const REFINERY_ITEM_ID: u64 = 90100;

// Recipe
const ORE_TYPE_ID: u64 = 77811; // Hydrated Sulfide Matrix
const ORE_ITEM_ID: u64 = 1000007139741;
const ORE_VOLUME: u64 = 100;
const BATCH_INPUT_QTY: u32 = 40;
const HYDROCARBON_RESIDUE_TYPE_ID: u64 = 84001;
const WATER_ICE_TYPE_ID: u64 = 84002;
const HYDROCARBON_RESIDUE_QTY: u32 = 20;
const WATER_ICE_QTY: u32 = 300;
const PROCESSING_TIME_MS: u64 = 3000;

// Other constants
const STATUS_ONLINE: u8 = 1;

// Mock extension witness
public struct TestAuth has drop {}

// === Setup helpers ===

fun setup_world_with_recipes(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
    test_helpers::configure_fuel(ts);
    test_helpers::configure_assembly_energy(ts);
    test_helpers::register_server_address(ts);
    // initialize the RecipeRegistry as a shared object (genesis stand-in)
    ts::next_tx(ts, test_helpers::governor());
    recipe::init_for_testing(ts.ctx());
}

fun register_hydrated_sulfide_recipe(ts: &mut ts::Scenario) {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<RecipeRegistry>(ts);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    recipe::register_recipe(
        &mut registry,
        &admin_acl,
        utf8(b"Hydrated Sulfide Matrix"),
        ORE_TYPE_ID,
        BATCH_INPUT_QTY,
        vector[HYDROCARBON_RESIDUE_TYPE_ID, WATER_ICE_TYPE_ID],
        vector[HYDROCARBON_RESIDUE_QTY, WATER_ICE_QTY],
        PROCESSING_TIME_MS,
        ts.ctx(),
    );
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
}

fun create_character(ts: &mut ts::Scenario): ID {
    ts::next_tx(ts, admin());
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = character::create_character(
        &mut registry,
        &admin_acl,
        CHARACTER_ITEM_ID,
        tenant(),
        100,
        user_a(),
        utf8(b"refinery-test-character"),
        ts.ctx(),
    );
    let character_id = object::id(&character);
    character.share_character(&admin_acl, ts.ctx());
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    character_id
}

fun create_network_node(ts: &mut ts::Scenario, character_id: ID): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let nwn = network_node::anchor(
        &mut registry,
        &character,
        &admin_acl,
        NWN_ITEM_ID,
        NWN_TYPE_ID,
        LOCATION_HASH,
        FUEL_MAX_CAPACITY,
        FUEL_BURN_RATE_IN_MS,
        MAX_PRODUCTION,
        ts.ctx(),
    );
    let id = object::id(&nwn);
    nwn.share_network_node(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(admin_acl);
    ts::return_shared(registry);
    id
}

fun create_refinery(ts: &mut ts::Scenario, character_id: ID, nwn_id: ID): ID {
    ts::next_tx(ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(ts);
    let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
    let character = ts::take_shared_by_id<Character>(ts, character_id);
    let admin_acl = ts::take_shared<AdminACL>(ts);
    let refinery = refinery::anchor(
        &mut registry,
        &mut nwn,
        &character,
        &admin_acl,
        REFINERY_ITEM_ID,
        test_helpers::assembly_type_1(),
        MAX_CAPACITY,
        LOCATION_HASH,
        ts.ctx(),
    );
    let refinery_id = object::id(&refinery);
    refinery.share_refinery(&admin_acl, ts.ctx());
    ts::return_shared(character);
    ts::return_shared(nwn);
    ts::return_shared(registry);
    ts::return_shared(admin_acl);
    refinery_id
}

fun online_refinery(
    ts: &mut ts::Scenario,
    user: address,
    character_id: ID,
    refinery_id: ID,
    nwn_id: ID,
    clock: &Clock,
) {
    // bring NWN online with fuel
    ts::next_tx(ts, user);
    let mut character = ts::take_shared_by_id<Character>(ts, character_id);
    let (nwn_cap, nwn_receipt) = character.borrow_owner_cap<NetworkNode>(
        ts::most_recent_receiving_ticket<OwnerCap<NetworkNode>>(&character_id),
        ts.ctx(),
    );
    ts::next_tx(ts, user);
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(ts, nwn_id);
        nwn.deposit_fuel_test(&nwn_cap, FUEL_TYPE_ID, FUEL_VOLUME, 10, clock);
        nwn.online(&nwn_cap, clock);
        ts::return_shared(nwn);
    };
    character.return_owner_cap(nwn_cap, nwn_receipt);

    // bring refinery online
    ts::next_tx(ts, user);
    {
        let mut refinery = ts::take_shared_by_id<Refinery>(ts, refinery_id);
        let (ref_cap, ref_receipt) = character.borrow_owner_cap<Refinery>(
            ts::most_recent_receiving_ticket<OwnerCap<Refinery>>(&character_id),
            ts.ctx(),
        );
        refinery.online(&ref_cap);
        let status = refinery.status();
        assert_eq!(status.status_to_u8(), STATUS_ONLINE);
        character.return_owner_cap(ref_cap, ref_receipt);
        ts::return_shared(refinery);
    };
    ts::return_shared(character);
}

fun mint_ore_into_refinery(
    ts: &mut ts::Scenario,
    user: address,
    character_id: ID,
    refinery_id: ID,
    quantity: u32,
) {
    ts::next_tx(ts, user);
    let mut character = ts::take_shared_by_id<Character>(ts, character_id);
    let (cap, receipt) = character.borrow_owner_cap<Refinery>(
        ts::most_recent_receiving_ticket<OwnerCap<Refinery>>(&character_id),
        ts.ctx(),
    );
    ts::next_tx(ts, user);
    {
        let mut refinery = ts::take_shared_by_id<Refinery>(ts, refinery_id);
        refinery.mint_input_for_testing<Refinery>(
            &character,
            &cap,
            ORE_ITEM_ID,
            ORE_TYPE_ID,
            ORE_VOLUME,
            quantity,
            ts.ctx(),
        );
        ts::return_shared(refinery);
    };
    character.return_owner_cap(cap, receipt);
    ts::return_shared(character);
}

fun authorize_test_extension(
    ts: &mut ts::Scenario,
    user: address,
    character_id: ID,
    refinery_id: ID,
) {
    ts::next_tx(ts, user);
    let mut character = ts::take_shared_by_id<Character>(ts, character_id);
    let (cap, receipt) = character.borrow_owner_cap<Refinery>(
        ts::most_recent_receiving_ticket<OwnerCap<Refinery>>(&character_id),
        ts.ctx(),
    );
    ts::next_tx(ts, user);
    {
        let mut refinery = ts::take_shared_by_id<Refinery>(ts, refinery_id);
        refinery.authorize_extension<TestAuth>(&cap);
        assert_eq!(refinery.has_authorized_extension(), true);
        ts::return_shared(refinery);
    };
    character.return_owner_cap(cap, receipt);
    ts::return_shared(character);
}

/// Bring everything online and return (refinery_id, nwn_id, character_id).
fun bootstrap(ts: &mut ts::Scenario, clock: &Clock): (ID, ID, ID) {
    setup_world_with_recipes(ts);
    register_hydrated_sulfide_recipe(ts);
    let character_id = create_character(ts);
    let nwn_id = create_network_node(ts, character_id);
    let refinery_id = create_refinery(ts, character_id, nwn_id);
    online_refinery(ts, user_a(), character_id, refinery_id, nwn_id, clock);
    (refinery_id, nwn_id, character_id)
}

// === Tests ===

#[test]
fun anchor_creates_refinery_with_inventory() {
    let mut scenario = ts::begin(test_helpers::governor());
    let clock = clock::create_for_testing(scenario.ctx());
    let (refinery_id, _nwn_id, _character_id) = bootstrap(&mut scenario, &clock);

    ts::next_tx(&mut scenario, user_a());
    {
        let refinery = ts::take_shared_by_id<Refinery>(&scenario, refinery_id);
        assert_eq!(refinery.status().status_to_u8(), STATUS_ONLINE);
        assert_eq!(refinery.has_active_job(), false);
        ts::return_shared(refinery);
    };

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun authorize_extension_registers_witness() {
    let mut scenario = ts::begin(test_helpers::governor());
    let clock = clock::create_for_testing(scenario.ctx());
    let (refinery_id, _nwn_id, character_id) = bootstrap(&mut scenario, &clock);
    authorize_test_extension(&mut scenario, user_a(), character_id, refinery_id);
    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test]
fun full_job_lifecycle_by_owner() {
    let mut scenario = ts::begin(test_helpers::governor());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000); // arbitrary non-zero start
    let (refinery_id, _nwn_id, character_id) = bootstrap(&mut scenario, &clock);

    // Seed input (40 of ORE_TYPE_ID = 1 batch)
    mint_ore_into_refinery(&mut scenario, user_a(), character_id, refinery_id, BATCH_INPUT_QTY);

    // start_job_by_owner
    ts::next_tx(&mut scenario, user_a());
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let (cap, receipt) = character.borrow_owner_cap<Refinery>(
        ts::most_recent_receiving_ticket<OwnerCap<Refinery>>(&character_id),
        scenario.ctx(),
    );
    ts::next_tx(&mut scenario, user_a());
    {
        let mut refinery = ts::take_shared_by_id<Refinery>(&scenario, refinery_id);
        let recipes = ts::take_shared<RecipeRegistry>(&scenario);
        refinery.start_job_by_owner<Refinery>(
            &character,
            &cap,
            &recipes,
            &clock,
            ORE_TYPE_ID,
            scenario.ctx(),
        );
        assert_eq!(refinery.has_active_job(), true);
        // Input was consumed (we minted exactly one batch). VecMap removes the
        // entry when qty drops to 0, so we check absence via contains_item.
        let owner_cap_id = refinery.owner_cap_id();
        assert_eq!(refinery.contains_item(owner_cap_id, ORE_TYPE_ID), false);
        ts::return_shared(refinery);
        ts::return_shared(recipes);
    };

    // Fast-forward past finishes_at_ms (recipe is 3000ms; jump 5000ms)
    clock.increment_for_testing(5000);

    // claim_outputs_by_owner
    ts::next_tx(&mut scenario, user_a());
    {
        let mut refinery = ts::take_shared_by_id<Refinery>(&scenario, refinery_id);
        refinery.claim_outputs_by_owner<Refinery>(&character, &cap, &clock, scenario.ctx());
        assert_eq!(refinery.has_active_job(), false);

        let owner_cap_id = refinery.owner_cap_id();
        assert_eq!(refinery.item_quantity(owner_cap_id, HYDROCARBON_RESIDUE_TYPE_ID), HYDROCARBON_RESIDUE_QTY);
        assert_eq!(refinery.item_quantity(owner_cap_id, WATER_ICE_TYPE_ID), WATER_ICE_QTY);
        ts::return_shared(refinery);
    };

    character.return_owner_cap(cap, receipt);
    ts::return_shared(character);

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test, expected_failure(abort_code = refinery::EJobInProgress)]
fun double_start_aborts() {
    let mut scenario = ts::begin(test_helpers::governor());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    let (refinery_id, _nwn_id, character_id) = bootstrap(&mut scenario, &clock);
    mint_ore_into_refinery(&mut scenario, user_a(), character_id, refinery_id, BATCH_INPUT_QTY * 2);

    ts::next_tx(&mut scenario, user_a());
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let (cap, receipt) = character.borrow_owner_cap<Refinery>(
        ts::most_recent_receiving_ticket<OwnerCap<Refinery>>(&character_id),
        scenario.ctx(),
    );
    ts::next_tx(&mut scenario, user_a());
    {
        let mut refinery = ts::take_shared_by_id<Refinery>(&scenario, refinery_id);
        let recipes = ts::take_shared<RecipeRegistry>(&scenario);
        refinery.start_job_by_owner<Refinery>(&character, &cap, &recipes, &clock, ORE_TYPE_ID, scenario.ctx());
        // Second start while the first is still active — should abort
        refinery.start_job_by_owner<Refinery>(&character, &cap, &recipes, &clock, ORE_TYPE_ID, scenario.ctx());
        ts::return_shared(refinery);
        ts::return_shared(recipes);
    };
    character.return_owner_cap(cap, receipt);
    ts::return_shared(character);

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test, expected_failure(abort_code = refinery::EJobNotComplete)]
fun claim_before_finish_aborts() {
    let mut scenario = ts::begin(test_helpers::governor());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    let (refinery_id, _nwn_id, character_id) = bootstrap(&mut scenario, &clock);
    mint_ore_into_refinery(&mut scenario, user_a(), character_id, refinery_id, BATCH_INPUT_QTY);

    ts::next_tx(&mut scenario, user_a());
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let (cap, receipt) = character.borrow_owner_cap<Refinery>(
        ts::most_recent_receiving_ticket<OwnerCap<Refinery>>(&character_id),
        scenario.ctx(),
    );
    ts::next_tx(&mut scenario, user_a());
    {
        let mut refinery = ts::take_shared_by_id<Refinery>(&scenario, refinery_id);
        let recipes = ts::take_shared<RecipeRegistry>(&scenario);
        refinery.start_job_by_owner<Refinery>(&character, &cap, &recipes, &clock, ORE_TYPE_ID, scenario.ctx());
        // claim without advancing clock — should abort EJobNotComplete
        refinery.claim_outputs_by_owner<Refinery>(&character, &cap, &clock, scenario.ctx());
        ts::return_shared(refinery);
        ts::return_shared(recipes);
    };
    character.return_owner_cap(cap, receipt);
    ts::return_shared(character);

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test, expected_failure(abort_code = refinery::ENoActiveJob)]
fun claim_with_no_job_aborts() {
    let mut scenario = ts::begin(test_helpers::governor());
    let clock = clock::create_for_testing(scenario.ctx());
    let (refinery_id, _nwn_id, character_id) = bootstrap(&mut scenario, &clock);

    ts::next_tx(&mut scenario, user_a());
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let (cap, receipt) = character.borrow_owner_cap<Refinery>(
        ts::most_recent_receiving_ticket<OwnerCap<Refinery>>(&character_id),
        scenario.ctx(),
    );
    ts::next_tx(&mut scenario, user_a());
    {
        let mut refinery = ts::take_shared_by_id<Refinery>(&scenario, refinery_id);
        // Never started a job — claim should abort ENoActiveJob
        refinery.claim_outputs_by_owner<Refinery>(&character, &cap, &clock, scenario.ctx());
        ts::return_shared(refinery);
    };
    character.return_owner_cap(cap, receipt);
    ts::return_shared(character);

    clock.destroy_for_testing();
    ts::end(scenario);
}

#[test, expected_failure(abort_code = refinery::ERecipeNotFound)]
fun start_unknown_recipe_aborts() {
    let mut scenario = ts::begin(test_helpers::governor());
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(1_000_000);
    let (refinery_id, _nwn_id, character_id) = bootstrap(&mut scenario, &clock);

    ts::next_tx(&mut scenario, user_a());
    let mut character = ts::take_shared_by_id<Character>(&scenario, character_id);
    let (cap, receipt) = character.borrow_owner_cap<Refinery>(
        ts::most_recent_receiving_ticket<OwnerCap<Refinery>>(&character_id),
        scenario.ctx(),
    );
    ts::next_tx(&mut scenario, user_a());
    {
        let mut refinery = ts::take_shared_by_id<Refinery>(&scenario, refinery_id);
        let recipes = ts::take_shared<RecipeRegistry>(&scenario);
        // Use a type_id we never registered
        refinery.start_job_by_owner<Refinery>(&character, &cap, &recipes, &clock, 999_999u64, scenario.ctx());
        ts::return_shared(refinery);
        ts::return_shared(recipes);
    };
    character.return_owner_cap(cap, receipt);
    ts::return_shared(character);

    clock.destroy_for_testing();
    ts::end(scenario);
}
