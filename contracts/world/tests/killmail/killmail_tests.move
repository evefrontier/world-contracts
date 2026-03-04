#[test_only]
module world::killmail_tests;

use std::string::utf8;
use sui::test_scenario as ts;
use world::{
    access::AdminACL,
    character::{Character},
    killmail,
    object_registry::ObjectRegistry,
    test_helpers::{Self, admin, tenant, user_a},
};

// Test constants
const KILLMAIL_ID_1: u64 = 1001;
const KILLMAIL_ID_2: u64 = 1002;

const SOLAR_SYSTEM_ID_1: u64 = 300001;

const TIMESTAMP_1: u64 = 1640995200; // 2022-01-01 00:00:00 UTC

const LOSS_TYPE_SHIP: u8 = 0;
const LOSS_TYPE_STRUCTURE: u8 = 1;

// Helper to setup test environment
fun setup(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
}

// Helper to create two characters (killer and victim) for killmail tests
fun setup_two_characters(ts: &mut ts::Scenario): (ID, ID) {
    ts::next_tx(ts, admin());
    {
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let admin_acl = ts::take_shared<AdminACL>(ts);

        let killer = world::character::create_character(
            &mut registry,
            &admin_acl,
            2001, // killer game character id
            tenant(),
            100,
            user_a(),
            utf8(b"killer"),
            ts::ctx(ts),
        );
        let killer_id = object::id(&killer);
        killer.share_character(&admin_acl, ts::ctx(ts));

        let victim = world::character::create_character(
            &mut registry,
            &admin_acl,
            2002, // victim game character id
            tenant(),
            100,
            user_a(),
            utf8(b"victim"),
            ts::ctx(ts),
        );
        let victim_id = object::id(&victim);
        victim.share_character(&admin_acl, ts::ctx(ts));

        ts::return_shared(registry);
        ts::return_shared(admin_acl);
        (killer_id, victim_id)
    }
}

// Test creating a killmail
#[test]
fun create_killmail() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let (killer_id, victim_id) = setup_two_characters(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let killer = ts::take_shared_by_id<Character>(&ts, killer_id);
        let victim = ts::take_shared_by_id<Character>(&ts, victim_id);

        killmail::create_killmail(
            &admin_acl,
            KILLMAIL_ID_1,
            &killer,
            &victim,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts.ctx(),
        );

        ts::return_shared(victim);
        ts::return_shared(killer);
        ts::return_shared(admin_acl);
    };

    ts::end(ts);
}

// Test creating multiple killmails
#[test]
fun create_multiple_killmails() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let (killer_id, victim_id) = setup_two_characters(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let killer = ts::take_shared_by_id<Character>(&ts, killer_id);
        let victim = ts::take_shared_by_id<Character>(&ts, victim_id);

        killmail::create_killmail(
            &admin_acl,
            KILLMAIL_ID_1,
            &killer,
            &victim,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts.ctx(),
        );

        killmail::create_killmail(
            &admin_acl,
            KILLMAIL_ID_2,
            &victim,
            &killer,
            TIMESTAMP_1,
            LOSS_TYPE_STRUCTURE,
            SOLAR_SYSTEM_ID_1,
            ts.ctx(),
        );

        ts::return_shared(victim);
        ts::return_shared(killer);
        ts::return_shared(admin_acl);
    };

    ts::end(ts);
}

// Test error cases - invalid killmail ID
#[test]
#[expected_failure(abort_code = killmail::EKillmailIdEmpty)]
fun create_killmail_invalid_id() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let (killer_id, victim_id) = setup_two_characters(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let killer = ts::take_shared_by_id<Character>(&ts, killer_id);
        let victim = ts::take_shared_by_id<Character>(&ts, victim_id);

        killmail::create_killmail(
            &admin_acl,
            0, // Invalid ID
            &killer,
            &victim,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts.ctx(),
        );
        abort 999
    }
}

// Test error cases - invalid loss type
#[test]
#[expected_failure(abort_code = killmail::EInvalidLossType)]
fun create_killmail_invalid_loss_type() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);
    let (killer_id, victim_id) = setup_two_characters(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let killer = ts::take_shared_by_id<Character>(&ts, killer_id);
        let victim = ts::take_shared_by_id<Character>(&ts, victim_id);

        killmail::create_killmail(
            &admin_acl,
            KILLMAIL_ID_1,
            &killer,
            &victim,
            TIMESTAMP_1,
            2, // Invalid loss type (only 0 or 1 allowed)
            SOLAR_SYSTEM_ID_1,
            ts.ctx(),
        );
        abort 999
    }
}

// Test error cases - tenant mismatch between killer and victim
#[test]
#[expected_failure(abort_code = killmail::ETenantMismatch)]
fun create_killmail_tenant_mismatch() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);

    let killer_id;
    let victim_id;
    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<ObjectRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);

        let killer = world::character::create_character(
            &mut registry,
            &admin_acl,
            2101,
            utf8(b"TENANT_A"),
            100,
            user_a(),
            utf8(b"killer-a"),
            ts.ctx(),
        );
        killer_id = object::id(&killer);
        killer.share_character(&admin_acl, ts.ctx());

        let victim = world::character::create_character(
            &mut registry,
            &admin_acl,
            2102,
            utf8(b"TENANT_B"),
            100,
            user_a(),
            utf8(b"victim-b"),
            ts.ctx(),
        );
        victim_id = object::id(&victim);
        victim.share_character(&admin_acl, ts.ctx());

        ts::return_shared(registry);
        ts::return_shared(admin_acl);
    };

    ts::next_tx(&mut ts, admin());
    {
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        let killer = ts::take_shared_by_id<Character>(&ts, killer_id);
        let victim = ts::take_shared_by_id<Character>(&ts, victim_id);

        killmail::create_killmail(
            &admin_acl,
            KILLMAIL_ID_1,
            &killer,
            &victim,
            TIMESTAMP_1,
            LOSS_TYPE_SHIP,
            SOLAR_SYSTEM_ID_1,
            ts.ctx(),
        );
        abort 999
    }
}
