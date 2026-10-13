#[test_only]
module inventory::inventory_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    docking,
    entity::{Self, Entity},
    object_registry::ObjectRegistry,
    request::Request,
    requirement::Requirement,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use inventory::{inventory, item::{Self, Item}};
use power::{grid_fuel, grid_generator, grid_load, power_grid};
use std::string::{Self, String};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const PLAYER: address = @0xC;
const FUEL: u64 = 88834;
const LENS: u64 = 55;
const VOL: u64 = 2;
const MODULE_ID: u64 = 0x51;
const MODULE_ID_2: u64 = 0x52;
const TYPE_ID: u64 = 1;
/// Firm draw stored on the inventory at install. `OnlineRequirement` asks for this.
const DRAW: u64 = 1;
const GENERATOR_ID: u64 = 0x71;
const FUEL_BAY_ID: u64 = 0x72;

fun unit_name(): String { string::utf8(b"SU-01") }

fun ship_id(): ID { object::id_from_address(@0x5) }

fun character_id(): ID { object::id_from_address(@0x8) }

/// Enable an action gated by the target's owner plus `item_req`. The owner
/// signs with their `AccessCap` (enable is owner-gated); the same cap also
/// satisfies the `Owner` requirement baked into the action itself, so only
/// that owner (or whoever they later hand items to via a composite action)
/// can ever move items through it.
fun enable(
    e: &mut Entity,
    name: vector<u8>,
    item_req: Requirement,
    owner_cap: &AccessCap,
    ctx: &mut TxContext,
) {
    let act = action::new(vector[access_cap::owner_requirement(), item_req]);
    let mut req = e.enable_action(string::utf8(name), act, ctx);
    access_cap::verify(&mut req, owner_cap);
    e.complete_request(req);
}

