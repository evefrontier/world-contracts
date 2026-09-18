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

    let mut req = inventory::install(
        &mut e,
        MODULE_ID,
        TYPE_ID,
        option::some(unit_name()),
        capacity,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    let mut req = e.mint_access(owner, true, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    e
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
/// entity. Every one of these is owner-gated: only the entity's own owner can
/// move items through its inventory this way. Cross-owner movement happens
/// only through an owner-configured composite action, like `swap` below.
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
    access_cap::verify(&mut req, cap);
    inventory::game_item_to_chain_inventory(e, &mut req, type_id, qty, vol);
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
    access_cap::verify(&mut req, cap);
    inventory::chain_item_to_game_inventory(e, &mut req, type_id, qty);
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
    access_cap::verify(&mut req, cap);
    inventory::deposit(e, &mut req, item);
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
    access_cap::verify(&mut req, cap);
    let item = inventory::withdraw(e, &mut req, type_id, qty, scenario.ctx());
    e.complete_request(req);
    item
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
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    assert!(e.has_component(MODULE_ID));
    assert!(e.has_component(MODULE_ID_2));
    assert!(inventory::inventory(&e, MODULE_ID).capacity() == 1000);
    assert!(inventory::inventory(&e, MODULE_ID_2).capacity() == 500);

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

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);

    bridge_in(&mut scenario, &mut e, &cap, b"bridge_in", FUEL, 100, VOL); // used 200, bal 100
    bridge_out(&mut scenario, &mut e, &cap, b"bridge_out", FUEL, 50); // used 100, bal 50
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
    bridge_in(&mut scenario, &mut e, &player_cap, b"bridge_in", FUEL, 10, VOL);

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

    // A bridges a LENS onto entity_a (owner-only).
    ts::next_tx(&mut scenario, player_a);
    let mut entity_a = ts::take_shared_by_id<Entity>(&scenario, entity_a_id);
    let cap_a = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut entity_a, &cap_a, b"bridge_in", LENS, 1, VOL);
    ts::return_to_sender(&scenario, cap_a);
    ts::return_shared(entity_a);

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

    // B bridges a FUEL onto entity_b (owner-only).
    ts::next_tx(&mut scenario, player_b);
    let mut entity_b = ts::take_shared_by_id<Entity>(&scenario, entity_b_id);
    let cap_b = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut entity_b, &cap_b, b"bridge_in", FUEL, 1, VOL);
    ts::return_to_sender(&scenario, cap_b);
    ts::return_shared(entity_b);

    // B, in one signed tx: withdraws FUEL from entity_b, swaps it for the LENS
    // on entity_a, then deposits the LENS into entity_b.
    ts::next_tx(&mut scenario, player_b);
    let mut entity_b = ts::take_shared_by_id<Entity>(&scenario, entity_b_id);
    let cap_b = ts::take_from_sender<AccessCap>(&scenario);
    let fuel = withdraw(&mut scenario, &mut entity_b, &cap_b, b"withdraw", FUEL, 1);

    let mut entity_a = ts::take_shared_by_id<Entity>(&scenario, entity_a_id);
    let mut req = entity_a.interact(string::utf8(b"swap"), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    inventory::deposit(&mut entity_a, &mut req, fuel);
    let lens = inventory::withdraw(&mut entity_a, &mut req, LENS, 1, scenario.ctx());
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
    let mut req = e.interact(string::utf8(b"bridge_fuel"), vector[], scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
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

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let owner_cap = ts::take_from_sender<AccessCap>(&scenario);
    bridge_in(&mut scenario, &mut e, &owner_cap, b"bridge_in", FUEL, 100, VOL);
    ts::return_to_sender(&scenario, owner_cap);
    ts::return_shared(e);

    ts::next_tx(&mut scenario, ADMIN);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, e_id);
    let acl = take_acl(&scenario);
    let mut req = inventory::uninstall(&mut e, MODULE_ID, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    assert!(!e.has_component(MODULE_ID));

    ts::return_shared(acl);
    ts::return_shared(e);
    scenario.end();
}
