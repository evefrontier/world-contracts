#[test_only]
module inventory::inventory_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    object_registry::ObjectRegistry,
    request::Request,
    requirement::Requirement,
    test_helpers::{claim, setup, take_acl, take_registry, tenant}
};
use creation::layout;
use inventory::{inventory, item::{Self, Item}};
use power::{grid_fuel, grid_generator, grid_load, grid_scenario, power_grid};
use std::string::{Self, String};
use sui::{clock::{Self, Clock}, event, test_scenario as ts};
use variant::variant::{Self, Variant, VariantKey, VariantRegistry};

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
const COMMAND_MODULE_ID: u64 = 0x73;

/// Stand-in Command Module the Shell sits in.
public struct CommandModule has store {}

fun unit_name(): String { string::utf8(b"SU-01") }

/// Key of the plain (variant 0) `type_id` item in the test tenant.
fun key_of(type_id: u64): VariantKey { variant::new_key(tenant(), type_id, 0) }

/// ID of the frozen plain `type_id` units record in `tenant`, registering it (and
/// the registry) on first use. Runs in its own `ADMIN` tx.
fun variant_for(scenario: &mut ts::Scenario, tenant: String, type_id: u64, unit_volume: u64): ID {
    ts::next_tx(scenario, ADMIN);
    if (!ts::has_most_recent_shared<VariantRegistry>()) {
        variant::init_for_testing(scenario.ctx());
        ts::next_tx(scenario, ADMIN);
    };
    let mut registry = ts::take_shared<VariantRegistry>(scenario);
    let key = variant::new_key(tenant, type_id, 0);
    if (!registry.exists(key)) {
        registry.register_for_testing(
            tenant,
            type_id,
            0,
            variant::units(),
            unit_volume,
            vector[],
            vector[],
            vector[],
        );
    };
    let id = object::id_from_address(registry.derive_id(key));
    ts::return_shared(registry);
    id
}

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
    e.verify_owner(&mut req, owner_cap);
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

