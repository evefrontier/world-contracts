#[test_only]

module world::character_tests;

use std::{string::{Self, utf8}, unit_test::assert_eq};
use sui::{derived_object, test_scenario as ts};
use world::{
    authority::{Self, AdminCap, OwnerCap},
    character::{Self, Character, CharacterRegistry},
    game_id as character_id,
    test_helpers::{Self, governor, admin, user_a, user_b},
    world::{Self, GovernorCap}
};

const TENANT: vector<u8> = b"TEST";
const TENANT_A: vector<u8> = b"TESTA";
const EMPTY_TENANT: vector<u8> = b"";

// Helper functions

fun setup_world(ts: &mut ts::Scenario) {
    ts::next_tx(ts, governor());
    {
        world::init_for_testing(ts::ctx(ts));
        character::init_for_testing(ts::ctx(ts));
    };

    ts::next_tx(ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(ts);
        authority::create_admin_cap(&gov_cap, admin(), ts::ctx(ts));
        ts::return_to_sender(ts, gov_cap);
    };
}

fun setup_character(ts: &mut ts::Scenario, game_id: u32, tribe_id: u32, name: vector<u8>) {
    ts::next_tx(ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let mut registry = ts::take_shared<CharacterRegistry>(ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            string::utf8(TENANT),
            tribe_id,
            utf8(name),
            ts::ctx(ts),
        );
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(ts, admin_cap);
    };
}

/// Tests that the character registry is initialized correctly
/// Scenario: Initialize character registry and verify it exists as a shared object
/// Expected: Registry is created and can be accessed as a shared object
#[test]
fun character_registry_initialized() {
    let mut ts = ts::begin(governor());
    ts::next_tx(&mut ts, governor());
    {
        character::init_for_testing(ts::ctx(&mut ts));
    };

    ts::next_tx(&mut ts, governor());
    {
        let registry = ts::take_shared<CharacterRegistry>(&ts);
        // Registry should exist and be shared
        ts::return_shared(registry);
    };

    ts.end();
}

/// Tests creating a character with valid parameters
/// Scenario: Admin creates a character with game_id=1, tribe_id=100, name="test"
/// Expected: Character is created successfully with correct attributes
#[test]
fun create_character() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, admin());
    {
        let character = ts::take_shared<Character>(&ts);

        assert_eq!(character::game_character_id(&character), 1);
        assert_eq!(character::tribe_id(&character), 100);
        assert_eq!(character::name(&character), utf8(b"test"));
        ts::return_shared(character);
    };

    ts.end();
}

/// Tests that character IDs are deterministic and can be pre-computed
/// Scenario: Pre-compute character ID using derive_address, then create character
/// Expected: Actual character ID matches the pre-computed ID
#[test]
fun deterministic_character_id() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let game_id = 42u32;
    let character_id_1: ID;
    let precomputed_id: ID;

    // Create first character with game_id = 42
    ts::next_tx(&mut ts, admin());
    {
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);

        // Pre-compute the character ID before creation
        // Pre-computation formula: blake2b_hash(registry_id || type_tag || bcs_serialize(CharacterKey))
        // where type_tag = "sui::derived_object::DerivedObjectKey<CharacterKey>"
        let character_key = character_id::create_key(game_id as u64, string::utf8(TENANT));
        let precomputed_addr = derived_object::derive_address(
            object::id(&registry),
            character_key,
        );
        precomputed_id = object::id_from_address(precomputed_addr);

        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            string::utf8(TENANT),
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

/// Tests that different game IDs produce different character IDs
/// Scenario: Create two characters with different game_ids (1 and 2)
/// Expected: The two characters have different IDs
#[test]
fun different_game_ids_produce_different_character_ids() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let character_id_1: ID;
    let character_id_2: ID;

    // Create first character with game_id = 1
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            1u32,
            string::utf8(TENANT),
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
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            2u32,
            string::utf8(TENANT),
            100,
            utf8(b"character2"),
            ts::ctx(&mut ts),
        );
        character_id_2 = character::id(&character);
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::next_tx(&mut ts, admin());
    {
        // Different game IDs should produce different character IDs
        assert!(character_id_1 != character_id_2, 0);
    };

    ts.end();
}

/// Tests that same character ID with different tenant produce different character ID
/// Scenario: Create a character with different tenant
/// Expected: 2 character objects with different tenant but same character ID
#[test]
fun different_tenant_create_character_id() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let character_id_1: ID;
    let character_id_2: ID;

    let game_id: u32 = 12345;

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            string::utf8(TENANT),
            100,
            utf8(b"characterA"),
            ts::ctx(&mut ts),
        );
        character_id_1 = character::id(&character);
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            string::utf8(TENANT_A),
            100,
            utf8(b"characterA"),
            ts::ctx(&mut ts),
        );
        character_id_2 = character::id(&character);
        character::share_character(character, &admin_cap);
        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::next_tx(&mut ts, admin());
    {
        // Different game IDs should produce different character IDs
        assert!(character_id_1 != character_id_2, 0);
    };

    ts.end();
}

/// Tests renaming a character with owner capability
/// Scenario: Owner of character renames it from "test" to "new_name"
/// Expected: Character name is updated successfully
#[test]
fun rename_character() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, user_a());
    {
        let character = ts::take_shared<Character>(&ts);
        let character_id = object::id(&character);
        ts::return_shared(character);

        test_helpers::setup_owner_cap(&mut ts, user_a(), character_id);
    };

    ts::next_tx(&mut ts, user_a());
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

/// Tests updating a character's tribe ID with admin capability
/// Scenario: Admin updates character tribe_id from 100 to 200
/// Expected: Character tribe_id is updated successfully
#[test]
fun update_tribe() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, admin());
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

