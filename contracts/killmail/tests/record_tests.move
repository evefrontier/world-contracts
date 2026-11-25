#[test_only]
module killmail::record_tests;

use character::identity;
use core::{
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    entity_key,
    object_registry::ObjectRegistry,
    request,
    test_helpers::{create_entity, setup, tenant, take_acl}
};
use killmail::{record::{Self, Killmail, KillmailCreated}, registry::{Self, KillmailRegistry}};
use std::string::String;
use sui::{event, test_scenario as ts};

// Test constants
const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const PLAYER: address = @0xC;

const KILLMAIL_ID_1: u64 = 1001;
const KILLMAIL_ID_2: u64 = 1002;

const KILLER_GAME_ID: u64 = 2001;
const VICTIM_GAME_ID: u64 = 2002;
const REPORTER_GAME_ID: u64 = 2003;

const TRIBE_ID: u32 = 7;

const SOLAR_SYSTEM_ID_1: u64 = 300001;

const TIMESTAMP_1: u64 = 1640995200; // 2022-01-01 00:00:00 UTC

const LOSS_TYPE_SHIP: u8 = 1;
const LOSS_TYPE_STRUCTURE: u8 = 2;

/// A foreign issuer, to show completion accepts only this module's requests.
public struct Other() has drop;

// === Success ===

#[test]
fun create_killmail_shares_record_at_derived_address() {
    let mut scenario = begin_with_reporter();
    create_default(&mut scenario, ADMIN, KILLMAIL_ID_1, LOSS_TYPE_SHIP);

    let key = registry::new_key(tenant(), KILLMAIL_ID_1);
    let events = event::events_by_type<KillmailCreated>();
    assert!(events.length() == 1);
    assert!(events[0].created_key() == key);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let km = ts::take_shared<Killmail>(&scenario);
        assert!(km.id() == events[0].created_id());
        assert!(km.key() == key);
        assert!(km.version() == 1);
        assert!(km.killer_id() == entity_key::new(KILLER_GAME_ID, tenant()));
        assert!(km.victim_id() == entity_key::new(VICTIM_GAME_ID, tenant()));
        assert!(km.reported_by_character_id() == entity_key::new(REPORTER_GAME_ID, tenant()));
        assert!(km.solar_system_id() == entity_key::new(SOLAR_SYSTEM_ID_1, tenant()));
        assert!(km.kill_timestamp() == TIMESTAMP_1);
        assert!(km.loss_type() == record::ship());
        assert!(km.is_ship_loss());
        assert!(!km.is_structure_loss());

        let registry = ts::take_shared<KillmailRegistry>(&scenario);
        assert!(registry.exists(key));
        assert!(object::id_to_address(&km.id()) == registry.derive_id(key));
        ts::return_shared(km);
        ts::return_shared(registry);
    };

    ts::end(scenario);
}

#[test]
fun create_killmail_structure_loss() {
    let mut scenario = begin_with_reporter();
    create_default(&mut scenario, ADMIN, KILLMAIL_ID_1, LOSS_TYPE_STRUCTURE);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let km = ts::take_shared<Killmail>(&scenario);
        assert!(km.loss_type() == record::structure());
        assert!(km.is_structure_loss());
        assert!(!km.is_ship_loss());
        ts::return_shared(km);
    };

    ts::end(scenario);
}

#[test, expected_failure(abort_code = record::EWrongVersion)]
fun read_killmail_wrong_version_aborts() {
    let mut scenario = begin_with_reporter();
    create_default(&mut scenario, ADMIN, KILLMAIL_ID_1, LOSS_TYPE_SHIP);

    ts::next_tx(&mut scenario, ADMIN);
    let mut km = ts::take_shared<Killmail>(&scenario);
    km.set_version_for_testing(2);
    km.killer_id();

    abort
}