/// Install the power grid on `e` if it is not there yet, with a Shell aboard so
/// it can be switched on. Admin-only.
fun install_grid(scenario: &mut ts::Scenario, e: &mut Entity, acl: &AdminACL) {
    if (e.has_component(power_grid::component_id())) return;
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = power_grid::install(e, &clock, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    clock.destroy_for_testing();
    let mut req = e.install(
        COMMAND_MODULE_ID,
        option::none(),
        CommandModule {},
        1,
        internal::permit<CommandModule>(),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    layout::install_with_shell_for_testing(e, acl, COMMAND_MODULE_ID, scenario.ctx());
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
    e.verify_owner(&mut req, &cap);
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
    let record_id = variant_for(scenario, tenant(), type_id, vol);
    bridge_in_record(scenario, e_id, owner, action, record_id, qty);
}

/// Bridge `qty` of the frozen variant `record_id` in through `action`.
fun bridge_in_record(
    scenario: &mut ts::Scenario,
    e_id: ID,
    owner: address,
    action: vector<u8>,
    record_id: ID,
    qty: u64,
) {
    ensure_admin_sponsors(scenario);
    next_tx_owner_signs_admin_pays(scenario, owner);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let acl = take_acl(scenario);
    let record = ts::take_immutable_by_id<Variant>(scenario, record_id);
    let mut req = e.interact(string::utf8(action), scenario.ctx());
    e.verify_owner(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, &record, qty);
    ts::return_immutable(record);
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
    e.verify_owner(&mut req, &cap);
    inventory::chain_item_to_game_inventory(&mut e, &mut req, key_of(type_id), qty);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    grid_load::assert_online(&mut e, &mut req, &clock);
    clock.destroy_for_testing();
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(acl);
    ts::return_shared(e);
}

/// Admin docks the shared `chaser_id` at the shared `target_id` (both sides), in its own tx.
fun dock_at(scenario: &mut ts::Scenario, target_id: ID, chaser_id: ID) {
    ts::next_tx(scenario, ADMIN);
    let mut target = ts::take_shared_by_id<Entity>(scenario, target_id);
    let mut chaser = ts::take_shared_by_id<Entity>(scenario, chaser_id);
    let acl = take_acl(scenario);
    let (mut target_req, mut chaser_req) = target.dock(&mut chaser);
    admin_service::verify_admin(&mut target_req, &acl, scenario.ctx());
    admin_service::verify_admin(&mut chaser_req, &acl, scenario.ctx());
    target.complete_request(target_req);
    chaser.complete_request(chaser_req);
    ts::return_shared(acl);
    ts::return_shared(chaser);
    ts::return_shared(target);
}

/// Admin undocks the shared `chaser_id` from the shared `target_id` (both sides), in its own tx.
fun undock_from(scenario: &mut ts::Scenario, target_id: ID, chaser_id: ID) {
    ts::next_tx(scenario, ADMIN);
    let mut target = ts::take_shared_by_id<Entity>(scenario, target_id);
    let mut chaser = ts::take_shared_by_id<Entity>(scenario, chaser_id);
    let acl = take_acl(scenario);
    let (mut target_req, mut chaser_req) = target.undock(&mut chaser);
    admin_service::verify_admin(&mut target_req, &acl, scenario.ctx());
    admin_service::verify_admin(&mut chaser_req, &acl, scenario.ctx());
    target.complete_request(target_req);
    chaser.complete_request(chaser_req);
    ts::return_shared(acl);
    ts::return_shared(chaser);
    ts::return_shared(target);
}

fun deposit(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    action: vector<u8>,
    item: Item,
) {
    let mut req = e.interact(string::utf8(action), scenario.ctx());
    e.verify_owner(&mut req, cap);
    inventory::deposit(e, &mut req, item);
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
    e.verify_owner(&mut req, cap);
    let item = inventory::withdraw(e, &mut req, key_of(type_id), qty, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    grid_load::assert_online(e, &mut req, &clock);
    clock.destroy_for_testing();
    e.complete_request(req);
    item
}

fun deposit_batch(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    action: vector<u8>,
    items: vector<Item>,
) {
    let mut req = e.interact(string::utf8(action), scenario.ctx());
    e.verify_owner(&mut req, cap);
    inventory::deposit_batch(e, &mut req, items);
    let clock = clock::create_for_testing(scenario.ctx());
    grid_load::assert_online(e, &mut req, &clock);
    clock.destroy_for_testing();
    e.complete_request(req);
}

fun withdraw_batch(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    action: vector<u8>,
    type_ids: vector<u64>,
    quantities: vector<u64>,
): vector<Item> {
    let mut req = e.interact(string::utf8(action), scenario.ctx());
    e.verify_owner(&mut req, cap);
    let keys = type_ids.map!(|type_id| key_of(type_id));
    let items = inventory::withdraw_batch(e, &mut req, keys, quantities, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    grid_load::assert_online(e, &mut req, &clock);
    clock.destroy_for_testing();
    e.complete_request(req);
    items
}

/// Install a generator and fuel bay, fuel the bay, and grant `MODULE_ID`.
fun power_inventory(scenario: &mut ts::Scenario, entity_id: ID, owner: address) {
    ts::next_tx(scenario, ADMIN);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let acl = take_acl(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = grid_generator::install(
        &mut entity,
        GENERATOR_ID,
        option::none(),
        7,
        vector[],
        10,
        1_000_000,
        50_000,
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
        0,
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

    let fuel_id = grid_scenario::fuel_variant(scenario, 7, 900_000, 140_000, 50_000, 0);
    ensure_admin_sponsors(scenario);
    next_tx_owner_signs_admin_pays(scenario, owner);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let acl = take_acl(scenario);
    let fuel = ts::take_immutable_by_id<Variant>(scenario, fuel_id);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = entity.interact(string::utf8(b"deposit_fuel"), scenario.ctx());
    grid_fuel::deposit_fuel(
        &mut entity,
        &mut req,
        FUEL_BAY_ID,
        &fuel,
        100 * grid_scenario::kg(),
        &clock,
    );
    ts::return_immutable(fuel);
    entity.verify_owner(&mut req, &cap);
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    clock.destroy_for_testing();
    ts::return_to_sender(scenario, cap);
    ts::return_shared(acl);
    ts::return_shared(entity);

    run_operate_grid!(scenario, entity_id, owner, |entity, req, clock| {
        grid_fuel::set_fuel_bay(entity, req, FUEL_BAY_ID, true, clock);
    });
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
    entity.verify_owner(&mut req, owner_cap);
    entity.complete_request(req);
}

fun set_desired(scenario: &mut ts::Scenario, entity_id: ID, owner: address, online: bool) {
    ts::next_tx(scenario, owner);
    let mut entity = ts::take_shared_by_id<Entity>(scenario, entity_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = entity.interact(string::utf8(b"operate_grid"), scenario.ctx());
    grid_load::set_desired_state(&mut entity, &mut req, MODULE_ID, online, &clock);
    entity.verify_owner(&mut req, &cap);
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
    entity.verify_owner(&mut req, &cap);
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
    let minted = event::events_by_type<item::ItemMinted>();
    assert!(minted.length() == 1);
    let (key, quantity, entity_id, component_id, balance_after, used_after) = item::minted_fields(
        &minted[0],
    );
    assert!(key == key_of(FUEL) && quantity == 100);
    assert!(entity_id == e_id && component_id == MODULE_ID);
    assert!(balance_after == 100 && used_after == 200);

    bridge_out(&mut scenario, e_id, OWNER, b"bridge_out", FUEL, 50); // used 100, bal 50
    let burned = event::events_by_type<item::ItemBurned>();
    assert!(burned.length() == 1);
    let (key, quantity, entity_id, component_id, balance_after, used_after) = item::burned_fields(
        &burned[0],
    );
    assert!(key == key_of(FUEL) && quantity == 50);
    assert!(entity_id == e_id && component_id == MODULE_ID);
    assert!(balance_after == 50 && used_after == 100);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let item = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 20); // used 60, bal 30
    assert!(item.quantity() == 20);
    let transit_id = object::id(&item);
    deposit(&mut scenario, &mut e, &cap, b"deposit", item); // used 100, bal 50

    assert!(inv(&e).used() == 100);
    assert!(inv(&e).items().balance(key_of(FUEL)) == 50);

    let withdrawn = event::events_by_type<item::ItemWithdrawn>();
    assert!(withdrawn.length() == 1);
    let (
        key,
        quantity,
        entity_id,
        component_id,
        out_transit,
        balance_after,
        used_after,
    ) = item::withdrawn_fields(&withdrawn[0]);
    assert!(key == key_of(FUEL) && quantity == 20);
    assert!(entity_id == e_id && component_id == MODULE_ID);
    assert!(out_transit == transit_id);
    assert!(balance_after == 30 && used_after == 60);

    let deposited = event::events_by_type<item::ItemDeposited>();
    assert!(deposited.length() == 1);
    let (
        key,
        quantity,
        entity_id,
        component_id,
        in_transit,
        balance_after,
        used_after,
    ) = item::deposited_fields(&deposited[0]);
    assert!(key == key_of(FUEL) && quantity == 20);
    assert!(entity_id == e_id && component_id == MODULE_ID);
    assert!(in_transit == transit_id);
    assert!(balance_after == 50 && used_after == 100);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

/// Shared entity holding 10 FUEL, so its `used` is exactly `10 * VOL`.
fun entity_with_ten_fuel(scenario: &mut ts::Scenario): ID {
    setup(scenario);
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let e = build_entity_with_inventory(scenario, &mut registry, &acl, 1, OWNER, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(scenario, e_id, OWNER);
    power_inventory(scenario, e_id, OWNER);
    bridge_in(scenario, e_id, OWNER, b"bridge_in", FUEL, 10, VOL);
    e_id
}

// Over-balance must hit the balance check, not underflow `used`.
#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun bridge_out_over_balance_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario);
    bridge_out(&mut scenario, e_id, OWNER, b"bridge_out", FUEL, 11);

    abort
}

#[test, expected_failure(abort_code = item::EInsufficientQuantity)]
fun withdraw_over_balance_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario);
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let _item = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 11);

    abort
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
    e.verify_owner(&mut req, &player_cap);

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
    let fuel_id = variant_for(&mut scenario, tenant(), FUEL, VOL);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let acl = take_acl(&scenario);
    let fuel = ts::take_immutable_by_id<Variant>(&scenario, fuel_id);
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    e.verify_owner(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, &fuel, 10);
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

    // B's ship (entity_b) docks at entity_a. Docking records both sides, so entity_a
    // accepts FUEL from entity_b and entity_b accepts the LENS from entity_a.
    dock_at(&mut scenario, entity_a_id, entity_b_id);

    ts::next_tx(&mut scenario, player_b);
    let mut entity_b = ts::take_shared_by_id<Entity>(&scenario, entity_b_id);
    let cap_b = ts::take_from_sender<AccessCap>(&scenario);
    let fuel = withdraw(&mut scenario, &mut entity_b, &cap_b, b"withdraw", FUEL, 1);

    let mut entity_a = ts::take_shared_by_id<Entity>(&scenario, entity_a_id);
    let mut req = entity_a.interact(string::utf8(b"swap"), scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    inventory::deposit(&mut entity_a, &mut req, fuel);
    grid_load::assert_online(&mut entity_a, &mut req, &clock);
    let lens = inventory::withdraw(&mut entity_a, &mut req, key_of(LENS), 1, scenario.ctx());
    grid_load::assert_online(&mut entity_a, &mut req, &clock);
    clock.destroy_for_testing();
    entity_a.complete_request(req);

    deposit(&mut scenario, &mut entity_b, &cap_b, b"deposit", lens);
    ts::return_to_sender(&scenario, cap_b);

    assert!(inv(&entity_a).items().balance(key_of(FUEL)) == 1);
    assert!(inv(&entity_a).items().balance(key_of(LENS)) == 0);
    assert!(inv(&entity_b).items().balance(key_of(LENS)) == 1);
    assert!(inv(&entity_b).items().balance(key_of(FUEL)) == 0);

    // `transit_id` pairs each withdrawal with its deposit.
    let withdrawn = event::events_by_type<item::ItemWithdrawn>();
    let deposited = event::events_by_type<item::ItemDeposited>();
    assert!(withdrawn.length() == 2 && deposited.length() == 2);
    let (fuel_key, _, fuel_from, _, fuel_transit, _, _) = item::withdrawn_fields(&withdrawn[0]);
    let (_, _, fuel_to, _, fuel_landed, _, _) = item::deposited_fields(&deposited[0]);
    let (lens_key, _, lens_from, _, lens_transit, _, _) = item::withdrawn_fields(&withdrawn[1]);
    let (_, _, lens_to, _, lens_landed, _, _) = item::deposited_fields(&deposited[1]);
    assert!(fuel_key == key_of(FUEL) && lens_key == key_of(LENS));
    assert!(fuel_transit == fuel_landed && lens_transit == lens_landed);
    assert!(fuel_transit != lens_transit);
    assert!(fuel_from == entity_b_id && fuel_to == entity_a_id);
    assert!(lens_from == entity_a_id && lens_to == entity_b_id);

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
    let fuel_id = variant_for(&mut scenario, tenant(), FUEL, VOL);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let fuel = ts::take_immutable_by_id<Variant>(&scenario, fuel_id);
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    e.verify_owner(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, &fuel, 60); // 120 > 100

    abort
}

/// A variant registered under another tenant cannot be bridged into this entity.
#[test, expected_failure(abort_code = inventory::EWrongTenant)]
fun bridge_in_other_tenant_variant_aborts() {
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
    let fuel_id = variant_for(&mut scenario, string::utf8(b"OTHER"), FUEL, VOL);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let fuel = ts::take_immutable_by_id<Variant>(&scenario, fuel_id);
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    e.verify_owner(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, &fuel, 10);

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
    let other_id = variant_for(&mut scenario, tenant(), FUEL + 1, VOL);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let other = ts::take_immutable_by_id<Variant>(&scenario, other_id);
    let mut req = e.interact(string::utf8(b"bridge_fuel"), scenario.ctx());
    e.verify_owner(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, &other, 10);

    abort
}

#[test]
fun uninstall_destroys_inventory() {
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

    let torn_down = event::events_by_type<inventory::InventoryUninstalled>();
    assert!(torn_down.length() == 1);
    let (
        entity_id,
        component_id,
        used_before,
        balance_count,
        batch_count,
    ) = inventory::uninstalled_fields(&torn_down[0]);
    assert!(entity_id == e_id && component_id == MODULE_ID);
    assert!(used_before == 200 && balance_count == 1 && batch_count == 1);

    let destroyed = event::events_by_type<item::ItemsDestroyed>();
    assert!(destroyed.length() == 1);
    let (entity_id, component_id, batch_index, balances) = item::items_destroyed_fields(
        &destroyed[0],
    );
    assert!(entity_id == e_id && component_id == MODULE_ID && batch_index == 0);
    assert!(balances.length() == 1);
    let (key, quantity, volume) = item::destroyed_balance_fields(&balances[0]);
    assert!(key == key_of(FUEL) && quantity == 100 && volume == 100 * VOL);
    assert!(event::events_by_type<item::ItemBurned>().is_empty());

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
    let (torn_entity, torn_component, used_before, _, _) = inventory::uninstalled_fields(
        &torn_down[0],
    );
    assert!(torn_entity == e_id && torn_component == MODULE_ID);
    assert!(used_before == 200);

    let installed = event::events_by_type<inventory::InventoryInstalled>();
    assert!(installed.length() == 1);
    let (new_entity, new_component, _, _, capacity) = inventory::installed_fields(&installed[0]);
    assert!(new_entity == e_id && new_component == MODULE_ID);
    assert!(capacity == 500);

    assert!(inv(&e).capacity() == 500);
    assert!(inv(&e).used() == 0);
    assert!(inventory::balance_of(&e, MODULE_ID, key_of(FUEL)) == 0);
    ts::return_shared(acl);
    ts::return_shared(e);

    // Reinstall connects desired-offline. Ask for the grant again before bridging.
    set_desired(&mut scenario, e_id, OWNER, true);

    // Second epoch: its own items, under the key the first one used. The FUEL
    // balance does not carry across.
    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", LENS, 50, VOL);
    ts::next_tx(&mut scenario, OWNER);
    let e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    assert!(inventory::balance_of(&e, MODULE_ID, key_of(LENS)) == 50);
    assert!(inventory::balance_of(&e, MODULE_ID, key_of(FUEL)) == 0);
    assert!(inv(&e).used() == 100);
    ts::return_shared(e);

    scenario.end();
}

/// Moving items between two inventories on one entity needs no docking: the
/// item's source is the entity it is deposited into.
#[test]
fun move_between_two_inventories_without_docking() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    install_inventory(
        &mut scenario,
        &mut e,
        &acl,
        MODULE_ID_2,
        TYPE_ID,
        option::some(string::utf8(b"SU-02")),
        500,
    );
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);
    let any = option::none();
    owner_enable(
        &mut scenario,
        e_id,
        OWNER,
        b"deposit_2",
        action::new(vector[
            access_cap::owner_requirement(),
            inventory::deposit_requirement(MODULE_ID_2, any, any, any),
        ]),
    );
    power_inventory(&mut scenario, e_id, OWNER);
    run_operate_grid!(&mut scenario, e_id, OWNER, |entity, req, clock| {
        grid_load::set_desired_state(entity, req, MODULE_ID_2, true, clock);
    });
    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", FUEL, 10, VOL);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    assert!(e.docked_entities().is_empty());
    let fuel = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 4);
    deposit(&mut scenario, &mut e, &cap, b"deposit_2", fuel);

    assert!(inv(&e).items().balance(key_of(FUEL)) == 6);
    assert!(inventory::inventory(&e, MODULE_ID_2).items().balance(key_of(FUEL)) == 4);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
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
    let _item = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 1);

    abort
}

#[test, expected_failure(abort_code = entity::ENotDocked)]
fun deposit_at_another_entity_with_nothing_docked_aborts() {
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

    ts::next_tx(&mut scenario, OWNER);
    let mut x = ts::take_shared_by_id<Entity>(&scenario, x_id);
    let mut z = ts::take_shared_by_id<Entity>(&scenario, z_id);
    let x_cap = ts::take_from_address<AccessCap>(&scenario, OWNER);
    let z_cap = ts::take_from_address<AccessCap>(&scenario, PLAYER);
    let fuel = withdraw(&mut scenario, &mut x, &x_cap, b"withdraw", FUEL, 1);
    deposit(&mut scenario, &mut z, &z_cap, b"deposit", fuel);

    abort
}

/// X was docked at Z, then undocked, so Z no longer accepts items from X.
#[test, expected_failure(abort_code = entity::ENotDocked)]
fun deposit_at_another_entity_after_undock_aborts() {
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
    dock_at(&mut scenario, z_id, x_id);
    undock_from(&mut scenario, z_id, x_id);

    ts::next_tx(&mut scenario, OWNER);
    let mut x = ts::take_shared_by_id<Entity>(&scenario, x_id);
    let mut z = ts::take_shared_by_id<Entity>(&scenario, z_id);
    let x_cap = ts::take_from_address<AccessCap>(&scenario, OWNER);
    let z_cap = ts::take_from_address<AccessCap>(&scenario, PLAYER);
    let fuel = withdraw(&mut scenario, &mut x, &x_cap, b"withdraw", FUEL, 1);
    deposit(&mut scenario, &mut z, &z_cap, b"deposit", fuel);

    abort
}

/// Z has something docked, but not X, so an item withdrawn from X can't be deposited at Z.
#[test, expected_failure(abort_code = entity::EWrongSource)]
fun deposit_from_an_undocked_source_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let x = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let x_id = x.id();
    let z = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 2, PLAYER, 1000);
    let z_id = z.id();
    let ship = claim(&mut registry, &acl, 3, scenario.ctx());
    let ship_id = ship.id();
    x.share();
    z.share();
    ship.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, x_id, OWNER);
    configure_default_actions(&mut scenario, z_id, PLAYER);
    power_inventory(&mut scenario, x_id, OWNER);
    bridge_in(&mut scenario, x_id, OWNER, b"bridge_in", FUEL, 1, VOL);
    dock_at(&mut scenario, z_id, ship_id);

    ts::next_tx(&mut scenario, OWNER);
    let mut x = ts::take_shared_by_id<Entity>(&scenario, x_id);
    let mut z = ts::take_shared_by_id<Entity>(&scenario, z_id);
    let x_cap = ts::take_from_address<AccessCap>(&scenario, OWNER);
    let z_cap = ts::take_from_address<AccessCap>(&scenario, PLAYER);
    let fuel = withdraw(&mut scenario, &mut x, &x_cap, b"withdraw", FUEL, 1);
    deposit(&mut scenario, &mut z, &z_cap, b"deposit", fuel);

    abort
}