/// Tests deleting a character with admin capability
/// Scenario: Admin deletes a character
/// Expected: Character is deleted successfully
#[test]
fun delete_character() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let character = ts::take_shared<Character>(&ts);

        character::delete_character(character, &admin_cap);

        ts::return_to_sender(&ts, admin_cap);
    };

    ts.end();
}

/// Tests that creating a character with empty game_character_id fails
/// Scenario: Attempt to create character with game_character_id = 0
/// Expected: Transaction aborts with EGameCharacterIdEmpty error
#[test]
#[expected_failure(abort_code = character::EGameCharacterIdEmpty)]
fun create_character_with_empty_game_character_id() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 0, 100, b"test");

    abort
}

/// Tests that creating a character with empty tribe_id fails
/// Scenario: Attempt to create character with tribe_id = 0
/// Expected: Transaction aborts with ETribeIdEmpty error
#[test]
#[expected_failure(abort_code = character::ETribeIdEmpty)]
fun create_character_with_empty_tribe_id() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 0, b"test");

    abort
}

#[test]
#[expected_failure(abort_code = character::ETenantEmpty)]
fun create_character_with_empty_tenant() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            123u32,
            string::utf8(EMPTY_TENANT),
            100,
            utf8(b"test1"),
            ts::ctx(&mut ts),
        );
        character::share_character(character, &admin_cap);

        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };
    abort
}

/// Tests that creating a character with duplicate game_id fails
/// Scenario: Create character with game_id=123, then attempt to create another with same game_id
/// Expected: Second creation aborts with ECharacterAlreadyExists error
#[test]
#[expected_failure(abort_code = character::ECharacterAlreadyExists)]
fun duplicate_game_id_fails() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    let game_id = 123u32;

    // Create first character with game_id = 123
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            string::utf8(TENANT),
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
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            game_id,
            string::utf8(TENANT),
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
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    // Create first character with game_id = 1
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            1u32,
            string::utf8(TENANT),
            100,
            utf8(b"character1"),
            ts::ctx(&mut ts),
        );
        character::share_character(character, &admin_cap);

        ts::return_shared(registry);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Delete the character
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let character = ts::take_shared<Character>(&ts);
        character::delete_character(character, &admin_cap);
        ts::return_to_sender(&ts, admin_cap);
    };

    // Create another character with the same game_id = 42
    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            1u32,
            string::utf8(TENANT),
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

/// Tests that creating a character without admin capability fails
/// Scenario: User A (not admin) attempts to create a character
/// Expected: Transaction aborts because AdminCap is required
/// Note: Security is enforced at compile time via &AdminCap parameter
#[test]
#[expected_failure]
fun create_character_without_admin_cap() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);

    ts::next_tx(&mut ts, user_a());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut registry = ts::take_shared<CharacterRegistry>(&ts);
        let character = character::create_character(
            &mut registry,
            &admin_cap,
            1,
            string::utf8(TENANT),
            100,
            utf8(b"test"),
            ts::ctx(&mut ts),
        );
        character::share_character(character, &admin_cap);
        abort
    }
}

/// Tests that renaming a character without proper owner capability fails
/// Scenario: User B attempts to rename User A's character using wrong OwnerCap
/// Expected: Transaction aborts because OwnerCap doesn't authorize access to the character
#[test]
#[expected_failure]
fun test_rename_character_without_owner_cap() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, user_b());
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let mut character = ts::take_shared<Character>(&ts);

        character::rename_character(&mut character, &owner_cap, utf8(b"new_name"));
        abort
    }
}

/// Tests that renaming a character with an empty string fails
/// Scenario: Owner attempts to rename character to empty string
/// Expected: Transaction aborts with ECharacterNameEmpty error
#[test]
#[expected_failure(abort_code = character::ECharacterNameEmpty)]
fun rename_character_to_empty_string() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, user_a());
    {
        let character = ts::take_shared<Character>(&ts);
        let character_id = object::id(&character);
        ts::return_shared(character);

        test_helpers::setup_owner_cap(&mut ts, user_a(), character_id);
    };

    ts::next_tx(&mut ts, user_a());
    {
        let owner_cap = ts::take_from_sender<OwnerCap>(&ts);
        let mut character = ts::take_shared<Character>(&ts);

        // This should abort with ECharacterNameEmpty
        character::rename_character(&mut character, &owner_cap, utf8(b""));

        ts::return_shared(character);
        ts::return_to_sender(&ts, owner_cap);
    };

    ts.end();
}

/// Tests that updating tribe_id to 0 is not allowed (validation in update_tribe)
/// Scenario: Admin attempts to update character tribe_id to 0
/// Expected: Transaction aborts with ETribeIdEmpty error
#[test]
#[expected_failure(abort_code = character::ETribeIdEmpty)]
fun update_tribe_to_zero() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut character = ts::take_shared<Character>(&ts);

        character::update_tribe(&mut character, &admin_cap, 0);

        // This should abort with ETribeIdEmpty
        ts::return_shared(character);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts.end();
}

/// Tests that updating tribe without admin capability fails
/// Scenario: User A (not admin) attempts to update character tribe_id
/// Expected: Transaction aborts because AdminCap is required
/// Note: Security is enforced at compile time via &AdminCap parameter
#[test]
#[expected_failure]
fun update_tribe_without_admin_cap() {
    let mut ts = ts::begin(governor());
    setup_world(&mut ts);
    setup_character(&mut ts, 1, 100, b"test");

    ts::next_tx(&mut ts, user_a());
    {
        let _character = ts::take_shared<Character>(&ts);
        // This should fail - user_a doesn't have AdminCap
        abort
    }
}