#[test]
fun create_multiple_killmails() {
    let mut scenario = begin_with_reporter();
    create_default(&mut scenario, ADMIN, KILLMAIL_ID_1, LOSS_TYPE_SHIP);
    // Second killmail swaps killer and victim and loses a structure.
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_2,
        VICTIM_GAME_ID,
        KILLER_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_STRUCTURE,
        SOLAR_SYSTEM_ID_1,
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = ts::take_shared<KillmailRegistry>(&scenario);
        let key_1 = registry::new_key(tenant(), KILLMAIL_ID_1);
        let key_2 = registry::new_key(tenant(), KILLMAIL_ID_2);
        let id_1 = object::id_from_address(registry.derive_id(key_1));
        let id_2 = object::id_from_address(registry.derive_id(key_2));
        assert!(id_1 != id_2);

        let km_1 = ts::take_shared_by_id<Killmail>(&scenario, id_1);
        assert!(km_1.key() == key_1);
        assert!(km_1.killer_id() == entity_key::new(KILLER_GAME_ID, tenant()));
        assert!(km_1.victim_id() == entity_key::new(VICTIM_GAME_ID, tenant()));
        assert!(km_1.is_ship_loss());

        let km_2 = ts::take_shared_by_id<Killmail>(&scenario, id_2);
        assert!(km_2.key() == key_2);
        assert!(km_2.killer_id() == entity_key::new(VICTIM_GAME_ID, tenant()));
        assert!(km_2.victim_id() == entity_key::new(KILLER_GAME_ID, tenant()));
        assert!(km_2.is_structure_loss());

        ts::return_shared(km_1);
        ts::return_shared(km_2);
        ts::return_shared(registry);
    };

    ts::end(scenario);
}

/// Sponsored tx: PLAYER sends, ADMIN pays gas. The gas sponsor is authorized.
#[test]
fun create_killmail_sponsored_tx_uses_gas_sponsor() {
    let mut scenario = begin_with_reporter();

    next_sponsored_tx(&mut scenario, PLAYER, ADMIN);
    submit_killmail(
        &mut scenario,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = ts::take_shared<KillmailRegistry>(&scenario);
        assert!(registry.exists(registry::new_key(tenant(), KILLMAIL_ID_1)));
        ts::return_shared(registry);
    };

    ts::end(scenario);
}

// === Failure: authorization ===

#[test, expected_failure(abort_code = admin_service::EUnauthorizedSponsor)]
fun create_killmail_not_sponsor() {
    let mut scenario = begin_with_reporter();
    // PLAYER is not on the sponsor list
    create_default(&mut scenario, PLAYER, KILLMAIL_ID_1, LOSS_TYPE_SHIP);
    abort
}

/// Sponsored tx: ADMIN sends, PLAYER pays gas. A sponsor sender doesn't help.
#[test, expected_failure(abort_code = admin_service::EUnauthorizedSponsor)]
fun create_killmail_sponsored_tx_non_sponsor_gas_aborts() {
    let mut scenario = begin_with_reporter();

    next_sponsored_tx(&mut scenario, ADMIN, PLAYER);
    submit_killmail(
        &mut scenario,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun complete_without_sponsor_check_aborts() {
    let mut scenario = begin_with_reporter();

    ts::next_tx(&mut scenario, ADMIN);
    let reporter = ts::take_shared<Entity>(&scenario);
    let mut registry = ts::take_shared<KillmailRegistry>(&scenario);
    let (km, req) = record::create_killmail(
        &mut registry,
        &reporter,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    km.complete_killmail(req);
    abort
}

#[test, expected_failure(abort_code = request::EWrongIssuer)]
fun complete_with_foreign_request_aborts() {
    let mut scenario = begin_with_reporter();

    ts::next_tx(&mut scenario, ADMIN);
    let reporter = ts::take_shared<Entity>(&scenario);
    let mut registry = ts::take_shared<KillmailRegistry>(&scenario);
    let (km, req) = record::create_killmail(
        &mut registry,
        &reporter,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    req.destroy();
    km.complete_killmail(request::new_for(internal::permit<Other>(), vector[]));
    abort
}

// === Failure: validation ===

#[test, expected_failure(abort_code = record::EKillmailAlreadyExists)]
fun duplicate_killmail_aborts() {
    let mut scenario = begin_with_reporter();
    create_default(&mut scenario, ADMIN, KILLMAIL_ID_1, LOSS_TYPE_SHIP);
    create_default(&mut scenario, ADMIN, KILLMAIL_ID_1, LOSS_TYPE_SHIP);
    abort
}

#[test, expected_failure(abort_code = registry::EKillmailIdZero)]
fun create_killmail_invalid_id() {
    let mut scenario = begin_with_reporter();
    create_default(&mut scenario, ADMIN, 0, LOSS_TYPE_SHIP);
    abort
}

#[test, expected_failure(abort_code = record::EKillerIdEmpty)]
fun create_killmail_invalid_killer_id() {
    let mut scenario = begin_with_reporter();
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        0,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EVictimIdEmpty)]
fun create_killmail_invalid_victim_id() {
    let mut scenario = begin_with_reporter();
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        0,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::ESolarSystemIdEmpty)]
fun create_killmail_invalid_solar_system_id() {
    let mut scenario = begin_with_reporter();
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        0,
    );
    abort
}

#[test, expected_failure(abort_code = record::EInvalidTimestamp)]
fun create_killmail_invalid_timestamp() {
    let mut scenario = begin_with_reporter();
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        0,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EInvalidLossType)]
fun create_killmail_invalid_loss_type() {
    let mut scenario = begin_with_reporter();
    create_default(&mut scenario, ADMIN, KILLMAIL_ID_1, 0);
    abort
}