/// Z has X docked, so an item withdrawn from X can be deposited at Z.
#[test]
fun deposit_from_a_docked_source() {
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
    power_inventory(&mut scenario, z_id, PLAYER);
    bridge_in(&mut scenario, x_id, OWNER, b"bridge_in", FUEL, 1, VOL);
    dock_at(&mut scenario, z_id, x_id);

    ts::next_tx(&mut scenario, OWNER);
    let mut x = ts::take_shared_by_id<Entity>(&scenario, x_id);
    let mut z = ts::take_shared_by_id<Entity>(&scenario, z_id);
    let x_cap = ts::take_from_address<AccessCap>(&scenario, OWNER);
    let z_cap = ts::take_from_address<AccessCap>(&scenario, PLAYER);
    let fuel = withdraw(&mut scenario, &mut x, &x_cap, b"withdraw", FUEL, 1);
    deposit(&mut scenario, &mut z, &z_cap, b"deposit", fuel);

    assert!(inv(&x).items().balance(key_of(FUEL)) == 0);
    assert!(inv(&z).items().balance(key_of(FUEL)) == 1);

    ts::return_to_address(OWNER, x_cap);
    ts::return_to_address(PLAYER, z_cap);
    ts::return_shared(x);
    ts::return_shared(z);
    scenario.end();
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
        0,
        0,
        &clock,
        scenario.ctx(),
    );

    abort
}