/// Claim an entity, install an inventory, and mint a transferable owner cap
/// to `owner`. Admin-only; the owner configures actions separately.
fun build_entity_with_inventory(
    scenario: &mut ts::Scenario,
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    id: u64,
    owner: address,
    capacity: u64,
): Entity {
    let mut e = claim(registry, acl, id, scenario.ctx());
    install_inventory(
        scenario,
        &mut e,
        acl,
        MODULE_ID,
        TYPE_ID,
        option::some(unit_name()),
        capacity,
    );

    let mut req = e.mint_access(owner, true, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    e
}

/// Install the power grid on `e` if it is not there yet. Admin-only.
fun install_grid(scenario: &mut ts::Scenario, e: &mut Entity, acl: &AdminACL) {
    if (e.has_component(power_grid::component_id())) return;
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = power_grid::install(e, &clock, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    clock.destroy_for_testing();
}

/// Install the grid if needed, then the Inventory under `component_id`, connected
/// to the grid. Admin-only.
fun install_inventory(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    acl: &AdminACL,
    component_id: u64,
    type_id: u64,
    name: Option<String>,
    capacity: u64,
) {
    install_grid(scenario, e, acl);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = inventory::install(
        e,
        component_id,
        type_id,
        name,
        capacity,
        DRAW,
        power_grid::firm(),
        power_grid::power(),
        0,
        0,
        &clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    clock.destroy_for_testing();
}

/// Uninstall the Inventory under `component_id`, leaving the grid. Admin-only.
fun uninstall_inventory(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    acl: &AdminACL,
    component_id: u64,
) {
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = inventory::uninstall(e, component_id, &clock, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    clock.destroy_for_testing();
}

/// Claim a bare entity (no inventory) and mint a soulbound cap to `owner`.
/// Used to give a player a real `AccessCap` that does not own the entity
/// under test.
fun claim_with_cap(
    scenario: &mut ts::Scenario,
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    id: u64,
    owner: address,
): Entity {
    let mut e = claim(registry, acl, id, scenario.ctx());
    let mut req = e.mint_access(owner, false, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    e
}

/// Owner enables `act` on the shared entity, signing with their cap. Runs in its
/// own `owner` tx and leaves the entity shared.
fun owner_enable(
    scenario: &mut ts::Scenario,
    e_id: ID,
    owner: address,
    name: vector<u8>,
    act: action::Action,
) {
    ts::next_tx(scenario, owner);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let mut req = e.enable_action(string::utf8(name), act, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

/// Owner exposes the standard bridge/deposit/withdraw action set on the shared
/// entity. A bridge call is signed by the owner. The gas sponsor must be on
/// `AdminACL`. Cross-owner movement happens only through an owner-configured
/// composite action, like `swap` below.
fun configure_default_actions(scenario: &mut ts::Scenario, e_id: ID, owner: address) {
    ts::next_tx(scenario, owner);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let any = option::none();
    enable(
        &mut e,
        b"bridge_in",
        inventory::bridge_in_requirement(MODULE_ID, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"bridge_out",
        inventory::bridge_out_requirement(MODULE_ID, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"deposit",
        inventory::deposit_requirement(MODULE_ID, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"withdraw",
        inventory::withdraw_requirement(MODULE_ID, any, any, any),
        &cap,
        scenario.ctx(),
    );
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

// === Interaction helpers (caller supplies its own cap and the action name) ===

/// Put `ADMIN` on the sponsor list.
fun ensure_admin_sponsors(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    let mut acl = take_acl(scenario);
    if (!admin_service::is_sponsor(&acl, ADMIN)) {
        admin_service::add_sponsors(&mut acl, vector[ADMIN], scenario.ctx());
    };
    ts::return_shared(acl);
}

/// Cap stays with `owner`.
fun next_tx_owner_signs_admin_pays(scenario: &mut ts::Scenario, owner: address) {
    let epoch = scenario.ctx().epoch();
    let timestamp = scenario.ctx().epoch_timestamp_ms();
    let rgp = scenario.ctx().reference_gas_price();
    let builder = ts::ctx_builder_from_sender(owner)
        .set_epoch(epoch)
        .set_epoch_timestamp(timestamp)
        .set_reference_gas_price(rgp)
        .set_sponsor(ADMIN);
    ts::next_with_context(scenario, builder);
}

/// Owner signs a bridge. The cap stays with the owner. `AdminACL` is shared.
/// The gas sponsor is `ADMIN`.
fun bridge_in(
    scenario: &mut ts::Scenario,
    e_id: ID,
    owner: address,
    action: vector<u8>,
    type_id: u64,
    qty: u64,
    vol: u64,
) {
    ensure_admin_sponsors(scenario);
    next_tx_owner_signs_admin_pays(scenario, owner);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let acl = take_acl(scenario);
    let mut req = e.interact(string::utf8(action), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, type_id, qty, vol);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    grid_load::assert_online(&mut e, &mut req, &clock);
    clock.destroy_for_testing();
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(acl);
    ts::return_shared(e);
}

fun bridge_out(
    scenario: &mut ts::Scenario,
    e_id: ID,
    owner: address,
    action: vector<u8>,
    type_id: u64,
    qty: u64,
) {
    ensure_admin_sponsors(scenario);
    next_tx_owner_signs_admin_pays(scenario, owner);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let acl = take_acl(scenario);
    let mut req = e.interact(string::utf8(action), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    inventory::chain_item_to_game_inventory(&mut e, &mut req, type_id, qty);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    grid_load::assert_online(&mut e, &mut req, &clock);
    clock.destroy_for_testing();
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(acl);
    ts::return_shared(e);
}

fun deposit(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    action: vector<u8>,
    item: Item,
) {
    let mut req = e.interact(string::utf8(action), scenario.ctx());
    access_cap::verify(&mut req, cap);
    inventory::deposit(e, &mut req, item, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    grid_load::assert_online(e, &mut req, &clock);
    clock.destroy_for_testing();
    e.complete_request(req);
}

fun withdraw(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    action: vector<u8>,
    type_id: u64,
    qty: u64,
): Item {
    let mut req = e.interact(string::utf8(action), scenario.ctx());
    access_cap::verify(&mut req, cap);
    let item = inventory::withdraw(e, &mut req, type_id, qty, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    grid_load::assert_online(e, &mut req, &clock);
    clock.destroy_for_testing();
    e.complete_request(req);
    item
}

/// Install a generator and fuel bay, fill the pool, and grant `MODULE_ID`.
fun power_inventory(scenario: &mut ts::Scenario, entity_id: ID, owner: address) {
    ts::next_tx(scenario, ADMIN);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = grid_generator::install(
        &mut entity,
        GENERATOR_ID,
        option::none(),
        10,
        10,
        1,
        &clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let mut req = grid_fuel::install(
        &mut entity,
        FUEL_BAY_ID,
        option::none(),
        1_000,
        &clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(entity);

    ts::next_tx(scenario, owner);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let any = option::none();
    enable_owner_in_handler(
        &mut entity,
        b"operate_grid",
        power_grid::operate_grid_requirement(),
        &cap,
        scenario.ctx(),
    );
    enable_owner_in_handler(
        &mut entity,
        b"deposit_fuel",
        power_grid::deposit_fuel_requirement(vector[], any, any, any, any),
        &cap,
        scenario.ctx(),
    );
    ts::return_to_sender(scenario, cap);
    ts::return_shared(entity);

    ensure_admin_sponsors(scenario);
    next_tx_owner_signs_admin_pays(scenario, owner);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let acl = take_acl(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = entity.interact(string::utf8(b"deposit_fuel"), scenario.ctx());
    grid_fuel::deposit_fuel(&mut entity, &mut req, 7, 100, 90, 14, &clock);
    access_cap::verify(&mut req, &cap);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    clock.destroy_for_testing();
    ts::return_to_sender(scenario, cap);
    ts::return_shared(acl);
    ts::return_shared(entity);

    run_operate_grid!(scenario, entity_id, owner, |entity, req, clock| {
        power_grid::set_power_grid(entity, req, true, clock);
    });
    run_operate_grid!(scenario, entity_id, owner, |entity, req, clock| {
        grid_generator::set_generator(entity, req, GENERATOR_ID, true, clock);
    });
    run_operate_grid!(scenario, entity_id, owner, |entity, req, clock| {
        grid_load::set_desired_state(entity, req, MODULE_ID, true, clock);
    });
}

/// Owner action whose only requirement is `requirement`. The handler pushes the owner check.
fun enable_owner_in_handler(
    entity: &mut Entity,
    name: vector<u8>,
    requirement: Requirement,
    owner_cap: &AccessCap,
    ctx: &mut TxContext,
) {
    let act = action::new(vector[requirement]);
    let mut req = entity.enable_action(string::utf8(name), act, ctx);
    access_cap::verify(&mut req, owner_cap);
    entity.complete_request(req);
}

fun set_desired(scenario: &mut ts::Scenario, entity_id: ID, owner: address, online: bool) {
    ts::next_tx(scenario, owner);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = entity.interact(string::utf8(b"operate_grid"), scenario.ctx());
    grid_load::set_desired_state(&mut entity, &mut req, MODULE_ID, online, &clock);
    access_cap::verify(&mut req, &cap);
    entity.complete_request(req);
    clock.destroy_for_testing();
    ts::return_to_sender(scenario, cap);
    ts::return_shared(entity);
}

macro fun run_operate_grid(
    $scenario: &mut ts::Scenario,
    $entity_id: ID,
    $owner: address,
    $handler: |&mut Entity, &mut Request, &Clock|,
) {
    let scenario = $scenario;
    ts::next_tx(scenario, $owner);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, $entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = entity.interact(string::utf8(b"operate_grid"), scenario.ctx());
    $handler(&mut entity, &mut req, &clock);
    access_cap::verify(&mut req, &cap);
    entity.complete_request(req);
    clock.destroy_for_testing();
    ts::return_to_sender(scenario, cap);
    ts::return_shared(entity);
}

// === View helpers ===

fun inv(e: &Entity): &inventory::Inventory {
    inventory::inventory(e, MODULE_ID)
}

#[test]
fun install_reports_component_and_capacity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);

    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    assert!(e.has_component(MODULE_ID));
    assert!(inventory::type_id(inv(&e)) == TYPE_ID);
    assert!(inv(&e).capacity() == 1000);
    assert!(inv(&e).used() == 0);

    let installed = event::events_by_type<inventory::InventoryInstalled>();
    assert!(installed.length() == 1);
    let (entity_id, component_id, inventory_type_id, name, capacity) = inventory::installed_fields(
        &installed[0],
    );
    assert!(entity_id == e.id());
    assert!(component_id == MODULE_ID);
    assert!(inventory_type_id == TYPE_ID);
    assert!(name == option::some(unit_name()));
    assert!(capacity == 1000);

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun install_two_inventories_on_one_entity() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    install_inventory(
        &mut scenario,
        &mut e,
        &acl,
        MODULE_ID,
        TYPE_ID,
        option::some(unit_name()),
        1000,
    );

    install_inventory(
        &mut scenario,
        &mut e,
        &acl,
        MODULE_ID_2,
        TYPE_ID,
        option::some(string::utf8(b"SU-02")),
        500,
    );

    assert!(e.has_component(MODULE_ID));
    assert!(e.has_component(MODULE_ID_2));
    assert!(inventory::inventory(&e, MODULE_ID).capacity() == 1000);
    assert!(inventory::inventory(&e, MODULE_ID_2).capacity() == 500);

    let installed = event::events_by_type<inventory::InventoryInstalled>();
    assert!(installed.length() == 2);
    let (entity_a, component_a, _, _, capacity_a) = inventory::installed_fields(&installed[0]);
    let (entity_b, component_b, _, _, capacity_b) = inventory::installed_fields(&installed[1]);
    assert!(entity_a == entity_b);
    assert!(component_a == MODULE_ID && capacity_a == 1000);
    assert!(component_b == MODULE_ID_2 && capacity_b == 500);

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun owner_interaction_inventory() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);
    power_inventory(&mut scenario, e_id, OWNER);

    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", FUEL, 100, VOL); // used 200, bal 100
    bridge_out(&mut scenario, e_id, OWNER, b"bridge_out", FUEL, 50); // used 100, bal 50

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    docking::dock_for_testing(ship_id(), e_id, character_id(), scenario.ctx());
    let item = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 20); // used 60, bal 30
    assert!(item.quantity() == 20);
    deposit(&mut scenario, &mut e, &cap, b"deposit", item); // used 100, bal 50

    assert!(inv(&e).used() == 100);
    assert!(inv(&e).items().balance(FUEL) == 50);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = access_cap::ENotOwner)]
fun bridge_in_by_non_owner_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    // PLAYER holds a real cap, just not one for this entity.
    let other = claim_with_cap(&mut scenario, &mut registry, &acl, 2, PLAYER);
    e.share();
    other.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);

    ts::next_tx(&mut scenario, PLAYER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let player_cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    access_cap::verify(&mut req, &player_cap);

    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedSponsor)]
fun bridge_in_by_owner_without_sponsor_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let acl = take_acl(&scenario);
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, FUEL, 10, VOL);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());

    abort
}

#[test]
fun swap_moves_items_between_two_entities() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    // A owns entity_a (offers LENS for FUEL). B owns entity_b (pays with FUEL).
    let player_a = OWNER;
    let player_b = PLAYER;

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let entity_a = build_entity_with_inventory(
        &mut scenario,
        &mut registry,
        &acl,
        1,
        player_a,
        1000,
    );
    let entity_a_id = entity_a.id();
    let entity_b = build_entity_with_inventory(
        &mut scenario,
        &mut registry,
        &acl,
        2,
        player_b,
        1000,
    );
    let entity_b_id = entity_b.id();
    entity_a.share();
    entity_b.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    configure_default_actions(&mut scenario, entity_a_id, player_a);
    configure_default_actions(&mut scenario, entity_b_id, player_b);
    power_inventory(&mut scenario, entity_a_id, player_a);
    power_inventory(&mut scenario, entity_b_id, player_b);

    // Admin bridges a LENS onto entity_a. The call needs the entity cap and an admin.
    bridge_in(&mut scenario, entity_a_id, player_a, b"bridge_in", LENS, 1, VOL);

    // A opens a public swap on entity_a: deposit one FUEL, withdraw the LENS.
    owner_enable(
        &mut scenario,
        entity_a_id,
        player_a,
        b"swap",
        action::new(vector[
            inventory::deposit_requirement(
                MODULE_ID,
                option::some(FUEL),
                option::some(1),
                option::some(1),
            ),
            inventory::withdraw_requirement(
                MODULE_ID,
                option::some(LENS),
                option::some(1),
                option::some(1),
            ),
        ]),
    );

    // Admin bridges a FUEL onto entity_b. The call needs the entity cap and an admin.
    bridge_in(&mut scenario, entity_b_id, player_b, b"bridge_in", FUEL, 1, VOL);

    // B's ship (entity_b) docks at entity_a and swaps in one tx.
    ts::next_tx(&mut scenario, player_b);
    docking::dock_for_testing(entity_b_id, entity_a_id, character_id(), scenario.ctx());
    let mut entity_b = ts::take_shared_by_id<Entity>(&scenario, entity_b_id);
    let cap_b = ts::take_from_sender<AccessCap>(&scenario);
    let fuel = withdraw(&mut scenario, &mut entity_b, &cap_b, b"withdraw", FUEL, 1);

    let mut entity_a = ts::take_shared_by_id<Entity>(&scenario, entity_a_id);
    let mut req = entity_a.interact(string::utf8(b"swap"), scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    inventory::deposit(&mut entity_a, &mut req, fuel, scenario.ctx());
    grid_load::assert_online(&mut entity_a, &mut req, &clock);
    let lens = inventory::withdraw(&mut entity_a, &mut req, LENS, 1, scenario.ctx());
    grid_load::assert_online(&mut entity_a, &mut req, &clock);
    clock.destroy_for_testing();
    entity_a.complete_request(req);

    deposit(&mut scenario, &mut entity_b, &cap_b, b"deposit", lens);
    ts::return_to_sender(&scenario, cap_b);

    assert!(inv(&entity_a).items().balance(FUEL) == 1);
    assert!(inv(&entity_a).items().balance(LENS) == 0);
    assert!(inv(&entity_b).items().balance(LENS) == 1);
    assert!(inv(&entity_b).items().balance(FUEL) == 0);

    ts::return_shared(entity_a);
    ts::return_shared(entity_b);
    scenario.end();
}

#[test, expected_failure(abort_code = inventory::EOverCapacity)]
fun bridge_in_over_capacity_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 100);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, FUEL, 60, VOL); // 120 > 100

    abort
}

#[test, expected_failure(abort_code = inventory::EItemTypeNotAllowed)]
fun bridge_in_wrong_type_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    owner_enable(
        &mut scenario,
        e_id,
        OWNER,
        b"bridge_fuel",
        action::new(vector[
            access_cap::owner_requirement(),
            inventory::bridge_in_requirement(
                MODULE_ID,
                option::some(FUEL),
                option::none(),
                option::none(),
            ),
        ]),
    );

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.interact(string::utf8(b"bridge_fuel"), scenario.ctx());
    access_cap::verify(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, FUEL + 1, 10, VOL);

    abort
}

#[test]
fun uninstall_burns_inventory() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(registry);
    ts::return_shared(acl);
    configure_default_actions(&mut scenario, e_id, OWNER);
    power_inventory(&mut scenario, e_id, OWNER);

    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", FUEL, 100, VOL);

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let acl = take_acl(&scenario);
    uninstall_inventory(&mut scenario, &mut e, &acl, MODULE_ID);
    assert!(!e.has_component(MODULE_ID));

    // The marker carries the whole `used` total and arrives ahead of the burns.
    let torn_down = event::events_by_type<inventory::InventoryUninstalled>();
    assert!(torn_down.length() == 1);
    let (entity_id, component_id, used_before) = inventory::uninstalled_fields(&torn_down[0]);
    assert!(entity_id == e_id && component_id == MODULE_ID);
    assert!(used_before == 200);
    assert!(event::events_by_type<item::ItemBurned>().length() == 1);

    ts::return_shared(acl);
    ts::return_shared(e);
    scenario.end();
}

#[test]
fun reinstall_opens_a_new_epoch_under_the_same_component_id() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(registry);
    ts::return_shared(acl);
    configure_default_actions(&mut scenario, e_id, OWNER);
    power_inventory(&mut scenario, e_id, OWNER);

    // First epoch: 100 FUEL at VOL each.
    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", FUEL, 100, VOL);
    ts::next_tx(&mut scenario, OWNER);
    let e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    assert!(inv(&e).used() == 200);
    ts::return_shared(e);

    // The seam: one tx closes the first epoch and opens the second under the
    // same key, so both events are the only thing telling them apart.
    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let acl = take_acl(&scenario);
    uninstall_inventory(&mut scenario, &mut e, &acl, MODULE_ID);

    install_inventory(
        &mut scenario,
        &mut e,
        &acl,
        MODULE_ID,
        TYPE_ID,
        option::some(string::utf8(b"SU-01b")),
        500,
    );

    let torn_down = event::events_by_type<inventory::InventoryUninstalled>();
    assert!(torn_down.length() == 1);
    let (torn_entity, torn_component, used_before) = inventory::uninstalled_fields(&torn_down[0]);
    assert!(torn_entity == e_id && torn_component == MODULE_ID);
    assert!(used_before == 200);

    let installed = event::events_by_type<inventory::InventoryInstalled>();
    assert!(installed.length() == 1);
    let (new_entity, new_component, _, _, capacity) = inventory::installed_fields(&installed[0]);
    assert!(new_entity == e_id && new_component == MODULE_ID);
    assert!(capacity == 500);

    assert!(inv(&e).capacity() == 500);
    assert!(inv(&e).used() == 0);
    assert!(inventory::balance_of(&e, MODULE_ID, FUEL) == 0);
    ts::return_shared(acl);
    ts::return_shared(e);

    // Reinstall connects desired-offline. Ask for the grant again before bridging.
    set_desired(&mut scenario, e_id, OWNER, true);

    // Second epoch: its own items, under the key the first one used. The FUEL
    // balance does not carry across.
    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", LENS, 50, VOL);
    ts::next_tx(&mut scenario, OWNER);
    let e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    assert!(inventory::balance_of(&e, MODULE_ID, LENS) == 50);
    assert!(inventory::balance_of(&e, MODULE_ID, FUEL) == 0);
    assert!(inv(&e).used() == 100);
    ts::return_shared(e);

    scenario.end();
}

#[test, expected_failure(abort_code = docking::ENoDocking)]
fun withdraw_without_docking_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);
    power_inventory(&mut scenario, e_id, OWNER);
    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", FUEL, 1, VOL);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let _item = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 1);

    abort
}

