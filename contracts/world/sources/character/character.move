/// This module manages character creation and lifecycle with capability-based access control.
///
/// Game characters have flexible ownership and access control beyond simple wallet-based ownership.
/// Characters are shared objects and mutable by admin and the character owner using capabilities.

module world::character;

use std::string::String;
use sui::{derived_object, event, transfer::Receiving};
use world::{
    access::{Self, AdminACL, OwnerCap},
    in_game_id::{Self, TenantItemId},
    metadata::{Self, Metadata},
    object_registry::ObjectRegistry
};

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

#[error(code = 5)]
const ESenderCannotAccessCharacter: vector<u8> = b"Sender cannot access Character";
#[error(code = 6)]
const EMetadataNotSet: vector<u8> = b"Metadata not set on character";
#[error(code = 7)]
const ECharacterNotAuthorized: vector<u8> = b"Character access not authorized";

public struct Character has key {
    id: UID,
    key: TenantItemId, // The derivation key used to generate the character's object ID
    tribe_id: u32,
    character_address: address,
    metadata: Option<Metadata>,
    owner_cap_id: ID,
}

/// Temporary struct for wallet-owned query: one per character, transferred to character_address.
/// Points at the character so clients can query "objects by wallet" and get character_id.
public struct PlayerProfile has key {
    id: UID,
    character_id: ID,
}

// Events
public struct CharacterCreatedEvent has copy, drop {
    character_id: ID,
    key: TenantItemId,
    tribe_id: u32,
    character_address: address,
}

// === View Functions ===
public fun id(character: &Character): ID {
    object::id(character)
}

public fun key(character: &Character): TenantItemId {
    character.key
}

public fun character_address(character: &Character): address {
    character.character_address
}

public fun tenant(character: &Character): String {
    in_game_id::tenant(&character.key)
}

public fun tribe(character: &Character): u32 {
    character.tribe_id
}

public fun owner_cap_id(character: &Character): ID {
    character.owner_cap_id
}

// === Public Functions ===
public fun update_metadata_name(
    character: &mut Character,
    owner_cap: &OwnerCap<Character>,
    name: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(character)), ECharacterNotAuthorized);
    assert!(std::option::is_some(&character.metadata), EMetadataNotSet);
    let metadata = std::option::borrow_mut(&mut character.metadata);
    metadata.update_name(character.key, name);
}

public fun update_metadata_description(
    character: &mut Character,
    owner_cap: &OwnerCap<Character>,
    description: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(character)), ECharacterNotAuthorized);
    assert!(std::option::is_some(&character.metadata), EMetadataNotSet);
    let metadata = std::option::borrow_mut(&mut character.metadata);
    metadata.update_description(character.key, description);
}

public fun update_metadata_url(
    character: &mut Character,
    owner_cap: &OwnerCap<Character>,
    url: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(character)), ECharacterNotAuthorized);
    assert!(std::option::is_some(&character.metadata), EMetadataNotSet);
    let metadata = std::option::borrow_mut(&mut character.metadata);
    metadata.update_url(character.key, url);
}

// === Admin Functions ===
public fun create_character(
    registry: &mut ObjectRegistry,
    admin_acl: &AdminACL,
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
    assert!(!registry.object_exists(character_key), ECharacterAlreadyExists);
    let character_uid = derived_object::claim(registry.borrow_registry_id(), character_key);
    let character_id = object::uid_to_inner(&character_uid);

    let owner_cap = access::create_owner_cap_by_id<Character>(character_id, admin_acl, ctx);
    let owner_cap_id = object::id(&owner_cap);

    let character = Character {
        id: character_uid,
        key: character_key,
        tribe_id,
        character_address,
        metadata: std::option::some(
            metadata::create_metadata(
                character_id,
                character_key,
                name,
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        owner_cap_id,
    };

    access::transfer_owner_cap(owner_cap, object::id_address(&character));

    // Create a temporary PlayerProfile and transfer it to the player's wallet address (character_address)
    // so clients can query characters by wallet. TODO: Replace with Character OwnerCap-to-wallet flow.
    let player_profile = PlayerProfile {
        id: object::new(ctx),
        character_id: object::id(&character),
    };
    transfer::transfer(player_profile, character_address);

    event::emit(CharacterCreatedEvent {
        character_id: object::id(&character),
        key: character_key,
        tribe_id,
        character_address,
    });
    character
}

// borrow owner cap from character
// refer : https://docs.sui.io/guides/developer/objects/transfers/transfer-to-object for more details
public fun borrow_owner_cap<T: key>(
    character: &mut Character,
    owner_cap_ticket: Receiving<OwnerCap<T>>,
    ctx: &TxContext,
): (OwnerCap<T>, access::ReturnOwnerCapReceipt) {
    assert!(character.character_address == ctx.sender(), ESenderCannotAccessCharacter);

    let owner_cap = access::receive_owner_cap(&mut character.id, owner_cap_ticket);
    let return_receipt = access::create_return_receipt(
        object::id(&owner_cap),
        object::id_address(character),
    );
    (owner_cap, return_receipt)
}

// return owner cap to character
public fun return_owner_cap<T: key>(
    character: &Character,
    owner_cap: OwnerCap<T>,
    receipt: access::ReturnOwnerCapReceipt,
) {
    access::return_owner_cap_to_object(owner_cap, receipt, object::id_address(character));
}

public fun share_character(character: Character, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    transfer::share_object(character);
}

public fun update_tribe(
    character: &mut Character,
    admin_acl: &AdminACL,
    tribe_id: u32,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    assert!(tribe_id != 0, ETribeIdEmpty);
    character.tribe_id = tribe_id;
}

/// Updates the character's wallet address. Note: any existing PlayerProfile remains at the old
/// wallet; clients querying by the new address will not see it until a new profile is issued.
/// TODO: Replace with transferring character ownercap to wallet address later
public fun update_address(
    character: &mut Character,
    admin_acl: &AdminACL,
    character_address: address,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    assert!(character_address != @0x0, EAddressEmpty);
    character.character_address = character_address;
}

// for emergencies
public fun update_tenant_id(
    character: &mut Character,
    admin_acl: &AdminACL,
    tenant: String,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    assert!(tenant.length() > 0, ETenantEmpty);
    let current_id = in_game_id::item_id(&character.key);
    character.key = in_game_id::create_key(current_id, tenant);
}

/// Deletes the character and its metadata. PlayerProfile (if any) is wallet-owned and not
/// cleaned up here; it will be obsolete once replaced by the OwnerCap-to-wallet flow.
public fun delete_character(character: Character, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
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