// === Migrate ===

/// Share a bare entity under `id` with only a power grid, in `tenant`.
fun share_grid_entity(scenario: &mut ts::Scenario, id: u64, tenant: vector<u8>): ID {
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let (mut e, mut req) = entity::new(&mut registry, id, string::utf8(tenant));
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    install_grid(scenario, &mut e, &acl);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    e_id
}

fun migrate_inventory(scenario: &mut ts::Scenario, from_id: ID, to_id: ID, component_id: u64) {
    ts::next_tx(scenario, ADMIN);
    let mut from = ts::take_shared_by_id<Entity>(scenario, from_id);
    let mut to = ts::take_shared_by_id<Entity>(scenario, to_id);
    let acl = take_acl(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let (mut from_req, mut to_req) = inventory::migrate(
        &mut from,
        &mut to,
        component_id,
        &clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut from_req, &acl, scenario.ctx());
    from.complete_request(from_req);
    admin_service::verify_admin(&mut to_req, &acl, scenario.ctx());
    to.complete_request(to_req);
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(to);
    ts::return_shared(from);
}

#[test]
fun migrate_moves_inventory_with_its_items() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let from_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, from_id, OWNER);
    power_inventory(&mut scenario, from_id, OWNER);
    bridge_in(&mut scenario, from_id, OWNER, b"bridge_in", FUEL, 100, VOL);
    let to_id = share_grid_entity(&mut scenario, 2, b"test");

    migrate_inventory(&mut scenario, from_id, to_id, MODULE_ID);

    assert!(event::events_by_type<item::ItemBurned>().is_empty());
    let migrated = event::events_by_type<inventory::InventoryMigrated>();
    assert!(migrated.length() == 1);
    let (
        from_entity,
        to_entity,
        component_id,
        inventory_type_id,
        capacity,
        used,
    ) = inventory::migrated_fields(&migrated[0]);
    assert!(from_entity == from_id && to_entity == to_id && component_id == MODULE_ID);
    assert!(inventory_type_id == TYPE_ID);
    assert!(capacity == 1000 && used == 100 * VOL);
    ts::next_tx(&mut scenario, ADMIN);
    let from = ts::take_shared_by_id<Entity>(&scenario, from_id);
    let to = ts::take_shared_by_id<Entity>(&scenario, to_id);
    assert!(!from.has_component(MODULE_ID));
    assert!(inv(&to).used() == 100 * VOL);
    assert!(inv(&to).items().balance(key_of(FUEL)) == 100);
    assert!(inv(&to).capacity() == 1000);
    assert!(inventory::type_id(inv(&to)) == TYPE_ID);
    assert!(power_grid::power_grid(&to).module_state(MODULE_ID).desired_online());
    assert!(!power_grid::power_grid(&from).is_module_connected(MODULE_ID));
    ts::return_shared(from);
    ts::return_shared(to);
    scenario.end();
}

