/// This module manages character creation and lifecycle with capability-based access control.
///
/// Game characters have flexible ownership and access control beyond simple wallet-based ownership.
/// Characters are shared objects and mutable by admin and the character owner using capabilities.

module world::character;

use std::string::{Self, String};
use sui::{derived_object, event};
use world::{authority::{Self, OwnerCap, AdminCap}, game_id::{Self, GameId}};

#[error(code = 0)]
const EGameCharacterIdEmpty: vector<u8> = b"Game character ID is empty";

#[error(code = 1)]
const ETribeIdEmpty: vector<u8> = b"Tribe ID is empty";

#[error(code = 2)]
const ECharacterAlreadyExists: vector<u8> = b"Character with this game character ID already exists";

#[error(code = 3)]
const ECharacterNotAuthorized: vector<u8> = b"Character not authorized";

#[error(code = 4)]
const ECharacterNameEmpty: vector<u8> = b"Character name cannot be empty";

#[error(code = 5)]
const ETenantEmpty: vector<u8> = b"Tenant name cannot be empty";

public struct CharacterRegistry has key {
    id: UID,
}

public struct Character has key {
    id: UID,
    key: GameId,
    tribe_id: u32,
    name: String,
}

// Events
public struct CharacterCreatedEvent has copy, drop {
    character_id: ID,
    game_character_id: u32,
    tenant: String,
    tribe_id: u32,
    // TODO : use metadata instead
    name: String,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(CharacterRegistry {
        id: object::new(ctx),
    });
}

// === Public Functions ===
public fun rename_character(character: &mut Character, owner_cap: &OwnerCap, name: String) {
    assert!(authority::is_authorized(owner_cap, object::id(character)), ECharacterNotAuthorized);
    assert!(std::string::length(&name) > 0, ECharacterNameEmpty);

    // TODO: emit events
    character.name = name;
}

// === Admin Functions ===
public fun create_character(
    registry: &mut CharacterRegistry,
    _: &AdminCap,
    game_character_id: u32,
    tenant: String,
    tribe_id: u32,
    name: String,
    _: &mut TxContext,
): Character {
    assert!(game_character_id != 0, EGameCharacterIdEmpty);
    assert!(tribe_id != 0, ETribeIdEmpty);
    assert!(std::string::length(&tenant) > 0, ETenantEmpty);

    // Claim a derived UID using the game character id and tenant id as the key
    // This ensures deterministic character id  generation and prevents duplicate character creation under the same game id.
    // The character id can be pre-computed using the registry object id and GameId
    let character_key = game_id::create_key(game_character_id as u64, tenant);
    assert!(!derived_object::exists(&registry.id, character_key), ECharacterAlreadyExists);
    let character_uid = derived_object::claim(&mut registry.id, character_key);
    let character = Character {
        id: character_uid,
        key: character_key,
        tribe_id: tribe_id,
        name: name,
    };
    event::emit(CharacterCreatedEvent {
        character_id: object::id(&character),
        game_character_id: game_character_id,
        tenant: tenant,
        tribe_id: tribe_id,
        name: name,
    });
    character
}

public fun share_character(character: Character, _: &AdminCap) {
    transfer::share_object(character);
}

public fun update_tribe(character: &mut Character, _: &AdminCap, tribe_id: u32) {
    assert!(tribe_id != 0, ETribeIdEmpty);
    // TODO: emit events
    character.tribe_id = tribe_id;
}

// for emergencies
public fun update_tenent_id(character: &mut Character, _: &AdminCap, tenant: String) {
    assert!(string::length(&tenant) > 0, ETenantEmpty);
    // TODO: emit events
    let current_id = game_id::id(&character.key);
    character.key = game_id::create_key(current_id, tenant);
}

public fun delete_character(character: Character, _: &AdminCap) {
    let Character { id, .. } = character;
    // TODO: emit events
    id.delete();
}

// === Test Functions ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun id(character: &Character): ID {
    object::id(character)
}

#[test_only]
public fun game_character_id(character: &Character): u32 {
    game_id::id(&character.key) as u32
}

#[test_only]
public fun tribe_id(character: &Character): u32 {
    character.tribe_id
}

#[test_only]
public fun name(character: &Character): String {
    character.name
}

#[test_only]
public fun tenant(character: &Character): String {
    game_id::tenant(&character.key)
}