#[test, expected_failure(abort_code = grid_load::ENoGrant)]
fun withdraw_without_power_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);
    power_inventory(&mut scenario, e_id, OWNER);
    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", FUEL, 1, VOL);
    set_desired(&mut scenario, e_id, OWNER, false);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    docking::dock_for_testing(ship_id(), e_id, character_id(), scenario.ctx());
    let _item = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 1);

    abort
}

#[test]
fun attested_docking_allows_withdraw_and_deposit() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, ADMIN, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, ADMIN);
    power_inventory(&mut scenario, e_id, ADMIN);
    bridge_in(&mut scenario, e_id, ADMIN, b"bridge_in", FUEL, 1, VOL);

    ts::next_tx(&mut scenario, ADMIN);
    let acl = take_acl(&scenario);
    docking::attest(&acl, scenario.ctx());
    ts::return_shared(acl);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let item = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 1);
    deposit(&mut scenario, &mut e, &cap, b"deposit", item);
    assert!(inv(&e).items().balance(FUEL) == 1);
    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);

    scenario.end();
}

#[test, expected_failure(abort_code = docking::ENotDocked)]
fun withdraw_with_docking_of_another_pair_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);
    power_inventory(&mut scenario, e_id, OWNER);
    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", FUEL, 1, VOL);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    docking::dock_for_testing(
        ship_id(),
        object::id_from_address(@0x6),
        character_id(),
        scenario.ctx(),
    );
    let _item = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 1);

    abort
}