#[test, expected_failure(abort_code = inventory::EComponentMissing)]
fun migrate_missing_inventory_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let from_id = share_grid_entity(&mut scenario, 1, b"test");
    let to_id = share_grid_entity(&mut scenario, 2, b"test");

    migrate_inventory(&mut scenario, from_id, to_id, MODULE_ID);

    abort
}

#[test, expected_failure(abort_code = inventory::EWrongTenant)]
fun migrate_across_tenants_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let from_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    let to_id = share_grid_entity(&mut scenario, 2, b"OTHER");

    migrate_inventory(&mut scenario, from_id, to_id, MODULE_ID);

    abort
}

// === Batched withdraw / deposit ===

/// Entry `i` of a batch is `(key_of(type_id), quantity, transit_id, balance_after, used_after)`.
fun assert_moved(
    entry: &item::MovedBalance,
    type_id: u64,
    quantity: u64,
    transit_id: ID,
    balance_after: u64,
    used_after: u64,
) {
    let (t, q, id, bal, used) = item::moved_balance_fields(entry);
    assert!(t == key_of(type_id) && q == quantity && id == transit_id);
    assert!(bal == balance_after && used == used_after);
}

#[test]
fun batch_withdraw_and_deposit_round_trip() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario); // FUEL 10, used 20
    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", LENS, 5, VOL); // used 30

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);

    // A repeated type is applied in order, so its `balance_after` steps down.
    let items = withdraw_batch(
        &mut scenario,
        &mut e,
        &cap,
        b"withdraw",
        vector[FUEL, LENS, FUEL],
        vector[4, 2, 3],
    );
    assert!(items.length() == 3);
    let t0 = object::id(&items[0]);
    let t1 = object::id(&items[1]);
    let t2 = object::id(&items[2]);
    assert!(items[0].key() == key_of(FUEL) && items[0].quantity() == 4);
    assert!(items[1].key() == key_of(LENS) && items[1].quantity() == 2);
    assert!(items[2].key() == key_of(FUEL) && items[2].quantity() == 3);

    let withdrawn = event::events_by_type<item::ItemsWithdrawn>();
    assert!(withdrawn.length() == 1);
    let (entity_id, component_id, batch_index, batch_count, entries) = item::items_withdrawn_fields(
        &withdrawn[0],
    );
    assert!(entity_id == e_id && component_id == MODULE_ID);
    assert!(batch_index == 0 && batch_count == 1 && entries.length() == 3);
    assert_moved(&entries[0], FUEL, 4, t0, 6, 22);
    assert_moved(&entries[1], LENS, 2, t1, 3, 18);
    assert_moved(&entries[2], FUEL, 3, t2, 3, 12);
    assert!(event::events_by_type<item::ItemWithdrawn>().is_empty());

    deposit_batch(&mut scenario, &mut e, &cap, b"deposit", items);
    assert!(inv(&e).used() == 30);
    assert!(
        inv(&e).items().balance(key_of(FUEL)) == 10 && inv(&e).items().balance(key_of(LENS)) == 5,
    );

    // Each deposit entry carries the `transit_id` of the withdrawal it completes.
    let deposited = event::events_by_type<item::ItemsDeposited>();
    assert!(deposited.length() == 1);
    let (entity_id, component_id, batch_index, batch_count, entries) = item::items_deposited_fields(
        &deposited[0],
    );
    assert!(entity_id == e_id && component_id == MODULE_ID);
    assert!(batch_index == 0 && batch_count == 1 && entries.length() == 3);
    assert_moved(&entries[0], FUEL, 4, t0, 7, 20);
    assert_moved(&entries[1], LENS, 2, t1, 5, 24);
    assert_moved(&entries[2], FUEL, 3, t2, 10, 30);
    assert!(event::events_by_type<item::ItemDeposited>().is_empty());

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = inventory::EBatchLengthMismatch)]
fun withdraw_batch_length_mismatch_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario);
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let _items = withdraw_batch(&mut scenario, &mut e, &cap, b"withdraw", vector[FUEL], vector[]);

    abort
}

