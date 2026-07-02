#[test_only]
module inventory::inventory_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    location_service,
    object_registry::ObjectRegistry,
    requirement::Requirement,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use inventory::{inventory, item::Item};
use std::string::{Self, String};
use sui::test_scenario as ts;

const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const PLAYER: address = @0xC;
const FUEL: u64 = 88834;
const VOL: u64 = 2;

fun unit_name(): String { string::utf8(b"SU-01") }

/// Enable an inventory action gated by a caller requirement plus `item_req`.
fun enable(e: &mut Entity, name: vector<u8>, item_req: Requirement, ctx: &mut TxContext) {
    let act = action::new(vector[access_cap::caller_requirement(), item_req]);
    let req = e.enable_action(string::utf8(name), act, ctx);
    e.complete_request(req);
}

/// Claim an entity, install an inventory, mint the owner (transferable) cap to
/// OWNER, and expose ungated bridge/deposit/withdraw actions. Entity kept local
/// so the caller can share it in the same (creating) transaction.
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

    let mut req = e.mint_access(OWNER, true, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    let n = unit_name();
    enable(
        &mut e,
        b"bridge_in",
        inventory::bridge_in_requirement(n, option::none(), option::none(), option::none()),
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"bridge_out",
        inventory::bridge_out_requirement(n, option::none(), option::none(), option::none()),
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"deposit",
        inventory::deposit_requirement(n, option::none(), option::none(), option::none()),
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"withdraw",
        inventory::withdraw_requirement(n, option::none(), option::none(), option::none()),
        scenario.ctx(),
    );
    e
}

/// Create a separate "character" entity and mint a soulbound cap to PLAYER.
/// Returns the character entity id (the key its ephemeral inventory routes to).
fun create_player(scenario: &mut ts::Scenario, registry: &mut ObjectRegistry, acl: &AdminACL): ID {
    let mut character = claim(registry, acl, 2, scenario.ctx());
    let mut req = character.mint_access(PLAYER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    character.complete_request(req);
    let character_id = character.id();
    character.share();
    character_id
}

// === Interaction helpers (caller supplies its own cap) ===

fun bridge_in(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    type_id: u64,
    qty: u64,
    vol: u64,
) {
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, cap);
    inventory::game_item_to_chain_inventory(e, &mut req, type_id, qty, vol, scenario.ctx());
    e.complete_request(req);
}

fun bridge_out(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    type_id: u64,
    qty: u64,
) {
    let mut req = e.interact(string::utf8(b"bridge_out"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, cap);
    inventory::chain_item_to_game_inventory(e, &mut req, type_id, qty, scenario.ctx());
    e.complete_request(req);
}

fun deposit(scenario: &mut ts::Scenario, e: &mut Entity, cap: &AccessCap, item: Item) {
    let mut req = e.interact(string::utf8(b"deposit"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, cap);
    inventory::deposit(e, &mut req, item, scenario.ctx());
    e.complete_request(req);
}

fun withdraw(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    type_id: u64,
    qty: u64,
): Item {
    let mut req = e.interact(string::utf8(b"withdraw"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, cap);
    let item = inventory::withdraw(e, &mut req, type_id, qty, scenario.ctx());
    e.complete_request(req);
    item
}

// === View helpers ===

fun main_inv(e: &Entity): &inventory::Inventory {
    inventory::inventory(inventory::storage(e, unit_name()), e.id())
}

fun eph_inv(e: &Entity, player_id: ID): &inventory::Inventory {
    inventory::inventory(inventory::storage(e, unit_name()), player_id)
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
    assert!(main_inv(&e).capacity() == 1000);
    assert!(main_inv(&e).used() == 0);
    assert!(inventory::ephemeral_capacity(inventory::storage(&e, unit_name())) == 100);

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun owner_interaction_main_inventory() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 100);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);

    bridge_in(&mut scenario, &mut e, &cap, FUEL, 100, VOL); // main used 200, bal 100
    assert!(main_inv(&e).used() == 200);
    assert!(main_inv(&e).items().balance(FUEL) == 100);

    bridge_out(&mut scenario, &mut e, &cap, FUEL, 50); // used 100, bal 50
    let item = withdraw(&mut scenario, &mut e, &cap, FUEL, 20); // used 60, bal 30
    assert!(item.quantity() == 20);
    deposit(&mut scenario, &mut e, &cap, item); // used 100, bal 50

    assert!(main_inv(&e).used() == 100);
    assert!(main_inv(&e).items().balance(FUEL) == 50);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test]
fun non_owner_interaction_ephemeral_inventory() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 1000);
    let e_id = e.id();
    let player_id = create_player(&mut scenario, &mut registry, &acl);
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, PLAYER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);

    bridge_in(&mut scenario, &mut e, &cap, FUEL, 30, VOL); // eph used 60, bal 30
    let item = withdraw(&mut scenario, &mut e, &cap, FUEL, 10); // eph used 40, bal 20
    assert!(item.quantity() == 10);
    deposit(&mut scenario, &mut e, &cap, item); // eph used 60, bal 30
    bridge_out(&mut scenario, &mut e, &cap, FUEL, 20); // eph used 20, bal 10

    // Ephemeral holds the balance; main is untouched.
    assert!(eph_inv(&e, player_id).used() == 20);
    assert!(eph_inv(&e, player_id).items().balance(FUEL) == 10);
    assert!(main_inv(&e).used() == 0);
    assert!(main_inv(&e).items().balance(FUEL) == 0);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test]