#[test, expected_failure(abort_code = record::EInvalidLossType)]
fun create_killmail_unknown_loss_type() {
    let mut scenario = begin_with_reporter();
    create_default(&mut scenario, ADMIN, KILLMAIL_ID_1, 3);
    abort
}

#[test, expected_failure(abort_code = record::EReporterNotCharacter)]
fun create_killmail_reporter_not_character() {
    let mut scenario = begin();

    // A plain entity with no Identity component installed
    create_entity(&mut scenario, REPORTER_GAME_ID);
    create_default(&mut scenario, ADMIN, KILLMAIL_ID_1, LOSS_TYPE_SHIP);
    abort
}

// === Helpers ===

/// Registries, the killmail registry, and ADMIN on the sponsor list.
fun begin(): ts::Scenario {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    registry::init_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, ADMIN);
    let mut acl = take_acl(&scenario);
    admin_service::add_sponsors(&mut acl, vector[ADMIN], scenario.ctx());
    ts::return_shared(acl);
    scenario
}

/// `begin`, plus the reporter character.
fun begin_with_reporter(): ts::Scenario {
    let mut scenario = begin();
    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    scenario
}

/// Start a tx sent by `sender` with `sponsor` paying gas.
fun next_sponsored_tx(scenario: &mut ts::Scenario, sender: address, sponsor: address) {
    let rgp = scenario.ctx().reference_gas_price();
    let builder = ts::ctx_builder_from_sender(sender)
        .set_reference_gas_price(rgp)
        .set_sponsor(sponsor);
    ts::next_with_context(scenario, builder);
}

/// Helper to create one character (used as reported_by_character; killer_id/victim_id are just u64s in the API)
fun create_character(
    scenario: &mut ts::Scenario,
    in_game_id: u64,
    tenant: String,
    tribe_id: u32,
    owner: address,
) {
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);

    let (mut character, mut req) = entity::new(&mut registry, in_game_id, tenant);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    character.complete_request(req);

    let mut req = identity::install(&mut character, tribe_id, owner, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    character.complete_request(req);

    character.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
}

/// A killmail with the default killer, victim, timestamp, and solar system.
fun create_default(scenario: &mut ts::Scenario, sender: address, killmail_id: u64, loss_type: u8) {
    create_killmail(
        scenario,
        sender,
        killmail_id,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        loss_type,
        SOLAR_SYSTEM_ID_1,
    );
}

/// One tx, sent by `sender`: create, verify sponsor, complete.
fun create_killmail(
    scenario: &mut ts::Scenario,
    sender: address,
    killmail_id: u64,
    killer_id: u64,
    victim_id: u64,
    timestamp: u64,
    loss_type: u8,
    solar_system_id: u64,
) {
    scenario.next_tx(sender);
    submit_killmail(
        scenario,
        killmail_id,
        killer_id,
        victim_id,
        timestamp,
        loss_type,
        solar_system_id,
    );
}

/// The full creation flow in the scenario's current tx (caller sets sender/sponsor).
fun submit_killmail(
    scenario: &mut ts::Scenario,
    killmail_id: u64,
    killer_id: u64,
    victim_id: u64,
    timestamp: u64,
    loss_type: u8,
    solar_system_id: u64,
) {
    let reporter = ts::take_shared<Entity>(scenario);
    let mut registry = ts::take_shared<KillmailRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);

    let (km, mut req) = record::create_killmail(
        &mut registry,
        &reporter,
        killmail_id,
        killer_id,
        victim_id,
        timestamp,
        loss_type,
        solar_system_id,
    );
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    km.complete_killmail(req);

    ts::return_shared(reporter);
    ts::return_shared(acl);
    ts::return_shared(registry);
}