#[test, expected_failure(abort_code = inventory::EEmptyBatch)]
fun withdraw_batch_empty_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario);
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let _items = withdraw_batch(&mut scenario, &mut e, &cap, b"withdraw", vector[], vector[]);

    abort
}

/// An entry over the action's max aborts the batch.
#[test, expected_failure(abort_code = inventory::EQuantityAboveMax)]
fun withdraw_batch_entry_over_rule_max_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario);
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let small = inventory::withdraw_requirement(
        MODULE_ID,
        option::none(),
        option::none(),
        option::some(3),
    );
    enable(&mut e, b"withdraw_small", small, &cap, scenario.ctx());
    let _items = withdraw_batch(
        &mut scenario,
        &mut e,
        &cap,
        b"withdraw_small",
        vector[FUEL, FUEL],
        vector[2, 4],
    );

    abort
}

/// Capacity is checked against the batch's total volume.
/// One requirement's max bounds the batch's total, even when every entry fits.
#[test, expected_failure(abort_code = inventory::EQuantityAboveMax)]
fun withdraw_batch_total_over_rule_max_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario);
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let small = inventory::withdraw_requirement(
        MODULE_ID,
        option::none(),
        option::none(),
        option::some(3),
    );
    enable(&mut e, b"withdraw_small", small, &cap, scenario.ctx());
    let _items = withdraw_batch(
        &mut scenario,
        &mut e,
        &cap,
        b"withdraw_small",
        vector[FUEL, FUEL],
        vector[2, 2],
    );

    abort
}

