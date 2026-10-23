#[test_only]
module killmail::record_tests;

use character::identity;
use core::{
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    entity_key,
    object_registry::{Self, ObjectRegistry},
    test_helpers::{create_entity, setup, tenant, take_acl}
};
use killmail::{record::{Self, Killmail}, registry::{Self, KillmailRegistry}};
use std::string::{Self, String};
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

/// === Test Cases: Success ===
#[test]
fun create_killmail_success() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );

    let effects = ts::next_tx(&mut scenario, ADMIN);
    assert!(effects.num_user_events() == 1);
    {
        let km = ts::take_shared<Killmail>(&scenario);
        let key = entity_key::new(KILLMAIL_ID_1, tenant());
        assert!(km.key() == key);
        assert!(km.killer_id() == entity_key::new(KILLER_GAME_ID, tenant()));
        assert!(km.victim_id() == entity_key::new(VICTIM_GAME_ID, tenant()));
        assert!(km.reported_by_character_id() == entity_key::new(REPORTER_GAME_ID, tenant()));
        assert!(km.solar_system_id() == entity_key::new(SOLAR_SYSTEM_ID_1, tenant()));
        assert!(km.kill_timestamp() == TIMESTAMP_1);
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
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_STRUCTURE,
        SOLAR_SYSTEM_ID_1,
    );

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

#[test]
fun create_multiple_killmails() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
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
        let key_1 = entity_key::new(KILLMAIL_ID_1, tenant());
        let key_2 = entity_key::new(KILLMAIL_ID_2, tenant());
        assert!(registry.exists(key_1));
        assert!(registry.exists(key_2));
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

/// === Test Cases: Failure ===
#[test, expected_failure(abort_code = record::EKillmailAlreadyExists)]
fun duplicate_killmail_aborts() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EKillmailIdEmpty)]
fun create_killmail_invalid_id() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    create_killmail(
        &mut scenario,
        ADMIN,
        0,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EInvalidLossType)]
fun create_killmail_invalid_loss_type() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        0,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EInvalidLossType)]
fun create_killmail_unknown_loss_type() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        3,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EKillerIdEmpty)]
fun create_killmail_invalid_killer_id() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
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
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
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

#[test, expected_failure(abort_code = record::ENotSponsor)]
fun create_killmail_not_sponsor() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    // PLAYER is not on the sponsor list
    create_killmail(
        &mut scenario,
        PLAYER,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::ESolarSystemIdEmpty)]
fun create_killmail_invalid_solar_system_id() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
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
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
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

#[test, expected_failure(abort_code = record::EReporterNotCharacter)]
fun create_killmail_reporter_not_character() {
    let mut scenario = ts::begin(ADMIN);
    record_test_setup(&mut scenario);

    // A plain entity with no Identity component installed
    create_entity(&mut scenario, REPORTER_GAME_ID);
    create_killmail(
        &mut scenario,
        ADMIN,
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

/// === Test Helpers ===
/// Setup the test environment for killmail record tests
fun record_test_setup(scenario: &mut ts::Scenario) {
    setup(scenario);
    registry::init_for_testing(scenario.ctx());

    ensure_admin_sponsors(scenario);
}

/// Put `ADMIN` on the sponsor list.
fun ensure_admin_sponsors(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    let mut acl = take_acl(scenario);
    if (!admin_service::is_sponsor(&acl, ADMIN)) {
        admin_service::add_sponsors(&mut acl, vector[ADMIN], scenario.ctx());
    };
    ts::return_shared(acl);
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

/// One tx: `sender` reports a killmail with the shared reporter character.
fun create_killmail(
    scenario: &mut ts::Scenario,
    sender: address,
    item_id: u64,
    killer_id: u64,
    victim_id: u64,
    timestamp: u64,
    loss_type: u8,
    solar_system_id: u64,
) {
    scenario.next_tx(sender);
    let reporter = ts::take_shared<Entity>(scenario);
    let mut registry = ts::take_shared<KillmailRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);

    record::create_killmail(
        &mut registry,
        &reporter,
        &acl,
        item_id,
        killer_id,
        victim_id,
        timestamp,
        loss_type,
        solar_system_id,
        scenario.ctx(),
    );

    ts::return_shared(reporter);
    ts::return_shared(acl);
    ts::return_shared(registry);
}
