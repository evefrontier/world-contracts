/// Shared setup and helpers for power grid tests.
#[test_only]
module power::grid_scenario;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    request::Request,
    requirement::Requirement,
    test_helpers::{claim, take_acl, take_registry}
};
use power::{
    grid_fuel::{Self, FuelLoad},
    grid_generator,
    grid_load,
    power_grid::{Self, ModulePowerSpec}
};
use std::string;
use sui::{clock::Clock, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const GENERATOR_BASE: u64 = 101;
/// Base burn rate of every Generator, 1 unit per second at `SCALE`.
const BASE_FUEL_RATE: u64 = 10_000;
/// Component id of the Fuel source every `setup_entity` grid gets.
const FUEL_ID: u64 = 9_001;
/// Fuel capacity and starting fuel of that source, units at `SCALE`.
const FUEL_CAPACITY: u64 = 1_000_000_000;
const STARTING_FUEL: u64 = 500_000_000;
/// Fuel stats at `SCALE`: impulse 90, containment burden 14.
const IMPULSE: u64 = 900_000;
const BURDEN: u64 = 140_000;
const FUEL_TYPE: u64 = 7;

const OPERATE: vector<u8> = b"operate_grid";
const DEPOSIT_FUEL: vector<u8> = b"deposit_fuel";
const TEMP_ACTION: vector<u8> = b"temp_action";

/// A stand-in consuming module (Inventory, Thruster, ...).
public struct Consumer has store {}

public fun admin(): address { ADMIN }

public fun owner(): address { OWNER }

/// Component id of the `index`-th Generator from `setup_entity`.
public fun generator_id(index: u64): u64 { GENERATOR_BASE + index }

public fun fuel_source_id(): u64 { FUEL_ID }

public fun fuel_capacity(): u64 { FUEL_CAPACITY }

public fun starting_fuel(): u64 { STARTING_FUEL }

public fun impulse(): u64 { IMPULSE }

public fun burden(): u64 { BURDEN }

public fun fuel_type(): u64 { FUEL_TYPE }

/// Firm power for a module with no line loss and priority 0.
public fun firm_power(power_req: u64): ModulePowerSpec {
    power_grid::module_power_spec(power_req, power_grid::firm(), power_grid::power(), 0, 0)
}

/// Elastic power for a module with no line loss and priority 0.
public fun elastic_power(power_req: u64): ModulePowerSpec {
    power_grid::module_power_spec(power_req, power_grid::elastic(), power_grid::power(), 0, 0)
}

/// Share an entity with an installed, off grid, offline Generators of
/// `max_outputs_mw` with `containments`, and a Fuel source holding
/// `starting_fuel()`. Modules are installed afterwards with `install_module`.
public fun setup_entity(
    scenario: &mut ts::Scenario,
    max_outputs_mw: vector<u64>,
    containments: vector<u64>,
    clock: &Clock,
): ID {
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let mut entity = claim(&mut registry, &acl, 1, scenario.ctx());
    let mut req = power_grid::install(&mut entity, clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    max_outputs_mw.length().do!(|i| {
        let mut req = grid_generator::install(
            &mut entity,
            generator_id(i),
            option::none(),
            max_outputs_mw[i],
            containments[i],
            BASE_FUEL_RATE,
            clock,
            scenario.ctx(),
        );
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        entity.complete_request(req);
    });
    let mut req = grid_fuel::install(
        &mut entity,
        FUEL_ID,
        option::none(),
        FUEL_CAPACITY,
        clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let mut req = entity.mint_access(OWNER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let entity_id = entity.id();
    entity.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    let any = option::none();
    enable_owner_in_handler(
        scenario,
        entity_id,
        DEPOSIT_FUEL,
        power_grid::deposit_fuel_requirement(vector[], any, any, any, any),
    );
    deposit_fuel(scenario, entity_id, STARTING_FUEL, IMPULSE, BURDEN, clock);
    enable_owner_in_handler(scenario, entity_id, OPERATE, power_grid::operate_grid_requirement());
    entity_id
}

/// Install a `Consumer` under `module_id` with `spec`, connecting it to the grid.
public fun install_module(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    spec: ModulePowerSpec,
    clock: &Clock,
) {
    ts::next_tx(scenario, ADMIN);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = entity.install(
        module_id,
        option::none(),
        Consumer {},
        1,
        std::internal::permit<Consumer>(),
        scenario.ctx(),
    );
    grid_load::connect<Consumer>(
        &mut entity,
        module_id,
        spec,
        std::internal::permit<Consumer>(),
        clock,
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(entity);
}

/// Disconnect `Consumer`'s module from the grid without uninstalling it. Only
/// `Consumer`'s own package holds its permit, so tests call this in place of a
/// foreign module.
public fun disconnect_consumer(entity: &mut Entity, module_id: u64, clock: &Clock) {
    grid_load::disconnect<Consumer>(entity, module_id, std::internal::permit<Consumer>(), clock);
}

/// Uninstall the `Consumer` at `module_id`, leaving the grid.
public fun uninstall_module(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    clock: &Clock,
) {
    ts::next_tx(scenario, ADMIN);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let (consumer, mut req) = entity.uninstall<Consumer>(
        module_id,
        std::internal::permit<Consumer>(),
        scenario.ctx(),
    );
    let Consumer {} = consumer.unwrap(std::internal::permit<Consumer>());
    grid_load::disconnect<Consumer>(
        &mut entity,
        module_id,
        std::internal::permit<Consumer>(),
        clock,
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(entity);
}

public fun enable_admin(
    entity: &mut Entity,
    acl: &AdminACL,
    name: vector<u8>,
    target: Requirement,
    ctx: &mut TxContext,
) {
    let mut req = entity.enable_admin_action(string::utf8(name), action::new(vector[target]), ctx);
    admin_service::verify_admin(&mut req, acl, ctx);
    entity.complete_request(req);
}

/// OWNER enables an owner-gated action `name` with `requirements`.
fun enable_action_with(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    name: vector<u8>,
    requirements: vector<Requirement>,
) {
    ts::next_tx(scenario, OWNER);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let act = action::new(requirements);
    let mut req = entity.enable_action(string::utf8(name), act, scenario.ctx());
    entity.verify_owner(&mut req, &cap);
    entity.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(entity);
}

/// OWNER runs action `$name`, satisfying its requirement with `$handler`.
public macro fun as_owner(
    $scenario: &mut ts::Scenario,
    $entity_id: ID,
    $name: vector<u8>,
    $handler: |&mut Entity, &mut Request|,
) {
    let scenario = $scenario;
    ts::next_tx(scenario, owner());
    let mut entity = ts::take_shared_by_id<Entity>(scenario, $entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let mut req = entity.interact(string::utf8($name), scenario.ctx());
    $handler(&mut entity, &mut req);
    entity.verify_owner(&mut req, &cap);
    entity.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(entity);
}

/// Expose `name` as an owner action requiring only `target`. The owner's cap is
/// not part of the action: `deposit_fuel` requires it in its own handler.
public fun enable_owner_in_handler(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    name: vector<u8>,
    target: Requirement,
) {
    enable_action_with(scenario, entity_id, name, vector[target]);
}

/// Name of the temporary action `temp_action!` enables.
public fun temp_action_name(): vector<u8> { TEMP_ACTION }

/// Enable, run and disable a temporary owner action bundling `$target`.
public macro fun temp_action(
    $scenario: &mut ts::Scenario,
    $entity_id: ID,
    $target: Requirement,
    $handler: |&mut Entity, &mut Request|,
) {
    let scenario = $scenario;
    ts::next_tx(scenario, owner());
    let mut entity = ts::take_shared_by_id<Entity>(scenario, $entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let name = string::utf8(temp_action_name());
    let act = action::new(vector[access_cap::owner_requirement(), $target]);
    let mut req = entity.enable_action(name, act, scenario.ctx());
    entity.verify_owner(&mut req, &cap);
    entity.complete_request(req);
    let mut req = entity.interact(name, scenario.ctx());
    entity.verify_owner(&mut req, &cap);
    $handler(&mut entity, &mut req);
    entity.complete_request(req);
    let mut req = entity.disable_action(name, scenario.ctx());
    entity.verify_owner(&mut req, &cap);
    entity.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(entity);
}

/// Power the grid on or off.
public fun power(scenario: &mut ts::Scenario, entity_id: ID, on: bool, clock: &Clock) {
    as_owner!(
        scenario,
        entity_id,
        OPERATE,
        |entity, req| power_grid::set_power_grid(entity, req, on, clock),
    );
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
        |entity, req| grid_generator::set_generator(
            entity,
            req,
            generator_id(index),
            online,
            clock,
        ),
    );
}

/// Power the grid on and bring every one of its `count` Generators online.
public fun power_up(scenario: &mut ts::Scenario, entity_id: ID, count: u64, clock: &Clock) {
    power(scenario, entity_id, true, clock);
    count.do!(|i| set_generator(scenario, entity_id, i, true, clock));
}

/// OWNER sets `module_id`'s desired state.
public fun set_desired(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    module_id: u64,
    online: bool,
    clock: &Clock,
) {
    as_owner!(
        scenario,
        entity_id,
        OPERATE,
        |entity, req| grid_load::set_desired_state(entity, req, module_id, online, clock),
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
        |entity, req| grid_load::set_priority(entity, req, module_id, priority, clock),
    );
}

/// Install Fuel source `fuel_source_id` with `capacity` (not the default one).
public fun install_fuel(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    fuel_source_id: u64,
    capacity: u64,
    clock: &Clock,
) {
    ts::next_tx(scenario, ADMIN);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = grid_fuel::install(
        &mut entity,
        fuel_source_id,
        option::none(),
        capacity,
        clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(entity);
}

/// Uninstall Fuel source `fuel_source_id`, returning the fuel it carried out.
public fun uninstall_fuel(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    fuel_source_id: u64,
    clock: &Clock,
): FuelLoad {
    ts::next_tx(scenario, ADMIN);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let (mut req, load) = grid_fuel::uninstall(&mut entity, fuel_source_id, clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(entity);
    load
}

/// Install Fuel source `fuel_source_id` with `capacity`, holding `load`.
public fun install_fuel_with(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    fuel_source_id: u64,
    capacity: u64,
    load: FuelLoad,
    clock: &Clock,
) {
    ts::next_tx(scenario, ADMIN);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let mut req = grid_fuel::install_with_fuel(
        &mut entity,
        fuel_source_id,
        option::none(),
        capacity,
        load,
        clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    ts::return_shared(acl);
    ts::return_shared(entity);
}

/// Bridge `amount` of fuel with the given stats into the pool, through the
/// default (unrestricted) deposit action.
public fun deposit_fuel(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    amount: u64,
    impulse: u64,
    burden: u64,
    clock: &Clock,
) {
    deposit_fuel_via(scenario, entity_id, DEPOSIT_FUEL, FUEL_TYPE, amount, impulse, burden, clock);
}

/// OWNER signs owner action `name` to deposit fuel; ADMIN sponsors the gas.
public fun deposit_fuel_via(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    name: vector<u8>,
    fuel_type: u64,
    amount: u64,
    impulse: u64,
    burden: u64,
    clock: &Clock,
) {
    ensure_admin_sponsors(scenario);
    next_tx_owner_signs_admin_pays(scenario);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let acl = take_acl(scenario);
    let mut req = entity.interact(string::utf8(name), scenario.ctx());
    grid_fuel::deposit_fuel(&mut entity, &mut req, fuel_type, amount, impulse, burden, clock);
    entity.verify_owner(&mut req, &cap);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(acl);
    ts::return_shared(entity);
}

/// Put ADMIN on the sponsor list.
fun ensure_admin_sponsors(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    let mut acl = take_acl(scenario);
    if (!admin_service::is_sponsor(&acl, ADMIN)) {
        admin_service::add_sponsors(&mut acl, vector[ADMIN], scenario.ctx());
    };
    ts::return_shared(acl);
}

/// Next tx is signed by OWNER with ADMIN as gas sponsor.
fun next_tx_owner_signs_admin_pays(scenario: &mut ts::Scenario) {
    let epoch = scenario.ctx().epoch();
    let timestamp = scenario.ctx().epoch_timestamp_ms();
    let rgp = scenario.ctx().reference_gas_price();
    let builder = ts::ctx_builder_from_sender(OWNER)
        .set_epoch(epoch)
        .set_epoch_timestamp(timestamp)
        .set_reference_gas_price(rgp)
        .set_sponsor(ADMIN);
    ts::next_with_context(scenario, builder);
}

/// `(projected_fuel, effective_capacity_mw, used_mw, online module ids)` at `clock`.
public fun projected(
    scenario: &mut ts::Scenario,
    entity_id: ID,
    clock: &Clock,
): (u64, u64, u64, vector<u64>) {
    ts::next_tx(scenario, OWNER);
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let fuel_left = power_grid::projected_fuel(&entity, clock);
    let (capacity, used_mw, online) = power_grid::projected_status(&entity, clock);
    ts::return_shared(entity);
    (fuel_left, capacity, used_mw, online)
}

/// `module_id`'s live draw at `clock`.
public fun draw(scenario: &mut ts::Scenario, entity_id: ID, module_id: u64, clock: &Clock): u64 {
    ts::next_tx(scenario, OWNER);
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let draw = power_grid::module_draw(&entity, module_id, clock);
    ts::return_shared(entity);
    draw
}

/// `module_id`'s stored draw as of the last settle.
public fun stored_draw(scenario: &mut ts::Scenario, entity_id: ID, module_id: u64): u64 {
    ts::next_tx(scenario, OWNER);
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let draw = power_grid::power_grid(&entity)
        .module_state(module_id)
        .active_draw_at_last_settled();
    ts::return_shared(entity);
    draw
}

/// The grid's stored (settled) fuel quantity.
public fun settled_fuel(scenario: &mut ts::Scenario, entity_id: ID): u64 {
    ts::next_tx(scenario, OWNER);
    let entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let quantity = power_grid::power_grid(&entity).fuel_quantity_at_last_settled();
    ts::return_shared(entity);
    quantity
}

/// Owner runs a no-op mutation that settles the grid at `clock`.
public fun catch_up(scenario: &mut ts::Scenario, entity_id: ID, module_id: u64, clock: &Clock) {
    set_priority(scenario, entity_id, module_id, 0, clock);
}

/// Share an entity under `game_id` with an empty, off grid and no owner.
public fun setup_empty_grid(scenario: &mut ts::Scenario, game_id: u64, clock: &Clock): ID {
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let mut entity = claim(&mut registry, &acl, game_id, scenario.ctx());
    let mut req = power_grid::install(&mut entity, clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let entity_id = entity.id();
    entity.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    entity_id
}

/// `setup_empty_grid` under another `tenant`.
public fun setup_empty_grid_in_tenant(
    scenario: &mut ts::Scenario,
    game_id: u64,
    tenant: vector<u8>,
    clock: &Clock,
): ID {
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let (mut entity, mut req) = entity::new(&mut registry, game_id, string::utf8(tenant));
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let mut req = power_grid::install(&mut entity, clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let entity_id = entity.id();
    entity.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    entity_id
}

/// `sender` moves the `Consumer` at `module_id` from `from_id` to `to_id`, the
/// way a module package's migrate does. With `uninstall_first` false the
/// component stays on `from_id`, to exercise the guard.
public fun migrate_module(
    scenario: &mut ts::Scenario,
    sender: address,
    from_id: ID,
    to_id: ID,
    module_id: u64,
    uninstall_first: bool,
    clock: &Clock,
) {
    ts::next_tx(scenario, sender);
    let mut from = ts::take_shared_by_id<Entity>(scenario, from_id);
    let mut to = ts::take_shared_by_id<Entity>(scenario, to_id);
    let acl = take_acl(scenario);
    let from_req = if (uninstall_first) {
        let (consumer, req) = from.uninstall<Consumer>(
            module_id,
            std::internal::permit<Consumer>(),
            scenario.ctx(),
        );
        let Consumer {} = consumer.unwrap(std::internal::permit<Consumer>());
        option::some(req)
    } else option::none();
    let mut to_req = to.install(
        module_id,
        option::none(),
        Consumer {},
        1,
        std::internal::permit<Consumer>(),
        scenario.ctx(),
    );
    grid_load::migrate<Consumer>(
        &mut from,
        &mut to,
        module_id,
        std::internal::permit<Consumer>(),
        clock,
    );
    from_req.do!(|mut req| {
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        from.complete_request(req);
    });
    admin_service::verify_admin(&mut to_req, &acl, scenario.ctx());
    to.complete_request(to_req);
    ts::return_shared(acl);
    ts::return_shared(to);
    ts::return_shared(from);
}

/// `sender` moves Generator `generator_id` from `from_id` to `to_id`.
public fun migrate_generator(
    scenario: &mut ts::Scenario,
    sender: address,
    from_id: ID,
    to_id: ID,
    generator_id: u64,
    clock: &Clock,
) {
    migrate_with!(scenario, sender, from_id, to_id, |from, to, ctx| {
        grid_generator::migrate(from, to, generator_id, clock, ctx)
    });
}

/// `sender` moves Fuel source `fuel_source_id` from `from_id` to `to_id`.
public fun migrate_fuel(
    scenario: &mut ts::Scenario,
    sender: address,
    from_id: ID,
    to_id: ID,
    fuel_source_id: u64,
    clock: &Clock,
) {
    migrate_with!(scenario, sender, from_id, to_id, |from, to, ctx| {
        grid_fuel::migrate(from, to, fuel_source_id, clock, ctx)
    });
}

macro fun migrate_with(
    $scenario: &mut ts::Scenario,
    $sender: address,
    $from_id: ID,
    $to_id: ID,
    $migrate: |&mut Entity, &mut Entity, &mut TxContext| -> (Request, Request),
) {
    let scenario = $scenario;
    ts::next_tx(scenario, $sender);
    let mut from = ts::take_shared_by_id<Entity>(scenario, $from_id);
    let mut to = ts::take_shared_by_id<Entity>(scenario, $to_id);
    let acl = take_acl(scenario);
    let (mut from_req, mut to_req) = $migrate(&mut from, &mut to, scenario.ctx());
    admin_service::verify_admin(&mut from_req, &acl, scenario.ctx());
    from.complete_request(from_req);
    admin_service::verify_admin(&mut to_req, &acl, scenario.ctx());
    to.complete_request(to_req);
    ts::return_shared(acl);
    ts::return_shared(to);
    ts::return_shared(from);
}
