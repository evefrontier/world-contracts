#[test_only]
module world::killmail_tests;

use sui::test_scenario as ts;
use world::{access::AdminCap, in_game_id, killmail, test_helpers::{Self, admin}};

// Test constants
const KILLMAIL_ID_1: u64 = 1001;
const KILLMAIL_ID_2: u64 = 1002;

const CHARACTER_ID_1: u64 = 2001;
const CHARACTER_ID_2: u64 = 2002;

const SOLAR_SYSTEM_ID_1: u64 = 300001;

const TENANT: vector<u8> = b"test";

const TIMESTAMP_1: u64 = 1640995200; // 2022-01-01 00:00:00 UTC

// Helper to setup test environment
fun setup(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
}

// Test creating a killmail
#[test]
fun test_create_killmail() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_address<AdminCap>(&ts, admin());

        // Create a killmail - this creates a shared object on-chain
        killmail::create_killmail(
            &admin_cap,
            in_game_id::create_key(KILLMAIL_ID_1, std::string::utf8(TENANT)),
            in_game_id::create_key(CHARACTER_ID_1, std::string::utf8(TENANT)),
            in_game_id::create_key(CHARACTER_ID_2, std::string::utf8(TENANT)),
            TIMESTAMP_1,
            killmail::ship(),
            in_game_id::create_key(SOLAR_SYSTEM_ID_1, std::string::utf8(TENANT)),
            ts.ctx(),
        );

        ts::return_to_address(admin(), admin_cap);
    };

    ts::end(ts);
}

// Test creating multiple killmails
#[test]
fun test_create_multiple_killmails() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_address<AdminCap>(&ts, admin());

        // Create first killmail
        killmail::create_killmail(
            &admin_cap,
            in_game_id::create_key(KILLMAIL_ID_1, std::string::utf8(TENANT)),
            in_game_id::create_key(CHARACTER_ID_1, std::string::utf8(TENANT)),
            in_game_id::create_key(CHARACTER_ID_2, std::string::utf8(TENANT)),
            TIMESTAMP_1,
            killmail::ship(),
            in_game_id::create_key(SOLAR_SYSTEM_ID_1, std::string::utf8(TENANT)),
            ts.ctx(),
        );

        // Create second killmail
        killmail::create_killmail(
            &admin_cap,
            in_game_id::create_key(KILLMAIL_ID_2, std::string::utf8(TENANT)),
            in_game_id::create_key(CHARACTER_ID_2, std::string::utf8(TENANT)),
            in_game_id::create_key(CHARACTER_ID_1, std::string::utf8(TENANT)),
            TIMESTAMP_1,
            killmail::structure(),
            in_game_id::create_key(SOLAR_SYSTEM_ID_1, std::string::utf8(TENANT)),
            ts.ctx(),
        );

        ts::return_to_address(admin(), admin_cap);
    };

    ts::end(ts);
}

// Test error cases - invalid killmail ID
#[test]
#[expected_failure(abort_code = killmail::EKillmailIdEmpty)]
fun test_create_killmail_invalid_id() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_address<AdminCap>(&ts, admin());

        // Try to create killmail with invalid ID (0)
        killmail::create_killmail(
            &admin_cap,
            in_game_id::create_key(0, std::string::utf8(TENANT)), // Invalid ID
            in_game_id::create_key(CHARACTER_ID_1, std::string::utf8(TENANT)),
            in_game_id::create_key(CHARACTER_ID_2, std::string::utf8(TENANT)),
            TIMESTAMP_1,
            killmail::ship(),
            in_game_id::create_key(SOLAR_SYSTEM_ID_1, std::string::utf8(TENANT)),
            ts.ctx(),
        );

        ts::return_to_address(admin(), admin_cap);
    };

    ts::end(ts);
}

// Test error cases - invalid character ID
#[test]
#[expected_failure(abort_code = killmail::ECharacterIdEmpty)]
fun test_create_killmail_invalid_killer_id() {
    let mut ts = ts::begin(@0x0);
    setup(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_address<AdminCap>(&ts, admin());

        // Try to create killmail with invalid killer ID (0)
        killmail::create_killmail(
            &admin_cap,
            in_game_id::create_key(KILLMAIL_ID_1, std::string::utf8(TENANT)),
            in_game_id::create_key(0, std::string::utf8(TENANT)), // Invalid killer ID
            in_game_id::create_key(CHARACTER_ID_2, std::string::utf8(TENANT)),
            TIMESTAMP_1,
            killmail::ship(),
            in_game_id::create_key(SOLAR_SYSTEM_ID_1, std::string::utf8(TENANT)),
            ts.ctx(),
        );

        ts::return_to_address(admin(), admin_cap);
    };

    ts::end(ts);
}
