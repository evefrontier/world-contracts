#[test_only]
module killmail::record_tests;

use character::identity;
use core::{
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    entity_key::{Self, EntityKey},
    object_registry::ObjectRegistry,
    test_helpers::{setup, tenant}
};
use killmail::record::{Self, KillmailCreated};
use std::string::{Self, String};
use sui::{bcs, event, hash, test_scenario as ts};

// Test constants
const ADMIN: address = @0xA;
const OWNER: address = @0xB;
const PLAYER: address = @0xC;

const KILLMAIL_ID_1: u64 = 1001;
const KILLMAIL_ID_2: u64 = 1002;
const KILLMAIL: vector<u8> = b"killmail";

const KILLER_GAME_ID: u64 = 2001;
const VICTIM_GAME_ID: u64 = 2002;
const REPORTER_GAME_ID: u64 = 2003;
const NON_CHARACTER_GAME_ID: u64 = 2004;

const TRIBE_ID: u32 = 7;

const SOLAR_SYSTEM_ID_1: u64 = 300001;

const TIMESTAMP_1: u64 = 1640995200; // 2022-01-01 00:00:00 UTC

const LOSS_TYPE_SHIP: u8 = 1;
const LOSS_TYPE_STRUCTURE: u8 = 2;

/// === Test Cases: Success ===
#[test]
fun create_killmail_success() {
    let mut scenario = setup_reporter();
    let killmail_id = create_killmail(
        &mut scenario,
        ADMIN,
        reporter_key(),
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    assert!(event::events_by_type<KillmailCreated>().length() == 1);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = ts::take_shared<ObjectRegistry>(&scenario);
        let key = killmail_key(KILLMAIL_ID_1);
        assert!(registry.exists(key));
        assert!(object::id_to_address(&killmail_id) == registry.derive_id(key));

        let km = ts::take_shared_by_id<Entity>(&scenario, killmail_id);
        assert!(km.key() == key);
        assert!(record::killer_id(&km) == entity_key::new(KILLER_GAME_ID, tenant()));
        assert!(record::victim_id(&km) == entity_key::new(VICTIM_GAME_ID, tenant()));
        assert!(record::reported_by_character_id(&km) == reporter_key());
        assert!(record::solar_system_id(&km) == entity_key::new(SOLAR_SYSTEM_ID_1, tenant()));
        assert!(record::kill_timestamp(&km) == TIMESTAMP_1);
        assert!(record::is_ship_loss(&km));
        assert!(!record::is_structure_loss(&km));

        ts::return_shared(km);
        ts::return_shared(registry);
    };

    ts::end(scenario);
}

#[test]
fun create_killmail_structure_loss() {
    let mut scenario = setup_reporter();
    let killmail_id = create_killmail(
        &mut scenario,
        ADMIN,
        reporter_key(),
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_STRUCTURE,
        SOLAR_SYSTEM_ID_1,
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let km = ts::take_shared_by_id<Entity>(&scenario, killmail_id);
        assert!(record::is_structure_loss(&km));
        assert!(!record::is_ship_loss(&km));
        ts::return_shared(km);
    };

    ts::end(scenario);
}

#[test]
fun create_multiple_killmails() {
    let mut scenario = setup_reporter();
    let id_1 = create_killmail(
        &mut scenario,
        ADMIN,
        reporter_key(),
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    // Second killmail swaps killer and victim and loses a structure.
    let id_2 = create_killmail(
        &mut scenario,
        ADMIN,
        reporter_key(),
        KILLMAIL_ID_2,
        VICTIM_GAME_ID,
        KILLER_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_STRUCTURE,
        SOLAR_SYSTEM_ID_1,
    );
    assert!(id_1 != id_2);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let km_1 = ts::take_shared_by_id<Entity>(&scenario, id_1);
        assert!(km_1.key() == killmail_key(KILLMAIL_ID_1));
        assert!(record::killer_id(&km_1) == entity_key::new(KILLER_GAME_ID, tenant()));
        assert!(record::victim_id(&km_1) == entity_key::new(VICTIM_GAME_ID, tenant()));
        assert!(record::is_ship_loss(&km_1));

        let km_2 = ts::take_shared_by_id<Entity>(&scenario, id_2);
        assert!(km_2.key() == killmail_key(KILLMAIL_ID_2));
        assert!(record::killer_id(&km_2) == entity_key::new(VICTIM_GAME_ID, tenant()));
        assert!(record::victim_id(&km_2) == entity_key::new(KILLER_GAME_ID, tenant()));
        assert!(record::is_structure_loss(&km_2));

        ts::return_shared(km_1);
        ts::return_shared(km_2);
    };

    ts::end(scenario);
}

#[test]
fun uninstall_removes_killmail() {
    let mut scenario = setup_reporter();
    let killmail_id = create_killmail(
        &mut scenario,
        ADMIN,
        reporter_key(),
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut km = ts::take_shared_by_id<Entity>(&scenario, killmail_id);
        let acl = ts::take_shared<AdminACL>(&scenario);
        let mut req = record::uninstall(&mut km, scenario.ctx());
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        km.complete_request(req);
        assert!(!km.has_component(record::component_id()));
        ts::return_shared(acl);
        ts::return_shared(km);
    };

    ts::end(scenario);
}