fun move_items_between_main_and_ephemeral() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 1000);
    let e_id = e.id();
    let player_id = create_player(&mut scenario, &mut registry, &acl);
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    // Owner seeds main and withdraws an Item from it.
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let owner_cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &owner_cap, FUEL, 100, VOL); // main bal 100
    let item = withdraw(&mut scenario, &mut e, &owner_cap, FUEL, 40); // main bal 60
    ts::return_to_sender(&scenario, owner_cap);
    ts::return_shared(e);

    // Player deposits that Item: it lands in the player's ephemeral inventory,
    // then withdraws it back out.
    ts::next_tx(&mut scenario, PLAYER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let player_cap = ts::take_from_sender<AccessCap>(&scenario);
    deposit(&mut scenario, &mut e, &player_cap, item); // eph bal 40
    assert!(main_inv(&e).items().balance(FUEL) == 60);
    assert!(eph_inv(&e, player_id).items().balance(FUEL) == 40);
    let item2 = withdraw(&mut scenario, &mut e, &player_cap, FUEL, 40); // eph bal 0
    ts::return_to_sender(&scenario, player_cap);
    ts::return_shared(e);

    // Owner deposits it back into main.
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let owner_cap = ts::take_from_sender<AccessCap>(&scenario);
    deposit(&mut scenario, &mut e, &owner_cap, item2); // main bal 100
    assert!(main_inv(&e).items().balance(FUEL) == 100);
    assert!(eph_inv(&e, player_id).items().balance(FUEL) == 0);
    ts::return_to_sender(&scenario, owner_cap);
    ts::return_shared(e);

    scenario.end();
}

#[test, expected_failure(abort_code = inventory::ENotAuthorized)]
fun interaction_without_caller_requirement_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 100);

    // Action with no caller requirement -> no authorized id recorded.
    let req = e.enable_action(
        string::utf8(b"bridge_uncalled"),
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

    let mut req = e.interact(string::utf8(b"bridge_uncalled"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, FUEL, 10, VOL, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = inventory::EOverCapacity)]
fun bridge_in_over_capacity_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_storage_unit(&mut scenario, &mut registry, &acl, 100, 100);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &cap, FUEL, 60, VOL); // 120 > 100

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
    enable(
        &mut e,
        b"bridge_fuel",
        inventory::bridge_in_requirement(
            unit_name(),
            option::some(FUEL),
            option::none(),
            option::none(),
        ),
        scenario.ctx(),
    );
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.interact(string::utf8(b"bridge_fuel"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, FUEL + 1, 10, VOL, scenario.ctx());

    abort
}

#[test]
fun uninstall_burns_all_inventories() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 1000);
    let e_id = e.id();
    let _player_id = create_player(&mut scenario, &mut registry, &acl);
    e.share();
    ts::return_shared(registry);

    // Owner seeds main; player seeds their ephemeral.
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let owner_cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &owner_cap, FUEL, 100, VOL);
    ts::return_to_sender(&scenario, owner_cap);
    ts::return_shared(e);

    ts::next_tx(&mut scenario, PLAYER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let player_cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &player_cap, FUEL, 10, VOL);
    ts::return_to_sender(&scenario, player_cap);
    ts::return_shared(e);

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let mut req = inventory::uninstall(&mut e, unit_name(), scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(!e.has_module(unit_name()));

    ts::return_shared(acl);
    ts::return_shared(e);
    scenario.end();
}
