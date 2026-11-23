/// Identity component installed on a Character `Entity`.
///
/// Holds the character's tribe and the single wallet address bound to it.
///
/// TODO: support multi-address / multisig ownership (`VecSet<address>`) so that
/// multiple addresses can be bound to a single character.
module character::identity;

use core::{
    admin_service,
    component::{Self, Component},
    entity::Entity,
    entity_key::EntityKey,
    request::Request,
    requirement::{Self, Requirement}
};
use std::{internal::Permit, string::{Self, String}};
use sui::event;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Identity component version does not match the package version";
#[error(code = 1)]
const EComponentMissing: vector<u8> = b"Identity component is not installed on this entity";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"identity";

// === Structs ===

public struct Identity has store {
    tribe_id: u32,
    owner: address,
}

/// Requirement satisfied by `edit`.
public struct Edit() has drop;

// === Events ===

/// Emitted when identity is installed on an entity, i.e. when it becomes a character.
public struct CharacterCreated has copy, drop {
    character_id: ID,
    key: EntityKey,
    tribe_id: u32,
    character_address: address,
}

/// Emitted when a character's information changes.
public struct CharacterUpdated has copy, drop {
    character_id: ID,
    key: EntityKey,
    tribe_id: u32,
}

// === View Functions ===

public fun tribe_id(entity: &Entity): u32 {
    borrow(entity).tribe_id
}

public fun owner(entity: &Entity): address {
    borrow(entity).owner
}

public fun component_id(): u64 {
    component::id_from_name(NAME)
}

// === Public Functions ===

/// Build and install the identity component on a character entity.
public fun install(
    entity: &mut Entity,
    tribe_id: u32,
    owner: address,
    ctx: &mut TxContext,
): Request {
    let identity = Identity { tribe_id, owner };
    let req = entity.install(
        component_id(),
        option::some(component_label()),
        identity,
        VERSION,
        identity_permit(),
        ctx,
    );

    event::emit(CharacterCreated {
        character_id: entity.id(),
        key: entity.key(),
        tribe_id,
        character_address: owner,
    });
    req
}

/// Remove the identity component, discarding its state. Aborts if it was never installed.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(entity.has_component_with_type<Identity>(component_id()), EComponentMissing);

    let (c, req) = entity.uninstall<Identity>(component_id(), identity_permit(), ctx);
    let Identity { tribe_id: _, owner: _ } = c.unwrap(identity_permit());
    req
}

/// Set the character editable fields. Next requirement must be this component's `Edit`,
/// and the frame then requires the admin. Emits `CharacterUpdated` only when a field changes.
public fun edit(entity: &mut Entity, req: &mut Request, new_tribe_id: u32) {
    assert!(entity.has_component_with_type<Identity>(component_id()), EComponentMissing);
    let character_id = entity.id();
    let key = entity.key();
    let c: &mut Component<Identity> = entity.component_mut(req, identity_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    let (_requirement, mut frame) = req.take_next(edit_permit());
    let identity = c.inner_mut();
    if (identity.tribe_id != new_tribe_id) {
        identity.tribe_id = new_tribe_id;
        event::emit(CharacterUpdated { character_id, key, tribe_id: new_tribe_id });
    };
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
}

/// Build an edit requirement targeting the identity component slot.
public fun edit_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), Edit())
}

// === Private Functions ===

fun borrow_component(entity: &Entity): &Component<Identity> {
    let c: &Component<Identity> = entity.component_ref(component_id(), identity_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    c
}

fun borrow(entity: &Entity): &Identity {
    borrow_component(entity).inner()
}

fun component_label(): String {
    string::utf8(NAME)
}

fun identity_permit(): Permit<Identity> {
    internal::permit<Identity>()
}

fun edit_permit(): Permit<Edit> {
    internal::permit<Edit>()
}
