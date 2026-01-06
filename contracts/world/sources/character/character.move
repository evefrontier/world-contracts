/// This module manages character creation and lifecycle with capability-based access control.
///
/// Game characters have flexible ownership and access control beyond simple wallet-based ownership.
/// Characters are shared objects and mutable by admin and the character owner using capabilities.

module world::character;

use std::string::String;
use sui::{derived_object, event};
use world::{access::{Self, AdminCap}, in_game_id::{Self, TenantItemId}, metadata::{Self, Metadata}};

#[error(code = 0)]
const EGameCharacterIdEmpty: vector<u8> = b"Game character ID is empty";

#[error(code = 1)]
const ETribeIdEmpty: vector<u8> = b"Tribe ID is empty";

#[error(code = 2)]
const ECharacterAlreadyExists: vector<u8> = b"Character with this game character ID already exists";

#[error(code = 3)]
const ETenantEmpty: vector<u8> = b"Tenant name cannot be empty";

#[error(code = 4)]
const EAddressEmpty: vector<u8> = b"Address cannot be empty";

public struct CharacterRegistry has key {
    id: UID,
}

public struct Character has key {
    id: UID,
    key: TenantItemId, // The derivation key used to generate the character's object ID
    tribe_id: u32,
    character_address: address,
    metadata: Option<Metadata>,
    owner_cap_id: ID,
}

// Events
public struct CharacterCreatedEvent has copy, drop {
    character_id: ID,
    key: TenantItemId,
    tribe_id: u32,
    character_address: address,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(CharacterRegistry {
        id: object::new(ctx),
    });
}

// === View Functions ===
public fun id(character: &Character): ID {
    object::id(character)
}

public fun character_address(character: &Character): address {
    character.character_address
}

public fun tenant(character: &Character): String {
    in_game_id::tenant(&character.key)
}

// === Admin Functions ===
public fun create_character(
    registry: &mut CharacterRegistry,
    admin_cap: &AdminCap,
    game_character_id: u32,
    tenant: String,
    tribe_id: u32,
    character_address: address,
    name: String,
    ctx: &mut TxContext,
): Character {
    assert!(game_character_id != 0, EGameCharacterIdEmpty);
    assert!(tribe_id != 0, ETribeIdEmpty);
    assert!(character_address != @0x0, EAddressEmpty);
    assert!(tenant.length() > 0, ETenantEmpty);

    // Claim a derived UID using the game character id and tenant id as the key
    // This ensures deterministic character id  generation and prevents duplicate character creation under the same game id.
    // The character id can be pre-computed using the registry object id and TenantItemId
    let character_key = in_game_id::create_key(game_character_id as u64, tenant);
    assert!(!derived_object::exists(&registry.id, character_key), ECharacterAlreadyExists);
    let character_uid = derived_object::claim(&mut registry.id, character_key);
    let character_id = object::uid_to_inner(&character_uid);

    let owner_cap_id = access::create_and_transfer_owner_cap<Character>(
        admin_cap,
        character_id,
        character_address,
        ctx,
    );

    let character = Character {
        id: character_uid,
        key: character_key,
        tribe_id,
        character_address,
        metadata: std::option::some(
            metadata::create_metadata(
                character_id,
                game_character_id as u64,
                name,
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        owner_cap_id,
    };

    event::emit(CharacterCreatedEvent {
        character_id: object::id(&character),
        key: character_key,
        tribe_id,
        character_address,
    });
    character
}

public fun share_character(character: Character, _: &AdminCap) {
    transfer::share_object(character);
}

public fun update_tribe(character: &mut Character, _: &AdminCap, tribe_id: u32) {
    assert!(tribe_id != 0, ETribeIdEmpty);
    character.tribe_id = tribe_id;
}

public fun update_address(character: &mut Character, _: &AdminCap, character_address: address) {
    assert!(character_address != @0x0, EAddressEmpty);
    character.character_address = character_address;
}

// for emergencies
public fun update_tenant_id(character: &mut Character, _: &AdminCap, tenant: String) {
    assert!(tenant.length() > 0, ETenantEmpty);
    let current_id = in_game_id::item_id(&character.key);
    character.key = in_game_id::create_key(current_id, tenant);
}

public fun delete_character(character: Character, _: &AdminCap) {
    let Character { id, metadata, .. } = character;
    if (std::option::is_some(&metadata)) {
        let m = std::option::destroy_some(metadata);
        metadata::delete(m);
    } else {
        std::option::destroy_none(metadata);
    };
    id.delete();
}

// === Test Functions ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun game_character_id(character: &Character): u32 {
    in_game_id::item_id(&character.key) as u32
}

#[test_only]
public fun tribe_id(character: &Character): u32 {
    character.tribe_id
}

#[test_only]
public fun name(character: &Character): String {
    let metadata = std::option::borrow(&character.metadata);
    metadata::name(metadata)
}

#[test_only]
public fun mutable_metadata(character: &mut Character): &mut Metadata {
    std::option::borrow_mut(&mut character.metadata)
}
