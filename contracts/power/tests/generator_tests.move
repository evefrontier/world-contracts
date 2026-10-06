#[test_only]
module power::generator_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::Entity,
    requirement::Requirement,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use power::{
    generator::{Self, GeneratorInstalled, GeneratorUninstalled},
    power_grid::{Self, CapacityChanged, GeneratorRegistered, GeneratorToggled}
};
use std::string;
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const GEN_A: u64 = 101;
const GEN_B: u64 = 102;
const OUTPUT_A: u64 = 50;
const OUTPUT_B: u64 = 30;
const CONTAINMENT: u64 = 10;

const MANAGE: vector<u8> = b"manage_generator";
const OPERATE: vector<u8> = b"operate_grid";
const OP_ONLINE: u8 = 0;
const OP_OFFLINE: u8 = 1;
const OP_POWER_ON: u8 = 2;

// === Helpers ===

/// Share an entity with a grid and Generator components A and B (unregistered),
/// the admin `manage_generator` action, OWNER's
/// AccessCap, and the owner-gated `operate_grid` action.
fun setup_entity(scenario: &mut ts::Scenario, clock: &Clock): ID {
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    let mut req = power_grid::install(&mut e, clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    install_generator(&mut e, &acl, GEN_A, scenario.ctx());
    install_generator(&mut e, &acl, GEN_B, scenario.ctx());
    enable_admin(&mut e, &acl, MANAGE, power_grid::manage_generator_requirement(), scenario.ctx());

    let mut req = e.mint_access(OWNER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let entity_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    enable(scenario, entity_id, OPERATE, power_grid::operate_grid_requirement());
    entity_id
}

fun install_generator(e: &mut Entity, acl: &AdminACL, component_id: u64, ctx: &mut TxContext) {
    let mut req = generator::install(e, component_id, option::none(), ctx);
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
}

fun enable_admin(
    e: &mut Entity,
    acl: &AdminACL,
    name: vector<u8>,
    target: Requirement,
    ctx: &mut TxContext,
) {
    let mut req = e.enable_admin_action(string::utf8(name), action::new(vector[target]), ctx);
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
}

fun enable(scenario: &mut ts::Scenario, entity_id: ID, name: vector<u8>, target: Requirement) {
    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let act = action::new(vector[access_cap::owner_requirement(), target]);
    let mut req = e.enable_action(string::utf8(name), act, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

/// `signer` runs `manage_generator` to register `id`; the admin requirement is
/// verified against `signer`.
fun register_as(
    scenario: &mut ts::Scenario,
    signer: address,
    entity_id: ID,
    id: u64,
    output: u64,
    clock: &Clock,
) {
    ts::next_tx(scenario, signer);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = e.interact(string::utf8(MANAGE), scenario.ctx());
    power_grid::register_generator(&mut e, &mut req, id, output, CONTAINMENT, clock);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(e);
}

fun register(scenario: &mut ts::Scenario, entity_id: ID, id: u64, output: u64, clock: &Clock) {
    register_as(scenario, ADMIN, entity_id, id, output, clock);
}

fun unregister(scenario: &mut ts::Scenario, entity_id: ID, id: u64, clock: &Clock) {
    ts::next_tx(scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = e.interact(string::utf8(MANAGE), scenario.ctx());
    power_grid::unregister_generator(&mut e, &mut req, id, clock);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(e);
}

fun uninstall_generator(scenario: &mut ts::Scenario, entity_id: ID, id: u64) {
    ts::next_tx(scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = power_grid::uninstall_generator(&mut e, id, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(e);
}

/// Owner runs operation `op`(operation) on Generator `id` (`id` is ignored for `OP_POWER_ON`).
fun owner_runs_operation(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    op: u8,
    id: u64,
    clock: &Clock,
) {
    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let mut req = e.interact(string::utf8(OPERATE), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    if (op == OP_POWER_ON) power_grid::set_power_grid(&mut e, &mut req, true, clock)
    else power_grid::set_generator(&mut e, &mut req, id, op == OP_ONLINE, clock);
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

/// Register Generator `id` and bring it online.
fun register_and_online(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    id: u64,
    output: u64,
    clock: &Clock,
) {
    register(scenario, entity_id, id, output, clock);
    owner_runs_operation(scenario, entity_id, OP_ONLINE, id, clock);
}

/// Read the grid's `capacity_mw` and `effective_capacity_mw`.
fun capacity(scenario: &mut ts::Scenario, entity_id: ID): (u64, u64) {
    ts::next_tx(scenario, OWNER);
    let e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let grid = power_grid::power_grid(&e);
    let total = grid.capacity_mw();
    let effective = grid.effective_capacity_mw();
    ts::return_shared(e);
    (total, effective)
}

// === Tests ===

#[test]
fun install_emits_event_and_starts_unregistered() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    install_generator(&mut e, &acl, GEN_A, scenario.ctx());
    assert!(event::events_by_type<GeneratorInstalled>().length() == 1);
    assert!(e.has_component(GEN_A));
    assert!(!power_grid::is_generator_registered(&e, GEN_A));

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun register_adds_offline_state_to_grid() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    clock.set_for_testing(5_000);
    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    assert!(event::events_by_type<GeneratorRegistered>().length() == 1);

    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        assert!(power_grid::is_generator_registered(&e, GEN_A));
        assert!(!power_grid::is_generator_registered(&e, GEN_B));
        let state = power_grid::generator_state(&e, GEN_A);
        assert!(state.max_output_mw() == OUTPUT_A);
        assert!(state.containment_reduction() == CONTAINMENT);
        assert!(!state.online());
        let grid = power_grid::power_grid(&e);
        assert!(grid.capacity_mw() == 0);
        assert!(grid.last_settled_ms() == 5_000);
        ts::return_shared(e);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun register_by_non_admin_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register_as(&mut scenario, OWNER, entity_id, GEN_A, OUTPUT_A, &clock);

    abort
}

#[test, expected_failure(abort_code = generator::EComponentMissing)]
fun register_without_marker_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register(&mut scenario, entity_id, 999, OUTPUT_A, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EGeneratorAlreadyRegistered)]
fun register_twice_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);

    abort
}

#[test]
fun online_and_offline_sum_capacity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register_and_online(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    assert!(event::events_by_type<GeneratorToggled>().length() == 1);
    assert!(event::events_by_type<CapacityChanged>().length() == 1);
    register_and_online(&mut scenario, entity_id, GEN_B, OUTPUT_B, &clock);
    let (total, _) = capacity(&mut scenario, entity_id);
    assert!(total == OUTPUT_A + OUTPUT_B);

    owner_runs_operation(&mut scenario, entity_id, OP_OFFLINE, GEN_A, &clock);
    let (total, _) = capacity(&mut scenario, entity_id);
    assert!(total == OUTPUT_B);

    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        assert!(!power_grid::generator_state(&e, GEN_A).online());
        assert!(power_grid::generator_state(&e, GEN_B).online());
        ts::return_shared(e);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun effective_capacity_follows_power_switch() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register_and_online(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    let (total, effective) = capacity(&mut scenario, entity_id);
    assert!(total == OUTPUT_A);
    assert!(effective == 0);

    owner_runs_operation(&mut scenario, entity_id, OP_POWER_ON, 0, &clock);
    let (_, effective) = capacity(&mut scenario, entity_id);
    assert!(effective == OUTPUT_A);

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun settle_advances_on_toggle() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    clock.set_for_testing(7_000);
    owner_runs_operation(&mut scenario, entity_id, OP_ONLINE, GEN_A, &clock);
    ts::next_tx(&mut scenario, OWNER);
    {
        let e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
        assert!(power_grid::power_grid(&e).last_settled_ms() == 7_000);
        ts::return_shared(e);
    };

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun full_lifecycle_frees_grid_for_uninstall() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register_and_online(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    owner_runs_operation(&mut scenario, entity_id, OP_OFFLINE, GEN_A, &clock);
    unregister(&mut scenario, entity_id, GEN_A, &clock);
    uninstall_generator(&mut scenario, entity_id, GEN_A);
    assert!(event::events_by_type<GeneratorUninstalled>().length() == 1);
    uninstall_generator(&mut scenario, entity_id, GEN_B);

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let acl = take_acl(&scenario);
    assert!(!e.has_component(GEN_A));
    assert!(power_grid::power_grid(&e).generators().is_empty());
    let mut req = power_grid::uninstall(&mut e, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    ts::return_shared(acl);
    ts::return_shared(e);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EGeneratorNotRegistered)]
fun online_unregistered_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    owner_runs_operation(&mut scenario, entity_id, OP_ONLINE, GEN_A, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EGeneratorAlreadyOnline)]
fun online_twice_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register_and_online(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    owner_runs_operation(&mut scenario, entity_id, OP_ONLINE, GEN_A, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EGeneratorAlreadyOffline)]
fun offline_while_offline_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    owner_runs_operation(&mut scenario, entity_id, OP_OFFLINE, GEN_A, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EGeneratorOnline)]
fun unregister_while_online_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register_and_online(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    unregister(&mut scenario, entity_id, GEN_A, &clock);

    abort
}

#[test, expected_failure(abort_code = power_grid::EGeneratorStillRegistered)]
fun uninstall_while_registered_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    uninstall_generator(&mut scenario, entity_id, GEN_A);

    abort
}

#[test, expected_failure(abort_code = power_grid::EPowerSourcesPresent)]
fun grid_uninstall_with_registered_generator_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);

    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    let _req = power_grid::uninstall(&mut e, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = generator::EComponentMissing)]
fun state_without_generator_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = claim(&mut registry, &acl, 1, scenario.ctx());
    power_grid::generator_state(&e, GEN_A);

    abort
}

#[test]
fun online_multiple_generators() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);
    register(&mut scenario, entity_id, GEN_B, OUTPUT_B, &clock);
    owner_runs_operation(&mut scenario, entity_id, OP_ONLINE, GEN_A, &clock);
    owner_runs_operation(&mut scenario, entity_id, OP_ONLINE, GEN_B, &clock);
    let (total, _) = capacity(&mut scenario, entity_id);
    assert!(total == OUTPUT_A + OUTPUT_B);

    clock.destroy_for_testing();
    scenario.end();
}

