/// Shared setup and helpers for power grid tests.
#[test_only]
module power::grid_scenario;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::Entity,
    request::Request,
    requirement::Requirement,
    test_helpers::{claim, take_acl, take_registry}
};
use power::{generator, power_grid::{Self, Reservation}};
use std::string;
use sui::{clock::Clock, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const GENERATOR_BASE: u64 = 101;
const CONTAINMENT: u64 = 10;

const MANAGE: vector<u8> = b"manage_generator";
const MANAGE_MODULE: vector<u8> = b"manage_module";
const OPERATE: vector<u8> = b"operate_grid";
const TEMP_ACTION: vector<u8> = b"temp_action";

/// A stand-in consuming module (Inventory, Thruster, ...).
public struct Consumer has store {}

public fun admin(): address { ADMIN }

public fun owner(): address { OWNER }

/// Component id of the `index`-th Generator from `setup_entity`.
public fun generator_id(index: u64): u64 { GENERATOR_BASE + index }

/// Share an entity with an off grid, offline Generators of `max_outputs_mw`, and
/// unconnected consumer `modules`.
public fun setup_entity(
    scenario: &mut ts::Scenario,
    max_outputs_mw: vector<u64>,
    modules: vector<u64>,
    clock: &Clock,
): ID {
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut req = power_grid::install(&mut e, clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    max_outputs_mw.length().do!(|i| {
        let mut req = generator::install(&mut e, generator_id(i), option::none(), scenario.ctx());
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);
    });
    modules.do_ref!(|id| install_consumer(&mut e, &acl, *id, scenario.ctx()));
    enable_admin(&mut e, &acl, MANAGE, power_grid::manage_generator_requirement(), scenario.ctx());
    enable_admin(
        &mut e,
        &acl,
        MANAGE_MODULE,
        power_grid::manage_module_requirement(),
        scenario.ctx(),
    );
    let mut req = e.mint_access(OWNER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    let entity_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    max_outputs_mw.length().do!(|i| {
        let mut req = e.interact(string::utf8(MANAGE), scenario.ctx());
        power_grid::register_generator(
            &mut e,
            &mut req,
            generator_id(i),
            max_outputs_mw[i],
            CONTAINMENT,
            clock,
        );
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);
    });
    ts::return_shared(acl);
    ts::return_shared(e);

    enable(scenario, entity_id, OPERATE, power_grid::operate_grid_requirement());
    entity_id
}

/// Install a `Consumer` component under `component_id`.
public fun install_consumer(
    e: &mut Entity,
    acl: &AdminACL,
    component_id: u64,
    ctx: &mut TxContext,
) {
    let mut req = e.install(
        component_id,
        option::none(),
        Consumer {},
        1,
        std::internal::permit<Consumer>(),
        ctx,
    );
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
}

public fun enable_admin(
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

/// OWNER enables an owner-gated action `name` bundling `target`.
public fun enable(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    name: vector<u8>,
    target: Requirement,
) {
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

/// OWNER runs action `name`, satisfying the grid requirement with `$handler`.
public macro fun as_owner(
    $scenario: &mut ts::Scenario,
    $entity_id: ID,
    $name: vector<u8>,
    $handler: |&mut Entity, &mut Request|,
) {
    let scenario = $scenario;
    ts::next_tx(scenario, owner());
    let mut e = ts::take_shared_by_id<Entity>(scenario, $entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let mut req = e.interact(string::utf8($name), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    $handler(&mut e, &mut req);
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

/// Enable, run and disable a temporary owner action bundling `$target`.
public macro fun temp_action(
    $scenario: &mut ts::Scenario,
    $entity_id: ID,
    $target: Requirement,
    $handler: |&mut Entity, &mut Request|,
) {
    let scenario = $scenario;
    ts::next_tx(scenario, owner());
    let mut e = ts::take_shared_by_id<Entity>(scenario, $entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let name = string::utf8(temp_action_name());
    let act = action::new(vector[access_cap::owner_requirement(), $target]);
    let mut req = e.enable_action(name, act, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);
    let mut req = e.interact(name, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    $handler(&mut e, &mut req);
    e.complete_request(req);
    let mut req = e.disable_action(name, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

public fun temp_action_name(): vector<u8> { TEMP_ACTION }

public fun power(scenario: &mut ts::Scenario, entity_id: ID, on: bool, clock: &Clock) {
    as_owner!(scenario, entity_id, OPERATE, |e, req| power_grid::set_power_grid(e, req, on, clock));
}

/// Bring the `index`-th Generator online or offline.
public fun set_generator(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    index: u64,
    online: bool,
    clock: &Clock,
) {
    as_owner!(
        scenario,
        entity_id,
        OPERATE,
        |e, req| power_grid::set_generator(e, req, generator_id(index), online, clock),
    );
}

/// Power the grid on and bring every one of its `count` Generators online.
public fun power_up(scenario: &mut ts::Scenario, entity_id: ID, count: u64, clock: &Clock) {
    power(scenario, entity_id, true, clock);
    count.do!(|i| set_generator(scenario, entity_id, i, true, clock));
}

/// `signer` runs `manage_module` with `$handler`; the admin requirement is
/// verified against `signer`.
macro fun as_admin(
    $scenario: &mut ts::Scenario,
    $signer: address,
    $entity_id: ID,
    $handler: |&mut Entity, &mut Request|,
) {
    let scenario = $scenario;
    ts::next_tx(scenario, $signer);
    let mut e = ts::take_shared_by_id<Entity>(scenario, $entity_id);
    let acl = take_acl(scenario);
    let mut req = e.interact(string::utf8(MANAGE_MODULE), scenario.ctx());
    $handler(&mut e, &mut req);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(e);
}

/// `signer` connects `module_id` with `line_loss` (priority group 0).
public fun connect_module_as(
    scenario: &mut ts::Scenario,
    signer: address,
    entity_id: ID,
    module_id: u64,
    line_loss: u64,
    clock: &Clock,
) {
    as_admin!(
        scenario,
        signer,
        entity_id,
        |e, req| power_grid::connect_module(e, req, module_id, line_loss, clock),
    );
}

public fun connect_module(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    line_loss: u64,
    clock: &Clock,
) {
    connect_module_as(scenario, ADMIN, entity_id, module_id, line_loss, clock);
}

public fun disconnect_module(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    clock: &Clock,
) {
    as_admin!(
        scenario,
        ADMIN,
        entity_id,
        |e, req| power_grid::disconnect_module(e, req, module_id, clock),
    );
}

/// OWNER moves `module_id` into a priority group.
public fun set_priority(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    priority: u64,
    clock: &Clock,
) {
    as_owner!(
        scenario,
        entity_id,
        OPERATE,
        |e, req| power_grid::set_priority(e, req, module_id, priority, clock),
    );
}

/// Connect `module_id`, then move it into `priority` when that group is not 0.
public fun connect(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    line_loss: u64,
    priority: u64,
    clock: &Clock,
) {
    connect_module(scenario, entity_id, module_id, line_loss, clock);
    if (priority != 0) set_priority(scenario, entity_id, module_id, priority, clock);
}

public fun reserve_firm(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    draw: u64,
    clock: &Clock,
) {
    as_owner!(
        scenario,
        entity_id,
        OPERATE,
        |e, req| power_grid::reserve(e, req, module_id, draw, power_grid::firm(), clock),
    );
}

public fun reserve_elastic(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    draw: u64,
    clock: &Clock,
) {
    as_owner!(
        scenario,
        entity_id,
        OPERATE,
        |e, req| power_grid::reserve(e, req, module_id, draw, power_grid::elastic(), clock),
    );
}

public fun release(scenario: &mut ts::Scenario, entity_id: ID, module_id: u64, clock: &Clock) {
    as_owner!(scenario, entity_id, OPERATE, |e, req| power_grid::release(e, req, module_id, clock));
}

/// Release every reservation in priority group `priority`.
public fun release_priority(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    priority: u64,
    clock: &Clock,
) {
    as_owner!(
        scenario,
        entity_id,
        OPERATE,
        |e, req| power_grid::release_priority(e, req, priority, clock),
    );
}

public fun used(scenario: &mut ts::Scenario, entity_id: ID): u64 {
    ts::next_tx(scenario, OWNER);
    let e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let used_mw = power_grid::power_grid(&e).used_mw();
    ts::return_shared(e);
    used_mw
}

public fun reservation_of(scenario: &mut ts::Scenario, entity_id: ID, module_id: u64): Reservation {
    ts::next_tx(scenario, OWNER);
    let e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let reservation = power_grid::power_grid(&e)
        .module_state(module_id)
        .reservation()
        .destroy_some();
    ts::return_shared(e);
    reservation
}

/// `module_id`'s current `active_draw`.
public fun active(scenario: &mut ts::Scenario, entity_id: ID, module_id: u64): u64 {
    reservation_of(scenario, entity_id, module_id).active_draw()
}

public fun has_reservation(scenario: &mut ts::Scenario, entity_id: ID, module_id: u64): bool {
    ts::next_tx(scenario, OWNER);
    let e = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let reserved = power_grid::power_grid(&e).has_reservation(module_id);
    ts::return_shared(e);
    reserved
}