#[test]
fun withdraw_batch_total_at_rule_max_succeeds() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario);
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let small = inventory::withdraw_requirement(
        MODULE_ID,
        option::none(),
        option::some(4),
        option::some(4),
    );
    enable(&mut e, b"withdraw_four", small, &cap, scenario.ctx());
    // Each entry is below the min of 4; only the total has to meet it.
    let items = withdraw_batch(
        &mut scenario,
        &mut e,
        &cap,
        b"withdraw_four",
        vector[FUEL, FUEL],
        vector[2, 2],
    );
    assert!(inv(&e).items().balance(key_of(FUEL)) == 6);
    deposit_batch(&mut scenario, &mut e, &cap, b"deposit", items);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = inventory::EItemTypeNotAllowed)]
fun withdraw_batch_entry_wrong_type_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario);
    bridge_in(&mut scenario, e_id, OWNER, b"bridge_in", LENS, 5, VOL);
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let fuel_only = inventory::withdraw_requirement(
        MODULE_ID,
        option::some(FUEL),
        option::none(),
        option::none(),
    );
    enable(&mut e, b"withdraw_fuel", fuel_only, &cap, scenario.ctx());
    let _items = withdraw_batch(
        &mut scenario,
        &mut e,
        &cap,
        b"withdraw_fuel",
        vector[FUEL, LENS],
        vector[1, 1],
    );

    abort
}

/// One requirement's max bounds the batch's total, even when every item fits.
#[test, expected_failure(abort_code = inventory::EQuantityAboveMax)]
fun deposit_batch_total_over_rule_max_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let e_id = entity_with_ten_fuel(&mut scenario);
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let small = inventory::deposit_requirement(
        MODULE_ID,
        option::none(),
        option::none(),
        option::some(3),
    );
    enable(&mut e, b"deposit_small", small, &cap, scenario.ctx());
    let items = withdraw_batch(
        &mut scenario,
        &mut e,
        &cap,
        b"withdraw",
        vector[FUEL, FUEL],
        vector[2, 2],
    );
    deposit_batch(&mut scenario, &mut e, &cap, b"deposit_small", items);

    abort
}

