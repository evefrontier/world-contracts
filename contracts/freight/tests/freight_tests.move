#[test_only]
module freight::freight_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    location_service,
    object_registry::ObjectRegistry,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use freight::freight::{Self, FreightDelivered, FreightPickedUp, FreightReceipt};
use inventory::{inventory, item::Item};
use std::string::{Self, String};
use sui::{event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER_A: address = @0xB;
const OWNER_B: address = @0xC;
const CARRIER: address = @0xD;
const OTHER: address = @0xE;

const FUEL: u64 = 88834;
const VOL: u64 = 2;
const QTY: u64 = 10;

fun unit_name(): String { string::utf8(b"SU-01") }

/// Claim, install inventory, mint a transferable owner cap, and share.
fun build_storage_unit(
    scenario: &mut ts::Scenario,
    registry: &mut ObjectRegistry,
    acl: &AdminACL,
    in_game_id: u64,
    owner: address,
): Entity {
    let mut e = claim(registry, acl, in_game_id, scenario.ctx());
    let mut req = inventory::install(&mut e, unit_name(), 1000, 100, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);

    let mut req = e.mint_access(owner, true, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    e.complete_request(req);
    e
}

/// Create a carrier "character" entity and mint a soulbound cap to CARRIER.
fun create_carrier(scenario: &mut ts::Scenario, registry: &mut ObjectRegistry, acl: &AdminACL): ID {
    let mut character = claim(registry, acl, 99, scenario.ctx());
    let mut req = character.mint_access(CARRIER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, acl, scenario.ctx());
    character.complete_request(req);
    let character_id = character.id();
    character.share();
    character_id
}

fun owner_enable(
    scenario: &mut ts::Scenario,
    owner: address,
    e_id: ID,
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

/// Source: bridge_in + freight_pickup. Destination: freight_dropoff.
fun configure_freight_actions(
    scenario: &mut ts::Scenario,
    source_id: ID,
    dest_id: ID,
    owner_a: address,
    owner_b: address,
) {
    let name = unit_name();
    let any = option::none();

    owner_enable(
        scenario,
        owner_a,
        source_id,
        b"bridge_in",
        action::new(vector[
            access_cap::caller_requirement(),
            inventory::bridge_in_requirement(name, false, any, any, any),
        ]),
    );
    owner_enable(
        scenario,
        owner_a,
        source_id,
        b"freight_pickup",
        action::new(vector[
            access_cap::caller_requirement(),
            inventory::withdraw_requirement(name, false, option::some(FUEL), any, any),
            freight::pickup_requirement(dest_id),
        ]),
    );
    owner_enable(
        scenario,
        owner_b,
        dest_id,
        b"freight_dropoff",
        action::new(vector[
            access_cap::caller_requirement(),
            freight::dropoff_requirement(),
            inventory::deposit_requirement(name, false, option::some(FUEL), any, any),
        ]),
    );
}

fun stock_main(scenario: &mut ts::Scenario, owner: address, e_id: ID, qty: u64) {
    ts::next_tx(scenario, owner);
    let mut e = ts::take_shared_by_id<Entity>(scenario, e_id);
    let cap = ts::take_from_sender<AccessCap>(scenario);
    let mut req = e.interact(string::utf8(b"bridge_in"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, &cap);
    inventory::game_item_to_chain_inventory(&mut e, &mut req, FUEL, qty, VOL, scenario.ctx());
    e.complete_request(req);
    ts::return_to_sender(scenario, cap);
    ts::return_shared(e);
}

fun main_balance(e: &Entity, type_id: u64): u64 {
    inventory::balance_of(e, unit_name(), e.id(), type_id)
}

/// Pickup at source: withdraw + issue receipt. Leaves the entity shared.
fun run_pickup(
    scenario: &mut ts::Scenario,
    source_id: ID,
    carrier_cap: &AccessCap,
): (Item, FreightReceipt) {
    let mut e = ts::take_shared_by_id<Entity>(scenario, source_id);
    let mut req = e.interact(string::utf8(b"freight_pickup"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, carrier_cap);
    let item = inventory::withdraw(&mut e, &mut req, FUEL, QTY, scenario.ctx());
    let receipt = freight::pickup(&e, &mut req, &item, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(e);
    (item, receipt)
}

/// Dropoff at destination: validate receipt then deposit. Leaves the entity shared.
fun run_dropoff(
    scenario: &mut ts::Scenario,
    dest_id: ID,
    carrier_cap: &AccessCap,
    item: Item,
    receipt: FreightReceipt,
) {
    let mut e = ts::take_shared_by_id<Entity>(scenario, dest_id);
    let mut req = e.interact(string::utf8(b"freight_dropoff"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, carrier_cap);
    freight::dropoff(&e, &mut req, &item, receipt);
    inventory::deposit(&mut e, &mut req, item, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(e);
}

/// Shared fixture: two SUs, carrier character, freight actions, source stocked.
fun setup_freight(scenario: &mut ts::Scenario): (ID, ID, ID) {
    setup(scenario);

    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);

    let source = build_storage_unit(scenario, &mut registry, &acl, 1, OWNER_A);
    let dest = build_storage_unit(scenario, &mut registry, &acl, 2, OWNER_B);
    let source_id = source.id();
    let dest_id = dest.id();
    let carrier_id = create_carrier(scenario, &mut registry, &acl);
    source.share();
    dest.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    configure_freight_actions(scenario, source_id, dest_id, OWNER_A, OWNER_B);
    stock_main(scenario, OWNER_A, source_id, 100);
    (source_id, dest_id, carrier_id)
}

#[test]
fun pickup_then_dropoff_delivers_across_entities() {
    let mut scenario = ts::begin(ADMIN);
    let (source_id, dest_id, carrier_id) = setup_freight(&mut scenario);

    // Tx 1: pickup — withdraw + bind receipt to the carrier.
    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    assert!(access_cap::entity(&carrier_cap) == carrier_id);
    let (item, receipt) = run_pickup(&mut scenario, source_id, &carrier_cap);

    assert!(freight::source(&receipt) == source_id);
    assert!(freight::destination(&receipt) == dest_id);
    assert!(freight::carrier(&receipt) == carrier_id);
    assert!(freight::item_id(&receipt) == object::id(&item));
    assert!(freight::type_id(&receipt) == FUEL);
    assert!(freight::quantity(&receipt) == QTY);

    let picked = event::events_by_type<FreightPickedUp>();
    assert!(picked.length() == 1);

    transfer::public_transfer(item, CARRIER);
    transfer::public_transfer(receipt, CARRIER);
    ts::return_to_sender(&scenario, carrier_cap);

    // Tx 2: dropoff — consume receipt and deposit the exact Item.
    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let item = ts::take_from_sender<Item>(&scenario);
    let receipt = ts::take_from_sender<FreightReceipt>(&scenario);

    let mut dest = ts::take_shared_by_id<Entity>(&scenario, dest_id);
    let mut req = dest.interact(string::utf8(b"freight_dropoff"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, &carrier_cap);
    freight::dropoff(&dest, &mut req, &item, receipt);
    inventory::deposit(&mut dest, &mut req, item, scenario.ctx());
    dest.complete_request(req);

    let delivered = event::events_by_type<FreightDelivered>();
    assert!(delivered.length() == 1);
    assert!(main_balance(&dest, FUEL) == QTY);
    ts::return_shared(dest);
    ts::return_to_sender(&scenario, carrier_cap);

    // Tx 3: assert source depleted (cannot re-take dest in the prior tx after return).
    ts::next_tx(&mut scenario, CARRIER);
    let source = ts::take_shared_by_id<Entity>(&scenario, source_id);
    assert!(main_balance(&source, FUEL) == 90);
    assert!(!ts::has_most_recent_for_sender<FreightReceipt>(&scenario));
    ts::return_shared(source);

    scenario.end();
}

#[test, expected_failure(abort_code = freight::EWrongDestination)]
fun dropoff_rejects_wrong_destination() {
    let mut scenario = ts::begin(ADMIN);
    let (source_id, dest_id, _carrier_id) = setup_freight(&mut scenario);

    // Enable dropoff on the SOURCE so we can attempt delivery to the wrong entity.
    owner_enable(
        &mut scenario,
        OWNER_A,
        source_id,
        b"freight_dropoff",
        action::new(vector[
            access_cap::caller_requirement(),
            freight::dropoff_requirement(),
            inventory::deposit_requirement(
                unit_name(),
                false,
                option::some(FUEL),
                option::none(),
                option::none(),
            ),
        ]),
    );

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let (item, receipt) = run_pickup(&mut scenario, source_id, &carrier_cap);
    assert!(freight::destination(&receipt) == dest_id);

    // Advance so the source entity is available again after pickup's return_shared.
    transfer::public_transfer(item, CARRIER);
    transfer::public_transfer(receipt, CARRIER);
    ts::return_to_sender(&scenario, carrier_cap);

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let item = ts::take_from_sender<Item>(&scenario);
    let receipt = ts::take_from_sender<FreightReceipt>(&scenario);
    run_dropoff(&mut scenario, source_id, &carrier_cap, item, receipt);
    ts::return_to_sender(&scenario, carrier_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = freight::EWrongCarrier)]
fun dropoff_rejects_different_carrier() {
    let mut scenario = ts::begin(ADMIN);
    let (source_id, dest_id, _carrier_id) = setup_freight(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut other_character = claim(&mut registry, &acl, 98, scenario.ctx());
    let mut req = other_character.mint_access(OTHER, false, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    other_character.complete_request(req);
    other_character.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let (item, receipt) = run_pickup(&mut scenario, source_id, &carrier_cap);
    transfer::public_transfer(item, OTHER);
    transfer::public_transfer(receipt, OTHER);
    ts::return_to_sender(&scenario, carrier_cap);

    ts::next_tx(&mut scenario, OTHER);
    let other_cap = ts::take_from_sender<AccessCap>(&scenario);
    let item = ts::take_from_sender<Item>(&scenario);
    let receipt = ts::take_from_sender<FreightReceipt>(&scenario);
    run_dropoff(&mut scenario, dest_id, &other_cap, item, receipt);
    ts::return_to_sender(&scenario, other_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = freight::EItemMismatch)]
fun dropoff_rejects_substituted_same_type_item() {
    let mut scenario = ts::begin(ADMIN);
    let (source_id, dest_id, _carrier_id) = setup_freight(&mut scenario);

    owner_enable(
        &mut scenario,
        OWNER_A,
        source_id,
        b"withdraw",
        action::new(vector[
            access_cap::caller_requirement(),
            inventory::withdraw_requirement(
                unit_name(),
                false,
                option::some(FUEL),
                option::none(),
                option::none(),
            ),
        ]),
    );

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let (item, receipt) = run_pickup(&mut scenario, source_id, &carrier_cap);
    transfer::public_transfer(item, CARRIER);
    transfer::public_transfer(receipt, CARRIER);
    ts::return_to_sender(&scenario, carrier_cap);

    // Fresh tx: withdraw a substitute Item of the same type/qty, then try dropoff.
    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let receipt = ts::take_from_sender<FreightReceipt>(&scenario);
    let legit = ts::take_from_sender<Item>(&scenario);

    let mut e = ts::take_shared_by_id<Entity>(&scenario, source_id);
    let mut req = e.interact(string::utf8(b"withdraw"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, &carrier_cap);
    let substitute = inventory::withdraw(&mut e, &mut req, FUEL, QTY, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(e);

    // Keep the legitimate haul parked; try to deliver a different object id.
    transfer::public_transfer(legit, CARRIER);
    transfer::public_transfer(substitute, CARRIER);
    transfer::public_transfer(receipt, CARRIER);
    ts::return_to_sender(&scenario, carrier_cap);

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let receipt = ts::take_from_sender<FreightReceipt>(&scenario);
    // take_from_sender returns an arbitrary matching owned object; pick the
    // substitute by comparing against the receipt-bound item id.
    let first = ts::take_from_sender<Item>(&scenario);
    let second = ts::take_from_sender<Item>(&scenario);
    let (substitute, legit) = if (object::id(&first) == freight::item_id(&receipt)) {
        (second, first)
    } else {
        (first, second)
    };
    transfer::public_transfer(legit, CARRIER);
    run_dropoff(&mut scenario, dest_id, &carrier_cap, substitute, receipt);
    ts::return_to_sender(&scenario, carrier_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = freight::ETenantMismatch)]
fun dropoff_rejects_cross_tenant_destination() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);

    let source = build_storage_unit(&mut scenario, &mut registry, &acl, 1, OWNER_A);
    let (mut dest, mut claim_req) = entity::new(
        &mut registry,
        2,
        string::utf8(b"other-tenant"),
        vector[],
    );
    admin_service::verify_admin(&mut claim_req, &acl, scenario.ctx());
    dest.complete_request(claim_req);
    let mut install_req = inventory::install(&mut dest, unit_name(), 1000, 100, scenario.ctx());
    admin_service::verify_admin(&mut install_req, &acl, scenario.ctx());
    dest.complete_request(install_req);
    let mut mint_req = dest.mint_access(OWNER_B, true, scenario.ctx());
    admin_service::verify_admin(&mut mint_req, &acl, scenario.ctx());
    dest.complete_request(mint_req);

    let source_id = source.id();
    let dest_id = dest.id();
    let _carrier_id = create_carrier(&mut scenario, &mut registry, &acl);
    source.share();
    dest.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    configure_freight_actions(&mut scenario, source_id, dest_id, OWNER_A, OWNER_B);
    stock_main(&mut scenario, OWNER_A, source_id, 100);

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let (item, receipt) = run_pickup(&mut scenario, source_id, &carrier_cap);
    transfer::public_transfer(item, CARRIER);
    transfer::public_transfer(receipt, CARRIER);
    ts::return_to_sender(&scenario, carrier_cap);

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let item = ts::take_from_sender<Item>(&scenario);
    let receipt = ts::take_from_sender<FreightReceipt>(&scenario);
    run_dropoff(&mut scenario, dest_id, &carrier_cap, item, receipt);
    ts::return_to_sender(&scenario, carrier_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = freight::ENotAuthorized)]
fun pickup_without_caller_requirement_aborts() {
    let mut scenario = ts::begin(ADMIN);
    let (source_id, dest_id, _carrier_id) = setup_freight(&mut scenario);

    owner_enable(
        &mut scenario,
        OWNER_A,
        source_id,
        b"freight_pickup_no_caller",
        action::new(vector[
            inventory::withdraw_requirement(
                unit_name(),
                false,
                option::some(FUEL),
                option::none(),
                option::none(),
            ),
            freight::pickup_requirement(dest_id),
        ]),
    );

    ts::next_tx(&mut scenario, CARRIER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, source_id);
    let mut req = e.interact(string::utf8(b"freight_pickup_no_caller"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    let item = inventory::withdraw(&mut e, &mut req, FUEL, QTY, scenario.ctx());
    let receipt = freight::pickup(&e, &mut req, &item, scenario.ctx());
    transfer::public_transfer(item, CARRIER);
    transfer::public_transfer(receipt, CARRIER);
    e.complete_request(req);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = inventory::EQuantityAboveMax)]
fun inventory_quantity_bounds_still_enforced() {
    let mut scenario = ts::begin(ADMIN);
    let (source_id, dest_id, _carrier_id) = setup_freight(&mut scenario);

    owner_enable(
        &mut scenario,
        OWNER_A,
        source_id,
        b"freight_pickup_bounded",
        action::new(vector[
            access_cap::caller_requirement(),
            inventory::withdraw_requirement(
                unit_name(),
                false,
                option::some(FUEL),
                option::none(),
                option::some(5),
            ),
            freight::pickup_requirement(dest_id),
        ]),
    );

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, source_id);
    let mut req = e.interact(string::utf8(b"freight_pickup_bounded"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, &carrier_cap);
    let item = inventory::withdraw(&mut e, &mut req, FUEL, QTY, scenario.ctx());
    let receipt = freight::pickup(&e, &mut req, &item, scenario.ctx());
    transfer::public_transfer(item, CARRIER);
    transfer::public_transfer(receipt, CARRIER);
    e.complete_request(req);
    ts::return_to_sender(&scenario, carrier_cap);
    ts::return_shared(e);
    scenario.end();
}

/// Skipping `freight::dropoff` leaves a non-module-scoped Dropoff requirement next;
/// `inventory::deposit` reads the module name off `req.next()` before type-checking
/// and aborts with `ERequirementNotModuleScoped`.
#[test, expected_failure(abort_code = entity::ERequirementNotModuleScoped)]
fun dropoff_action_rejects_skipping_receipt_validation() {
    let mut scenario = ts::begin(ADMIN);
    let (source_id, dest_id, _carrier_id) = setup_freight(&mut scenario);

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let (item, receipt) = run_pickup(&mut scenario, source_id, &carrier_cap);
    transfer::public_transfer(item, CARRIER);
    transfer::public_transfer(receipt, CARRIER);
    ts::return_to_sender(&scenario, carrier_cap);

    ts::next_tx(&mut scenario, CARRIER);
    let carrier_cap = ts::take_from_sender<AccessCap>(&scenario);
    let item = ts::take_from_sender<Item>(&scenario);
    let receipt = ts::take_from_sender<FreightReceipt>(&scenario);
    // Park the receipt; attempt deposit without consuming it.
    transfer::public_transfer(receipt, CARRIER);

    let mut e = ts::take_shared_by_id<Entity>(&scenario, dest_id);
    let mut req = e.interact(string::utf8(b"freight_dropoff"), scenario.ctx());
    location_service::verify_proximity(&mut req, vector[]);
    access_cap::verify_caller(&mut req, &carrier_cap);
    inventory::deposit(&mut e, &mut req, item, scenario.ctx());
    e.complete_request(req);
    ts::return_to_sender(&scenario, carrier_cap);
    ts::return_shared(e);
    scenario.end();
}