/// === Test Cases: Failure ===
#[test, expected_failure(abort_code = entity::EEntityAlreadyExists)]
fun duplicate_killmail_aborts() {
    let mut scenario = setup_reporter();
    create_killmail(
        &mut scenario,
        ADMIN,
        reporter_key(),
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
        reporter_key(),
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EInvalidKillTime)]
fun create_killmail_zero_kill_time() {
    let mut scenario = setup_reporter();
    create_killmail(
        &mut scenario,
        ADMIN,
        reporter_key(),
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
    let mut scenario = setup_reporter();
    create_killmail(
        &mut scenario,
        ADMIN,
        reporter_key(),
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
    let mut scenario = setup_reporter();
    create_killmail(
        &mut scenario,
        ADMIN,
        reporter_key(),
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        3,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun create_killmail_not_admin() {
    let mut scenario = setup_reporter();
    // PLAYER is not on the admin list
    create_killmail(
        &mut scenario,
        PLAYER,
        reporter_key(),
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EReporterNotCharacter)]
fun create_killmail_reporter_without_identity() {
    let mut scenario = setup_reporter();

    // A bare entity with no identity component installed.
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = ts::take_shared<ObjectRegistry>(&scenario);
    let acl = ts::take_shared<AdminACL>(&scenario);
    let (mut bare, mut req) = entity::new(&mut registry, NON_CHARACTER_GAME_ID, tenant());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    bare.complete_request(req);
    bare.share();
    ts::return_shared(acl);
    ts::return_shared(registry);

    create_killmail(
        &mut scenario,
        ADMIN,
        entity_key::new(NON_CHARACTER_GAME_ID, tenant()),
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EWrongTenant)]
fun create_killmail_reporter_wrong_tenant() {
    let mut scenario = setup_reporter();

    // A valid character, but in a different tenant from the killmail.
    ts::next_tx(&mut scenario, ADMIN);
    let other_tenant = string::utf8(b"other-tenant");
    create_character(&mut scenario, REPORTER_GAME_ID, other_tenant, TRIBE_ID, OWNER);

    create_killmail(
        &mut scenario,
        ADMIN,
        entity_key::new(REPORTER_GAME_ID, other_tenant),
        KILLMAIL_ID_1,
        KILLER_GAME_ID,
        VICTIM_GAME_ID,
        TIMESTAMP_1,
        LOSS_TYPE_SHIP,
        SOLAR_SYSTEM_ID_1,
    );
    abort
}

#[test, expected_failure(abort_code = record::EComponentMissing)]
fun uninstall_without_killmail_aborts() {
    let mut scenario = setup_reporter();

    ts::next_tx(&mut scenario, ADMIN);
    let registry = ts::take_shared<ObjectRegistry>(&scenario);
    let reporter_id = object::id_from_address(registry.derive_id(reporter_key()));
    let mut reporter = ts::take_shared_by_id<Entity>(&scenario, reporter_id);
    let _req = record::uninstall(&mut reporter, scenario.ctx());
    abort
}

/// === Test Helpers ===
/// Setup the registries and create the reporter character.
fun setup_reporter(): ts::Scenario {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    create_character(&mut scenario, REPORTER_GAME_ID, tenant(), TRIBE_ID, OWNER);
    scenario
}

fun reporter_key(): EntityKey {
    entity_key::new(REPORTER_GAME_ID, tenant())
}

/// Killmail entity id: first 8 bytes (LE) of `blake2b256(bcs(game_id) ++ "killmail")`.
fun killmail_id(game_id: u64): u64 {
    let mut bytes = bcs::to_bytes(&game_id);
    bytes.append(KILLMAIL);
    let mut b = bcs::new(hash::blake2b256(&bytes));
    b.peel_u64()
}

fun killmail_key(game_id: u64): EntityKey {
    entity_key::new(killmail_id(game_id), tenant())
}

/// Helper to create one character (used as the reporter)
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

/// One tx, as the game server's PTB: `sender` claims a killmail entity, installs the
/// killmail component on it, and shares it. Returns the killmail entity's id.
fun create_killmail(
    scenario: &mut ts::Scenario,
    sender: address,
    reporter: EntityKey,
    killmail_game_id: u64,
    killer_id: u64,
    victim_id: u64,
    timestamp: u64,
    loss_type: u8,
    solar_system_id: u64,
): ID {
    scenario.next_tx(sender);
    let mut registry = ts::take_shared<ObjectRegistry>(scenario);
    let acl = ts::take_shared<AdminACL>(scenario);
    let reporter_id = object::id_from_address(registry.derive_id(reporter));
    let reporter = ts::take_shared_by_id<Entity>(scenario, reporter_id);

    let (mut killmail, mut req) = entity::new(
        &mut registry,
        killmail_id(killmail_game_id),
        tenant(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    killmail.complete_request(req);

    let mut req = record::install(
        &mut killmail,
        &reporter,
        killer_id,
        victim_id,
        timestamp,
        loss_type,
        solar_system_id,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    killmail.complete_request(req);

    let killmail_id = killmail.id();
    killmail.share();
    ts::return_shared(reporter);
    ts::return_shared(acl);
    ts::return_shared(registry);
    killmail_id
}
