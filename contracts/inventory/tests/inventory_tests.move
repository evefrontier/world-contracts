#[test_only]
module inventory::inventory_tests;

use core::{
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    location_service,
    object_registry::ObjectRegistry,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use inventory::{inventory, item};
use std::string::{Self, String};
use sui::{event, test_scenario as ts};

const ADMIN: address = @0xA;
const FUEL: u64 = 100;
const VOL: u64 = 2;

fun unit_name(): String { string::utf8(b"SU-01") }

/// Claim an entity, install an inventory module, and expose deposit/withdraw/
/// bridge actions (all ungated). Returns the configured, locked-then-unlocked entity.
fun build_storage_unit(
    scenario: &mut ts::Scenario,
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    main_cap: u64,
    eph_cap: u64,
): Entity {
    let mut e = claim(registry, acl, 1, scenario.ctx());

    let mut req = inventory::install(&mut e, unit_name(), main_cap, eph_cap, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    let req = e.enable_action(
        string::utf8(b"bridge_in"),
        action::new(vector[
            inventory::bridge_in_requirement(
                unit_name(),
                option::none(),
                option::none(),
                option::none(),
            ),
        ]),
        scenario.ctx(),
    );
    e.complete_request(req);
    let req = e.enable_action(
        string::utf8(b"deposit"),
        action::new(vector[
            inventory::deposit_requirement(
                unit_name(),
                option::none(),
                option::none(),
                option::none(),
            ),
        ]),
        scenario.ctx(),
    );
    e.complete_request(req);
    let req = e.enable_action(
        string::utf8(b"withdraw"),
        action::new(vector[
            inventory::withdraw_requirement(
                unit_name(),
                option::none(),
                option::none(),
                option::none(),
            ),
        ]),
        scenario.ctx(),
    );
    e.complete_request(req);
    e
}

fun bridge_in(scenario: &mut ts::Scenario, e: &mut Entity, type_id: u64, qty: u64, vol: u64) {
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    inventory::game_item_to_chain_inventory(e, &mut req, type_id, qty, vol);
    e.complete_request(req);
}

#[test]
fun install_reports_module_and_capacities() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);

    let e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 100);
    assert!(e.has_module(unit_name()));
    let storage = inventory::main(inventory_state(&e));
    assert!(storage.capacity() == 1000);
    assert!(storage.used() == 0);

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun bridge_in_adds_main_inventory_balance_then_withdraws_and_deposits() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut storage_unit = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 100);

    // bridge 100 fuel with vol 2 -> used = 200
    bridge_in(&mut scenario, &mut storage_unit, FUEL, 100, VOL);
    assert!(inventory::main(inventory_state(&storage_unit)).used() == 200);
    assert!(inventory::main(inventory_state(&storage_unit)).items().balance(FUEL) == 100);

    // withdraw 40 -> Item in hand, used = 120
    let mut req = storage_unit.interact(string::utf8(b"withdraw"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    let fuel = inventory::withdraw(&mut storage_unit, &mut req, FUEL, 40, scenario.ctx());
    storage_unit.complete_request(req);
    assert!(fuel.quantity() == 40);
    assert!(inventory::main(inventory_state(&storage_unit)).used() == 120);

    // deposit it back -> used = 200
    let mut req = storage_unit.interact(string::utf8(b"deposit"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    inventory::deposit(&mut storage_unit, &mut req, fuel);
    storage_unit.complete_request(req);
    assert!(inventory::main(inventory_state(&storage_unit)).used() == 200);

    storage_unit.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = inventory::EOverCapacity)]
fun bridge_in_over_capacity_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_storage_unit(&mut scenario, &mut registry, &acl, 100, 100);
    bridge_in(&mut scenario, &mut e, FUEL, 60, VOL);

    abort
}

#[test, expected_failure(abort_code = inventory::EItemTypeNotAllowed)]
fun bridge_in_wrong_type_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 100);

    let req = e.enable_action(
        string::utf8(b"bridge_fuel"),
        action::new(vector[
            inventory::bridge_in_requirement(
                unit_name(),
                option::some(FUEL),
                option::none(),
                option::none(),
            ),
        ]),
        scenario.ctx(),
    );
    e.complete_request(req);

    let mut req = e.interact(string::utf8(b"bridge_fuel"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, FUEL + 1, 10, VOL);

    abort
}

#[test, expected_failure(abort_code = inventory::EQuantityAboveMax)]
fun bridge_in_above_max_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 100);

    let req = e.enable_action(
        string::utf8(b"bridge_capped"),
        action::new(vector[
            inventory::bridge_in_requirement(
                unit_name(),
                option::none(),
                option::none(),
                option::some(50),
            ),
        ]),
        scenario.ctx(),
    );
    e.complete_request(req);

    let mut req = e.interact(string::utf8(b"bridge_capped"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, FUEL, 60, VOL);

    abort
}

#[test]
fun uninstall_burns_main_inventory() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 100);

    bridge_in(&mut scenario, &mut e, FUEL, 100, VOL);
    assert!(inventory::main(inventory_state(&e)).items().balance(FUEL) == 100);
    assert!(inventory::main(inventory_state(&e)).used() == 100 * VOL);

    let mut req = inventory::uninstall(&mut e, unit_name(), scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(!e.has_module(unit_name()));
    assert!(event::events_by_type<item::ItemBurned>().length() == 1);

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun uninstall_empty_removes_module() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 100);

    let mut req = inventory::uninstall(&mut e, unit_name(), scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(!e.has_module(unit_name()));

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

fun inventory_state(e: &Entity): &inventory::StorageInventory {
    inventory::storage(e, unit_name())
}