#[test, expected_failure(abort_code = docking::ENotDocked)]
fun deposit_at_an_entity_outside_the_docking_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let x = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let x_id = x.id();
    let z = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 2, PLAYER, 1000);
    let z_id = z.id();
    x.share();
    z.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, x_id, OWNER);
    configure_default_actions(&mut scenario, z_id, PLAYER);
    power_inventory(&mut scenario, x_id, OWNER);
    bridge_in(&mut scenario, x_id, OWNER, b"bridge_in", FUEL, 1, VOL);

    // X is docked at Y; Z is not part of the transaction's docking.
    ts::next_tx(&mut scenario, OWNER);
    let mut x = ts::take_shared_by_id<Entity>(&scenario, x_id);
    let mut z = ts::take_shared_by_id<Entity>(&scenario, z_id);
    let x_cap = ts::take_from_address<AccessCap>(&scenario, OWNER);
    let z_cap = ts::take_from_address<AccessCap>(&scenario, PLAYER);
    docking::dock_for_testing(x_id, ship_id(), character_id(), scenario.ctx());
    let fuel = withdraw(&mut scenario, &mut x, &x_cap, b"withdraw", FUEL, 1);
    deposit(&mut scenario, &mut z, &z_cap, b"deposit", fuel);

    abort
}

/// Installing the Inventory connects it to the grid. Uninstalling disconnects
/// it and leaves the grid installed.
#[test]
fun install_connects_and_uninstall_disconnects() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let entity_id = e.id();
    e.share();
    ts::return_shared(registry);
    ts::return_shared(acl);

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, entity_id);
    assert!(power_grid::power_grid(&e).is_module_connected(MODULE_ID));
    let acl = take_acl(&scenario);
    uninstall_inventory(&mut scenario, &mut e, &acl, MODULE_ID);
    assert!(!e.has_component(MODULE_ID));
    assert!(e.has_component(power_grid::component_id()));
    assert!(!power_grid::power_grid(&e).is_module_connected(MODULE_ID));
    ts::return_shared(acl);
    ts::return_shared(e);

    scenario.end();
}

/// The grid must be installed before an Inventory can connect to it.
#[test, expected_failure(abort_code = power_grid::EComponentMissing)]
fun install_without_grid_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    let _req = inventory::install(
        &mut e,
        MODULE_ID,
        TYPE_ID,
        option::some(unit_name()),
        1000,
        1,
        power_grid::firm(),
        power_grid::power(),
        0,
        0,
        &clock,
        scenario.ctx(),
    );

    abort
}
