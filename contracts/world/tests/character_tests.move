#[test_only]

module world::character_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::{derived_object, test_scenario as ts};
use world::{
    authority::{Self, AdminCap, OwnerCap},
    character::{Self, Character, CharacterRegistry},
    world::{Self, GovernorCap}
};

const GOVERNOR: address = @0xA;
const ADMIN: address = @0xB;
const USER_A: address = @0xC;
const USER_B: address = @0xD;

// Helper functions

fun setup_world(ts: &mut ts::Scenario) {
    ts::next_tx(ts, GOVERNOR);
    {
        world::init_for_testing(ts::ctx(ts));
        character::init_for_testing(ts::ctx(ts));
    };

    ts::next_tx(ts, GOVERNOR);
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(ts);
        authority::create_admin_cap(&gov_cap, ADMIN, ts::ctx(ts));
        ts::return_to_sender(ts, gov_cap);
    };
}

fun setup_owner_cap(ts: &mut ts::Scenario, owner: address, character_id: ID) {
    ts::next_tx(ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let owner_cap = authority::create_owner_cap(&admin_cap, character_id, ts::ctx(ts));
        authority::transfer_owner_cap(owner_cap, &admin_cap, owner);
        ts::return_to_sender(ts, admin_cap);
    };
}

fun setup_character(ts: &mut ts::Scenario, game_id: u32, tribe_id: u32, name: vector<u8>) {
    ts::next_tx(ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let mut registry = ts::take_shared<CharacterRegistry>(ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            tribe_id,
            utf8(name),
            ts::ctx(ts),
        );
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(ts, admin_cap);
    };
}

#[test]
fun character_registry_initialized() {
    let mut ts = ts::begin(GOVERNOR);
    ts::next_tx(&mut ts, GOVERNOR);
    {
        character::init_for_testing(ts::ctx(&mut ts));
    };

    ts::next_tx(&mut ts, GOVERNOR);
    {
        let registry = ts::take_shared<CharacterRegistry>(&ts);
        // Registry should exist and be shared
        ts::return_shared(registry);
    };

    ts.end();
}

#[test]
fun create_character() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, ADMIN);
    {
        let character = ts::take_shared<Character>(&ts);

        assert_eq!(character::game_character_id(&character), 1);
        assert_eq!(character::tribe_id(&character), 100);
        assert_eq!(character::name(&character), utf8(b"test"));
        ts::return_shared(character);
    };

    ts.end();
}

#[test]
fun deterministic_character_id() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);

    let game_id = 42u32;
    let character_id_1: ID;
    let precomputed_id: ID;

    // Create first character with game_id = 42
    ts::next_tx(&mut ts, ADMIN);
    {
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);

        // Pre-compute the character ID before creation
        // Pre-computation formula: blake2b_hash(registry_id || type_tag || bcs_serialize(game_character_id))
        // where type_tag = "sui::derived_object::DerivedObjectKey<u32>"
        let precomputed_addr = derived_object::derive_address(
            object::id(&registry),
            game_id,
        );
        precomputed_id = object::id_from_address(precomputed_addr);

        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            100,
            utf8(b"test1"),
            ts::ctx(&mut ts),
        );
        character_id_1 = character::id(&character);

        // Verify that the actual ID matches the pre-computed ID
        assert_eq!(character_id_1, precomputed_id);

        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts.end();
}

#[test]
fun different_game_ids_produce_different_character_ids() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);

    let character_id_1: ID;
    let character_id_2: ID;

    // Create first character with game_id = 1
    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            1u32,
            100,
            utf8(b"character1"),
            ts::ctx(&mut ts),
        );
        character_id_1 = character::id(&character);
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Create second character with game_id = 2
    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            2u32,
            100,
            utf8(b"character2"),
            ts::ctx(&mut ts),
        );
        character_id_2 = character::id(&character);
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::next_tx(&mut ts, ADMIN);
    {
        // Different game IDs should produce different character IDs
        assert!(character_id_1 != character_id_2, 0);
    };

    ts.end();
}

#[test]
fun rename_character() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, USER_A);
    {
        let character = ts::take_shared<Character>(&ts);
        let character_id = object::id(&character);
        ts::return_shared(character);

        setup_owner_cap(&mut ts, USER_A, character_id);
    };

    ts::next_tx(&mut ts, USER_A);
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let mut character = ts::take_shared<Character>(&ts);

        character::rename_character(&mut character, &owner_cap, utf8(b"new_name"));
        assert_eq!(character::name(&character), utf8(b"new_name"));

        ts::return_shared(character);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts.end();
}

#[test]
fun update_tribe() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut character = ts::take_shared<Character>(&ts);

        character::update_tribe(&mut character, &admin_cap, 200);
        assert_eq!(character::tribe_id(&character), 200);

        ts::return_shared(character);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts.end();
}

#[test]
fun delete_character() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let character = ts::take_shared<Character>(&ts);

        character::delete_character(character, &admin_cap);

        ts::return_to_sender(&ts, admin_cap);
    };

    ts.end();
}

#[test]
#[expected_failure(abort_code = character::EGameCharacterIdEmpty)]
fun create_character_with_empty_game_character_id() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    setup_character(&mut ts, 0, 100, b"test");

    abort
}

#[test]
#[expected_failure(abort_code = character::ETribeIdEmpty)]
fun create_character_with_empty_tribe_id() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 0, b"test");

    abort
}

#[test]
#[expected_failure(abort_code = character::ECharacterAlreadyExists)]
fun duplicate_game_id_fails() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);

    let game_id = 123u32;

    // Create first character with game_id = 123
    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            100,
            utf8(b"test1"),
            ts::ctx(&mut ts),
        );
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Try to create another character with the same game_id = 123
    // This should fail because the derived UID was already claimed
    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            200,
            utf8(b"test2"),
            ts::ctx(&mut ts),
        );
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts.end();
}

// Current limitation: derived UIDs cannot be reclaimed after deletion.
// Recreating a character with the same game_id fails,
// even after the original character is deleted.
// The Sui team plans to lift this restriction in the future.
#[test]
#[expected_failure]
fun delete_recreate_character() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);

    // Create first character with game_id = 1
    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            1u32,
            100,
            utf8(b"character1"),
            ts::ctx(&mut ts),
        );
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Delete the character
    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let character = ts::take_shared<Character>(&ts);
        character::delete_character(character, &admin_cap);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Create another character with the same game_id = 42
    ts::next_tx(&mut ts, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            1u32,
            200,
            utf8(b"test2"),
            ts::ctx(&mut ts),
        );

        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts.end();
}

#[test]
#[expected_failure]
fun create_character_without_admin_cap() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);

    ts::next_tx(&mut ts, USER_A);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            1,
            100,
            utf8(b"test"),
            ts::ctx(&mut ts),
        );
        character::share_character(character, &admin_cap);
        abort
    }
}

#[test]
#[expected_failure]
fun test_rename_character_without_owner_cap() {
    let mut ts = ts::begin(GOVERNOR);
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, USER_B);
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let mut character = ts::take_shared<Character>(&ts);

        character::rename_character(&mut character, &owner_cap, utf8(b"new_name"));
        abort
    }
}