/// A one-FUEL-for-one-LENS swap cannot pay out several LENS through one batch.
#[test, expected_failure(abort_code = inventory::EQuantityAboveMax)]
fun swap_batch_withdraw_cannot_exceed_payment() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let entity_a = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let entity_a_id = entity_a.id();
    let entity_b = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 2, PLAYER, 1000);
    let entity_b_id = entity_b.id();
    entity_a.share();
    entity_b.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    configure_default_actions(&mut scenario, entity_a_id, OWNER);
    configure_default_actions(&mut scenario, entity_b_id, PLAYER);
    power_inventory(&mut scenario, entity_a_id, OWNER);
    power_inventory(&mut scenario, entity_b_id, PLAYER);
    bridge_in(&mut scenario, entity_a_id, OWNER, b"bridge_in", LENS, 3, VOL);
    owner_enable(
        &mut scenario,
        entity_a_id,
        OWNER,
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
    bridge_in(&mut scenario, entity_b_id, PLAYER, b"bridge_in", FUEL, 1, VOL);

    dock_at(&mut scenario, entity_a_id, entity_b_id);

    ts::next_tx(&mut scenario, PLAYER);
    let mut entity_b = ts::take_shared_by_id<Entity>(&scenario, entity_b_id);
    let cap_b = ts::take_from_sender<AccessCap>(&scenario);
    let fuel = withdraw(&mut scenario, &mut entity_b, &cap_b, b"withdraw", FUEL, 1);

    let mut entity_a = ts::take_shared_by_id<Entity>(&scenario, entity_a_id);
    let mut req = entity_a.interact(string::utf8(b"swap"), scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    inventory::deposit(&mut entity_a, &mut req, fuel);
    grid_load::assert_online(&mut entity_a, &mut req, &clock);
    let _lens = inventory::withdraw_batch(
        &mut entity_a,
        &mut req,
        vector[key_of(LENS), key_of(LENS), key_of(LENS)],
        vector[1, 1, 1],
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = entity::ENotDocked)]
fun deposit_batch_from_undocked_entity_aborts() {
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
    power_inventory(&mut scenario, z_id, PLAYER);
    bridge_in(&mut scenario, x_id, OWNER, b"bridge_in", FUEL, 20, VOL);

    // X and Z are never docked, so Z refuses X's items.
    ts::next_tx(&mut scenario, OWNER);
    let mut x = ts::take_shared_by_id<Entity>(&scenario, x_id);
    let x_cap = ts::take_from_sender<AccessCap>(&scenario);
    let items = withdraw_batch(
        &mut scenario,
        &mut x,
        &x_cap,
        b"withdraw",
        vector[FUEL, FUEL],
        vector[2, 2],
    );
    let mut z = ts::take_shared_by_id<Entity>(&scenario, z_id);
    let z_cap = ts::take_from_address<AccessCap>(&scenario, PLAYER);
    deposit_batch(&mut scenario, &mut z, &z_cap, b"deposit", items);

    abort
}

#[test, expected_failure(abort_code = inventory::EOverCapacity)]
fun deposit_batch_over_capacity_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let x = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 1000);
    let x_id = x.id();
    let z = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 2, PLAYER, 30);
    let z_id = z.id();
    x.share();
    z.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, x_id, OWNER);
    configure_default_actions(&mut scenario, z_id, PLAYER);
    power_inventory(&mut scenario, x_id, OWNER);
    power_inventory(&mut scenario, z_id, PLAYER);
    bridge_in(&mut scenario, x_id, OWNER, b"bridge_in", FUEL, 20, VOL);

    // 8 + 8 units at VOL 2 is 32 volume against Z's 30; each half alone fits.
    dock_at(&mut scenario, z_id, x_id);

    ts::next_tx(&mut scenario, OWNER);
    let mut x = ts::take_shared_by_id<Entity>(&scenario, x_id);
    let x_cap = ts::take_from_sender<AccessCap>(&scenario);
    let items = withdraw_batch(
        &mut scenario,
        &mut x,
        &x_cap,
        b"withdraw",
        vector[FUEL, FUEL],
        vector[8, 8],
    );
    let mut z = ts::take_shared_by_id<Entity>(&scenario, z_id);
    let z_cap = ts::take_from_address<AccessCap>(&scenario, PLAYER);
    deposit_batch(&mut scenario, &mut z, &z_cap, b"deposit", items);

    abort
}

/// A mass variant takes space per kg: at 1/8000 m³ per kg (density 8,000 kg/m³),
/// 12.5 kg is 0.0015625 m³ (1,562,500 nano-m³), and the stack rounds once.
#[test]
fun bridge_in_mass_variant_sizes_per_kg() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_entity_with_inventory(&mut scenario, &mut registry, &acl, 1, OWNER, 10_000_000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    configure_default_actions(&mut scenario, e_id, OWNER);
    power_inventory(&mut scenario, e_id, OWNER);

    ts::next_tx(&mut scenario, ADMIN);
    if (!ts::has_most_recent_shared<VariantRegistry>()) {
        variant::init_for_testing(scenario.ctx());
        ts::next_tx(&mut scenario, ADMIN);
    };
    let mut variants = ts::take_shared<VariantRegistry>(&scenario);
    let ore = variants.register_for_testing(
        tenant(),
        FUEL,
        1,
        variant::mass(),
        125_000,
        vector[],
        vector[],
        vector[],
    );
    ts::return_shared(variants);

    bridge_in_record(&mut scenario, e_id, OWNER, b"bridge_in", ore, 12_500_000_000);
    let (_, _, _, _, balance_after, used_after) = item::minted_fields(
        &event::events_by_type<item::ItemMinted>()[0],
    );
    assert!(balance_after == 12_500_000_000 && used_after == 1_562_500);

    scenario.end();
}
