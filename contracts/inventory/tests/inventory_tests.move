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
const LENS: u64 = 55;
const VOL: u64 = 2;
const MODULE_ID: u64 = 0x51;
const MODULE_ID_2: u64 = 0x52;
const TYPE_ID: u64 = 1;

fun unit_name(): String { string::utf8(b"SU-01") }

/// Enable an action gated by a caller requirement plus `item_req`. The owner
/// signs with their `AccessCap` (enable is owner-gated).
fun enable(
    e: &mut Entity,
    name: vector<u8>,
    item_req: Requirement,
    owner_cap: &AccessCap,
    ctx: &mut TxContext,
) {
    let act = action::new(vector[access_cap::caller_requirement(), item_req]);
    let mut req = e.enable_action(string::utf8(name), act, ctx);
    access_cap::verify(&mut req, owner_cap);
    e.complete_request(req);
}

/// Claim an entity, install an inventory, and mint the owner (transferable) cap
/// to OWNER. Admin-only; the owner configures actions separately.
fun build_storage_unit(
    scenario: &mut ts::Scenario,
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    main_cap: u64,
    eph_cap: u64,
): Entity {
    let mut e = claim(registry, acl, 1, scenario.ctx());

    let mut req = inventory::install(
        &mut e,
        MODULE_ID,
        TYPE_ID,
        option::some(unit_name()),
        main_cap,
        eph_cap,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    let mut req = e.mint_access(OWNER, true, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    e
}

/// Owner enables `act` on the shared entity, signing with their cap. Runs in its
/// own OWNER tx and leaves the entity shared.
fun owner_enable(scenario: &mut ts::Scenario, e_id: ID, name: vector<u8>, act: action::Action) {
    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let mut req = e.enable_action(string::utf8(name), act, scenario.ctx());
    access_cap::verify(&mut req, &cap);
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

/// Owner exposes the standard main + ephemeral action set on the shared entity.
fun configure_default_actions(scenario: &mut ts::Scenario, e_id: ID) {
    ts::next_tx(scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let any = option::none();
    enable(
        &mut e,
        b"bridge_in",
        inventory::bridge_in_requirement(MODULE_ID, false, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"bridge_out",
        inventory::bridge_out_requirement(MODULE_ID, false, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"deposit",
        inventory::deposit_requirement(MODULE_ID, false, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"withdraw",
        inventory::withdraw_requirement(MODULE_ID, false, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"eph_bridge_in",
        inventory::bridge_in_requirement(MODULE_ID, true, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"eph_bridge_out",
        inventory::bridge_out_requirement(MODULE_ID, true, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"eph_deposit",
        inventory::deposit_requirement(MODULE_ID, true, any, any, any),
        &cap,
        scenario.ctx(),
    );
    enable(
        &mut e,
        b"eph_withdraw",
        inventory::withdraw_requirement(MODULE_ID, true, any, any, any),
        &cap,
        scenario.ctx(),
    );
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
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

// === Interaction helpers (caller supplies its own cap and the action name) ===

fun bridge_in(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    action: vector<u8>,
    type_id: u64,
    qty: u64,
    vol: u64,
) {
    let mut req = e.interact(string::utf8(action), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, cap);
    inventory::game_item_to_chain_inventory(e, &mut req, type_id, qty, vol, scenario.ctx());
    e.complete_request(req);
}

fun bridge_out(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    action: vector<u8>,
    type_id: u64,
    qty: u64,
) {
    let mut req = e.interact(string::utf8(action), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, cap);
    inventory::chain_item_to_game_inventory(e, &mut req, type_id, qty, scenario.ctx());
    e.complete_request(req);
}

fun deposit(
    scenario: &mut ts::Scenario,
    e: &mut Entity,
    cap: &AccessCap,
    action: vector<u8>,
    item: Item,
) {
    let mut req = e.interact(string::utf8(action), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, cap);
    inventory::deposit(e, &mut req, item, scenario.ctx());
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
    let mut req = e.interact(string::utf8(action), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, cap);
    let item = inventory::withdraw(e, &mut req, type_id, qty, scenario.ctx());
    e.complete_request(req);
    item
}

// === View helpers ===

fun main_inv(e: &Entity): &inventory::Inventory {
    inventory::inventory(inventory::storage(e, MODULE_ID), e.id())
}

fun eph_inv(e: &Entity, player_id: ID): &inventory::Inventory {
    inventory::inventory(inventory::storage(e, MODULE_ID), player_id)
}

#[test]
fun install_reports_module_and_capacities() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);

    let e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 100);
    assert!(e.has_module(MODULE_ID));
    assert!(inventory::type_id(&e, MODULE_ID) == TYPE_ID);
    assert!(inventory::is_creation_module(&e, MODULE_ID));
    assert!(main_inv(&e).capacity() == 1000);
    assert!(main_inv(&e).used() == 0);
    assert!(inventory::ephemeral_capacity(inventory::storage(&e, MODULE_ID)) == 100);

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

    let mut req = inventory::install(
        &mut e,
        MODULE_ID,
        TYPE_ID,
        option::some(unit_name()),
        1000,
        100,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    let mut req = inventory::install(
        &mut e,
        MODULE_ID_2,
        TYPE_ID,
        option::some(string::utf8(b"SU-02")),
        500,
        50,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    assert!(e.has_module(MODULE_ID));
    assert!(e.has_module(MODULE_ID_2));
    assert!(inventory::inventory(inventory::storage(&e, MODULE_ID), e.id()).capacity() == 1000);
    assert!(inventory::inventory(inventory::storage(&e, MODULE_ID_2), e.id()).capacity() == 500);

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
    configure_default_actions(&mut scenario, e_id);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);

    bridge_in(&mut scenario, &mut e, &cap, b"bridge_in", FUEL, 100, VOL); // used 200, bal 100
    bridge_out(&mut scenario, &mut e, &cap, b"bridge_out", FUEL, 50); // used 100, bal 50
    let item = withdraw(&mut scenario, &mut e, &cap, b"withdraw", FUEL, 20); // used 60, bal 30
    assert!(item.quantity() == 20);
    deposit(&mut scenario, &mut e, &cap, b"deposit", item); // used 100, bal 50

    assert!(main_inv(&e).used() == 100);
    assert!(main_inv(&e).items().balance(FUEL) == 50);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test]
fun main_inv_interaction_without_caller() {
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
    // A main action with no caller requirement: any player can execute it.
    owner_enable(
        &mut scenario,
        e_id,
        b"public_bridge",
        action::new(vector[
            inventory::bridge_in_requirement(
                MODULE_ID,
                false,
                option::none(),
                option::none(),
                option::none(),
            ),
        ]),
    );

    // PLAYER (not the owner, no cap presented) still lands in main.
    ts::next_tx(&mut scenario, PLAYER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let mut req = e.interact(string::utf8(b"public_bridge"), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, FUEL, 10, VOL, scenario.ctx());
    e.complete_request(req);

    assert!(main_inv(&e).items().balance(FUEL) == 10);
    ts::return_shared(e);
    scenario.end();
}

#[test]
fun player_interaction_ephemeral_inventory() {
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
    configure_default_actions(&mut scenario, e_id);

    ts::next_tx(&mut scenario, PLAYER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);

    bridge_in(&mut scenario, &mut e, &cap, b"eph_bridge_in", FUEL, 30, VOL); // eph bal 30
    let item = withdraw(&mut scenario, &mut e, &cap, b"eph_withdraw", FUEL, 10); // eph bal 20
    assert!(item.quantity() == 10);
    deposit(&mut scenario, &mut e, &cap, b"eph_deposit", item); // eph bal 30
    bridge_out(&mut scenario, &mut e, &cap, b"eph_bridge_out", FUEL, 20); // eph bal 10

    assert!(eph_inv(&e, player_id).items().balance(FUEL) == 10);
    assert!(main_inv(&e).items().balance(FUEL) == 0);

    ts::return_to_sender(&scenario, cap);
    ts::return_shared(e);
    scenario.end();
}

#[test]
fun swap_moves_between_main_and_ephemeral_single_signer() {
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
    configure_default_actions(&mut scenario, e_id);
    // Owner-configured swap: give a fuel from your ephemeral, get a lens from main.
    owner_enable(
        &mut scenario,
        e_id,
        b"swap",
        action::new(vector[
            access_cap::caller_requirement(),
            inventory::withdraw_requirement(
                MODULE_ID,
                true,
                option::some(FUEL),
                option::none(),
                option::none(),
            ),
            inventory::deposit_requirement(
                MODULE_ID,
                false,
                option::some(FUEL),
                option::none(),
                option::none(),
            ),
            inventory::withdraw_requirement(
                MODULE_ID,
                false,
                option::some(LENS),
                option::none(),
                option::none(),
            ),
            inventory::deposit_requirement(
                MODULE_ID,
                true,
                option::some(LENS),
                option::none(),
                option::none(),
            ),
        ]),
    );

    // Owner stocks a lens in main.
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let owner_cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &owner_cap, b"bridge_in", LENS, 1, VOL);
    ts::return_to_sender(&scenario, owner_cap);
    ts::return_shared(e);

    // Player brings fuel into their ephemeral, then swaps — one signer, one tx.
    ts::next_tx(&mut scenario, PLAYER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let player_cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &player_cap, b"eph_bridge_in", FUEL, 1, VOL);

    let mut req = e.interact(string::utf8(b"swap"), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, &player_cap);
    let fuel = inventory::withdraw(&mut e, &mut req, FUEL, 1, scenario.ctx()); // from ephemeral
    inventory::deposit(&mut e, &mut req, fuel, scenario.ctx()); // into main
    let lens = inventory::withdraw(&mut e, &mut req, LENS, 1, scenario.ctx()); // from main
    inventory::deposit(&mut e, &mut req, lens, scenario.ctx()); // into ephemeral
    e.complete_request(req);

    // Main now holds the fuel; the player's ephemeral holds the lens.
    assert!(main_inv(&e).items().balance(FUEL) == 1);
    assert!(main_inv(&e).items().balance(LENS) == 0);
    assert!(eph_inv(&e, player_id).items().balance(LENS) == 1);
    assert!(eph_inv(&e, player_id).items().balance(FUEL) == 0);

    ts::return_to_sender(&scenario, player_cap);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = inventory::ENotAuthorized)]
fun ephemeral_interaction_without_caller_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = build_storage_unit(&mut scenario, &mut registry, &acl, 1000, 1000);
    let e_id = e.id();
    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    // Ephemeral action missing the caller requirement -> no recorded caller.
    owner_enable(
        &mut scenario,
        e_id,
        b"eph_uncalled",
        action::new(vector[
            inventory::bridge_in_requirement(
                MODULE_ID,
                true,
                option::none(),
                option::none(),
                option::none(),
            ),
        ]),
    );

    ts::next_tx(&mut scenario, PLAYER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let mut req = e.interact(string::utf8(b"eph_uncalled"), vector[], scenario.ctx());
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
    configure_default_actions(&mut scenario, e_id);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &cap, b"bridge_in", FUEL, 60, VOL); // 120 > 100

    abort
}

#[test, expected_failure(abort_code = inventory::EItemTypeNotAllowed)]
fun bridge_in_wrong_type_aborts() {
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
    owner_enable(
        &mut scenario,
        e_id,
        b"bridge_fuel",
        action::new(vector[
            access_cap::caller_requirement(),
            inventory::bridge_in_requirement(
                MODULE_ID,
                false,
                option::some(FUEL),
                option::none(),
                option::none(),
            ),
        ]),
    );

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut req = e.interact(string::utf8(b"bridge_fuel"), vector[], scenario.ctx());
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
    ts::return_shared(acl);
    configure_default_actions(&mut scenario, e_id);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let owner_cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &owner_cap, b"bridge_in", FUEL, 100, VOL);
    ts::return_to_sender(&scenario, owner_cap);
    ts::return_shared(e);

    ts::next_tx(&mut scenario, PLAYER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let player_cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &player_cap, b"eph_bridge_in", FUEL, 10, VOL);
    ts::return_to_sender(&scenario, player_cap);
    ts::return_shared(e);

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let acl = take_acl(&scenario);
    let mut req = inventory::uninstall(&mut e, MODULE_ID, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(!e.has_module(MODULE_ID));

    ts::return_shared(acl);
    ts::return_shared(e);
    scenario.end();
}
