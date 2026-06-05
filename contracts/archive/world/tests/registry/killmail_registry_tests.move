#[test_only]
module world::killmail_registry_tests;

use sui::test_scenario as ts;
use world::{in_game_id, killmail_registry::{Self, KillmailRegistry}, test_helpers::{Self, admin}};

// Registry is created by setup_world and used by killmail tests.
// These tests verify the registry's public API in isolation.

#[test]
fun object_exists_returns_false_for_unused_key() {
    let mut ts = ts::begin(@0x0);
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let registry = ts::take_shared<KillmailRegistry>(&ts);
        let key = in_game_id::create_key(1, test_helpers::tenant());
        assert!(!killmail_registry::object_exists(&registry, key), 0);
        ts::return_shared(registry);
    };

    ts::end(ts);
}

#[test]
fun registry_can_be_taken_after_setup() {
    let mut ts = ts::begin(@0x0);
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let registry = ts::take_shared<KillmailRegistry>(&ts);
        // Registry exists and is shared; object_exists is callable
        let key = in_game_id::create_key(999, test_helpers::tenant());
        assert!(!killmail_registry::object_exists(&registry, key), 0);
        ts::return_shared(registry);
    };

    ts::end(ts);
}
