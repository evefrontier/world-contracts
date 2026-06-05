/// Server-controlled spatial objects that initially store only a hashed location.
///
/// Rifts are created and managed solely by gameplay servers (authorized sponsors).
/// Players have no OwnerCap and therefore no on-chain path to create or modify them.
/// Authorized sponsors may broadcast the plaintext location on-chain (e.g. when mining begins)
/// to enable PvP interference; the mining lifecycle itself is enforced off-chain.
module world::rift;

use std::string::String;
use sui::{derived_object, event};
use world::{
    access::AdminACL,
    in_game_id::{Self, TenantItemId},
    location::{Self, Location, LocationRegistry},
    object_registry::ObjectRegistry
};

// === Errors ===
#[error(code = 0)]
const ERiftAlreadyExists: vector<u8> = b"Rift with this ItemId already exists";
#[error(code = 1)]
const ERiftItemIdEmpty: vector<u8> = b"Rift ItemId is empty";

// === Structs ===
public struct Rift has key {
    id: UID,
    key: TenantItemId,
    location: Location,
}

// === Events ===
public struct RiftSpawnedEvent has copy, drop {
    rift_id: ID,
    rift_key: TenantItemId,
    location_hash: vector<u8>,
}

public struct RiftLocationBroadcastEvent has copy, drop {
    rift_id: ID,
    rift_key: TenantItemId,
    location_hash: vector<u8>,
    solarsystem: u64,
    x: String,
    y: String,
    z: String,
}

// === View Functions ===
public fun id(rift: &Rift): ID {
    object::id(rift)
}

public fun key(rift: &Rift): TenantItemId {
    rift.key
}

public fun location_hash(rift: &Rift): vector<u8> {
    location::hash(&rift.location)
}

// === Admin Functions ===
public fun spawn(
    registry: &mut ObjectRegistry,
    admin_acl: &AdminACL,
    item_id: u64,
    tenant: String,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): Rift {
    admin_acl.verify_sponsor(ctx);
    assert!(item_id != 0, ERiftItemIdEmpty);

    let rift_key = in_game_id::create_key(item_id, tenant);
    assert!(!registry.object_exists(rift_key), ERiftAlreadyExists);

    let rift_uid = derived_object::claim(registry.borrow_registry_id(), rift_key);
    let rift_id = object::uid_to_inner(&rift_uid);

    let rift = Rift {
        id: rift_uid,
        key: rift_key,
        location: location::attach(location_hash),
    };

    event::emit(RiftSpawnedEvent {
        rift_id,
        rift_key,
        location_hash: rift.location.hash(),
    });

    rift
}

public fun share_rift(rift: Rift, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    transfer::share_object(rift);
}

public fun broadcast_location(
    rift: &Rift,
    location_registry: &mut LocationRegistry,
    admin_acl: &AdminACL,
    solarsystem: u64,
    x: String,
    y: String,
    z: String,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);

    let rift_id = object::id(rift);
    let location_hash = location::hash(&rift.location);

    location::record_revealed_coordinates(
        location_registry,
        rift_id,
        solarsystem,
        x,
        y,
        z,
    );

    event::emit(RiftLocationBroadcastEvent {
        rift_id,
        rift_key: rift.key,
        location_hash,
        solarsystem,
        x,
        y,
        z,
    });
}

public fun despawn(rift: Rift, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);

    let Rift { id, location, .. } = rift;
    location.remove();
    id.delete();
}
