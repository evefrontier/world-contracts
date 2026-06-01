#[test_only]
module world::killmail_tests;

use std::string::utf8;
use sui::test_scenario as ts;
use world::{
    access::AdminACL,
    character::Character,
    killmail,
    killmail_registry::KillmailRegistry,
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, tenant, user_a}
};

// Test constants
const KILLMAIL_ID_1: u64 = 1001;
const KILLMAIL_ID_2: u64 = 1002;

const KILLER_GAME_ID: u64 = 2001;
const VICTIM_GAME_ID: u64 = 2002;

const SOLAR_SYSTEM_ID_1: u64 = 300001;

const TIMESTAMP_1: u64 = 1640995200; // 2022-01-01 00:00:00 UTC

const LOSS_TYPE_SHIP: u8 = 1;
const LOSS_TYPE_STRUCTURE: u8 = 2;

// Helper to setup test environment
fun setup(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
}

// Helper to create one character (used as reported_by_character; killer_id/victim_id are just u64s in the API)
fun setup_reporter_character(ts: &mut ts::Scenario): ID {
    ts::next_tx(ts, admin());
    {
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let admin_acl = ts::take_shared<AdminACL>(ts);

        let reporter = world::character::create_character(
            &mut registry,
            &admin_acl,
            2001,
            tenant(),
            100,
            user_a(),
            utf8(b"reporter"),
            ts::ctx(ts),
        );
        let reporter_id = object::id(&reporter);
        world::character::share_character(reporter, &admin_acl, ts::ctx(ts));

        ts::return_shared(registry);
        ts::return_shared(admin_acl);
        reporter_id
    }
}

// Test creating a killmail
#[test]
fun create_killmail() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let reporter_id = setup_reporter_character(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<KillmailRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let reporter = ts::take_shared_by_id<Character>(&ts, reporter_id);

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            KILLMAIL_ID_1,
            KILLER_GAME_ID,
            VICTIM_GAME_ID,
            &reporter,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts::ctx(&mut ts),
        );

        ts::return_shared(reporter);
        ts::return_shared(admin_acl);
        ts::return_shared(registry);
    };

    ts::end(ts);
}

// Test creating multiple killmails
#[test]
fun create_multiple_killmails() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let reporter_id = setup_reporter_character(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<KillmailRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let reporter = ts::take_shared_by_id<Character>(&ts, reporter_id);

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            KILLMAIL_ID_1,
            KILLER_GAME_ID,
            VICTIM_GAME_ID,
            &reporter,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts::ctx(&mut ts),
        );

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            KILLMAIL_ID_2,
            VICTIM_GAME_ID,
            KILLER_GAME_ID,
            &reporter,
            TIMESTAMP_1,
            LOSS_TYPE_STRUCTURE,
            SOLAR_SYSTEM_ID_1,
            ts::ctx(&mut ts),
        );

        ts::return_shared(reporter);
        ts::return_shared(admin_acl);
        ts::return_shared(registry);
    };

    ts::end(ts);
}

// Test error cases - invalid killmail item_id (0)
#[test]
#[expected_failure(abort_code = killmail::EKillmailIdEmpty)]
fun create_killmail_invalid_id() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let reporter_id = setup_reporter_character(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<KillmailRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let reporter = ts::take_shared_by_id<Character>(&ts, reporter_id);

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            0,
            KILLER_GAME_ID,
            VICTIM_GAME_ID,
            &reporter,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts::ctx(&mut ts),
        );
        abort 999
    }
}

// Test error cases - invalid loss type (0 = LOSS_UNSPECIFIED, not allowed)
#[test]
#[expected_failure(abort_code = killmail::EInvalidLossType)]
fun create_killmail_invalid_loss_type() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let reporter_id = setup_reporter_character(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<KillmailRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let reporter = ts::take_shared_by_id<Character>(&ts, reporter_id);

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            KILLMAIL_ID_1,
            KILLER_GAME_ID,
            VICTIM_GAME_ID,
            &reporter,
            TIMESTAMP_1,
            0,
            SOLAR_SYSTEM_ID_1,
            ts::ctx(&mut ts),
        );
        abort 999
    }
}

// Test error cases - invalid killer_id (0)
#[test]
#[expected_failure(abort_code = killmail::ECharacterIdEmpty)]
fun create_killmail_invalid_killer_id() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let reporter_id = setup_reporter_character(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<KillmailRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let reporter = ts::take_shared_by_id<Character>(&ts, reporter_id);

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            KILLMAIL_ID_1,
            0,
            VICTIM_GAME_ID,
            &reporter,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts::ctx(&mut ts),
        );
        abort 999
    }
}

// Test error cases - invalid solar_system_id (0)
#[test]
#[expected_failure(abort_code = killmail::ESolarSystemIdEmpty)]
fun create_killmail_invalid_solar_system_id() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let reporter_id = setup_reporter_character(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<KillmailRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let reporter = ts::take_shared_by_id<Character>(&ts, reporter_id);

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            KILLMAIL_ID_1,
            KILLER_GAME_ID,
            VICTIM_GAME_ID,
            &reporter,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            0,
            ts::ctx(&mut ts),
        );
        abort 999
    }
}

// Test error cases - invalid kill_timestamp (0)
#[test]
#[expected_failure(abort_code = killmail::EInvalidTimestamp)]
fun create_killmail_invalid_timestamp() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let reporter_id = setup_reporter_character(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<KillmailRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let reporter = ts::take_shared_by_id<Character>(&ts, reporter_id);

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            KILLMAIL_ID_1,
            KILLER_GAME_ID,
            VICTIM_GAME_ID,
            &reporter,
            0,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts::ctx(&mut ts),
        );
        abort 999
    }
}

// Test error cases - duplicate killmail item_id (EKillmailAlreadyExists)
#[test]
#[expected_failure(abort_code = killmail::EKillmailAlreadyExists)]
fun create_killmail_duplicate_item_id() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let reporter_id = setup_reporter_character(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<KillmailRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let reporter = ts::take_shared_by_id<Character>(&ts, reporter_id);

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            KILLMAIL_ID_1,
            KILLER_GAME_ID,
            VICTIM_GAME_ID,
            &reporter,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts::ctx(&mut ts),
        );

        killmail::create_killmail(
            &mut registry,
            &admin_acl,
            KILLMAIL_ID_1,
            KILLER_GAME_ID,
            VICTIM_GAME_ID,
            &reporter,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts::ctx(&mut ts),
        );
        abort 999
    }
}