/// Owner enables `check_generator` with `rule`, then runs it.
fun run_generator_check(scenario: &mut ts::Scenario, entity_id: ID, rule: Requirement) {
    enable(scenario, entity_id, b"check_generator", rule);

    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let mut req = e.interact(string::utf8(b"check_generator"), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    power_grid::assert_generator(&mut e, &mut req);
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

#[test]
fun generator_check_passes_when_offline() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);

    run_generator_check(
        &mut scenario,
        entity_id,
        power_grid::generator_requirement(
            GEN_A,
            false,
            option::some(OUTPUT_A),
            option::some(CONTAINMENT),
        ),
    );

    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun generator_check_passes_when_online() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    register_and_online(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);

    run_generator_check(
        &mut scenario,
        entity_id,
        power_grid::generator_requirement(GEN_A, true, option::none(), option::none()),
    );

    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = power_grid::EGenNotOnline)]
fun generator_check_aborts_when_online_required() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);

    run_generator_check(
        &mut scenario,
        entity_id,
        power_grid::generator_requirement(GEN_A, true, option::none(), option::none()),
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EOutputBelowMin)]
fun generator_check_aborts_when_output_below() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);

    run_generator_check(
        &mut scenario,
        entity_id,
        power_grid::generator_requirement(GEN_A, false, option::some(OUTPUT_A + 1), option::none()),
    );

    abort
}

#[test, expected_failure(abort_code = power_grid::EContainmentBelowMin)]
fun generator_check_aborts_when_containment_below() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let entity_id = setup_entity(&mut scenario, &clock);
    register(&mut scenario, entity_id, GEN_A, OUTPUT_A, &clock);

    run_generator_check(
        &mut scenario,
        entity_id,
        power_grid::generator_requirement(
            GEN_A,
            false,
            option::none(),
            option::some(CONTAINMENT + 1),
        ),
    );

    abort
}
