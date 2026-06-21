/// `Entity` in-game can be a ship or a structure. It stays small: modules and actions are
/// stored as dynamic fields, so installing behavior never changes its type.
///
/// On-chain object IDs are derived from `ObjectRegistry` using a tenant-scoped game
/// identifier (`id + tenant`), so each in-game ID maps to exactly one entity.
///
/// Lifecycle operations (`install`, `uninstall`, `enable_action`,
/// `disable_action`, `interact`) lock the entity and return a `Request` that
/// the transaction must `complete_request` — this is what gates `module_mut`
/// access and leaves room for system approval requirements.
module core::entity;

use core::{
    action::Action,
    admin_service,
    entity_key::{Self, EntityKey},
    location_service,
    mod::{Self, Module},
    object_registry::ObjectRegistry,
    request::{Self, Request}
};
use std::{internal::Permit, string::String};
use sui::{derived_object, dynamic_field as df, vec_map::{Self, VecMap}};

// === Errors ===

const EWrongVersion: u64 = 0;
const ENotLocked: u64 = 1;
const EWrongEntity: u64 = 2;
const ERequirementNotModuleScoped: u64 = 3;
const EUnknownAction: u64 = 4;
const EModuleExists: u64 = 5;
const EModuleMissing: u64 = 6;
const EActionExists: u64 = 7;
const EEntityAlreadyExists: u64 = 8;

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

public struct ModuleKey(String) has copy, drop, store;
public struct ActionsKey() has copy, drop, store;
public struct InFlight() has copy, drop, store;

public struct Entity has key {
    id: UID,
    version: u64,
    /// Tenant-scoped game identifier used to derive this entity's object ID.
    key: EntityKey,
    /// Location hash injected as a proximity requirement on every interaction.
    location_hash: vector<u8>,
}

// === Public Functions ===

/// Claim an entity with a deterministic ID derived from `id + tenant`. The same
/// in-game ID can only ever back a single entity. Locked on return with an admin
/// requirement: the caller must `admin_service::verify_admin` then
/// `complete_request` before configuring the entity.
public fun new(
    registry: &mut ObjectRegistry,
    id: u64,
    tenant: String,
    location_hash: vector<u8>,
): (Entity, Request) {
    let key = entity_key::new(id, tenant);
    assert!(!registry.exists(key), EEntityAlreadyExists);

    let uid = derived_object::claim(registry.borrow_id(), key);
    let mut entity = Entity { id: uid, version: VERSION, key, location_hash };
    df::add(&mut entity.id, ActionsKey(), vec_map::empty<String, Action>());

    entity.lock();
    let req = request::new(
        option::some(entity.id.to_inner()),
        vector[admin_service::admin_requirement()],
    );
    (entity, req)
}

/// Share the entity once configured.
public fun share(entity: Entity) {
    transfer::share_object(entity);
}

/// Install module state `T` under `name`. The `Permit<T>` proves the caller's
/// package authored `T`. Returns a `Request` the transaction must complete.
public fun install<T: store>(
    entity: &mut Entity,
    name: String,
    inner: T,
    version: u64,
    _: Permit<T>,
    _ctx: &mut TxContext,
): Request {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(!df::exists_(&entity.id, ModuleKey(name)), EModuleExists);

    df::add(&mut entity.id, ModuleKey(name), mod::new(name, inner, version));
    entity.lock();
    request::new(
        option::some(entity.id.to_inner()),
        vector[admin_service::admin_requirement()],
    )
}

/// Remove module `name`, returning its wrapped state to the caller.
public fun uninstall<T: store>(
    entity: &mut Entity,
    name: String,
    _: Permit<T>,
    _ctx: &mut TxContext,
): (Module<T>, Request) {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(df::exists_with_type<_, Module<T>>(&entity.id, ModuleKey(name)), EModuleMissing);

    let m: Module<T> = df::remove(&mut entity.id, ModuleKey(name));
    entity.lock();
    let req = request::new(
        option::some(entity.id.to_inner()),
        vector[admin_service::admin_requirement()],
    );
    (m, req)
}

/// Expose a programmable `action` under `name`.
public fun enable_action(
    entity: &mut Entity,
    name: String,
    action: Action,
    _ctx: &mut TxContext,
): Request {
    assert!(entity.version == VERSION, EWrongVersion);

    let actions: &mut VecMap<String, Action> = df::borrow_mut(&mut entity.id, ActionsKey());
    assert!(!actions.contains(&name), EActionExists);
    actions.insert(name, action);

    entity.lock();
    request::new(option::some(entity.id.to_inner()), vector[])
}

/// Remove a previously-exposed action.
public fun disable_action(entity: &mut Entity, name: String, _ctx: &mut TxContext): Request {
    assert!(entity.version == VERSION, EWrongVersion);

    let actions: &mut VecMap<String, Action> = df::borrow_mut(&mut entity.id, ActionsKey());
    assert!(actions.contains(&name), EUnknownAction);
    let (_, _action) = actions.remove(&name);

    entity.lock();
    request::new(option::some(entity.id.to_inner()), vector[])
}

/// Interact with a registered action, producing the `Request` to satisfy. A
/// proximity requirement for the entity's location is injected ahead of the
/// action's own requirements, so it must be resolved first.
public fun interact(entity: &mut Entity, action: String, _ctx: &mut TxContext): Request {
    assert!(entity.version == VERSION, EWrongVersion);

    let actions: &VecMap<String, Action> = df::borrow(&entity.id, ActionsKey());
    assert!(actions.contains(&action), EUnknownAction);
    let request = actions
        .get(&action)
        .to_request(
            option::some(entity.id.to_inner()),
            vector[location_service::proximity_requirement(entity.location_hash)],
        );

    entity.lock();
    request
}

/// Mutable access to a module, only valid mid-interaction. The target module
/// name is read off the request's next requirement (not the caller's args), so
/// a handler can never mutate the wrong module.
public fun module_mut<T: store>(entity: &mut Entity, req: &Request, _: Permit<T>): &mut Module<T> {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(entity.is_locked(), ENotLocked);
    assert!(req.entity_id().is_some_and!(|id| id == entity.id.to_inner()), EWrongEntity);

    let name = req.next().module_name().destroy_or!(abort ERequirementNotModuleScoped);
    df::borrow_mut(&mut entity.id, ModuleKey(name))
}

/// Read-only access to a module by name. `Permit<T>` enforces that only the
/// package that authored `T` can read it; no lock is required since nothing
/// is mutated.
public fun module_ref<T: store>(entity: &Entity, name: String, _: Permit<T>): &Module<T> {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(df::exists_with_type<_, Module<T>>(&entity.id, ModuleKey(name)), EModuleMissing);
    df::borrow(&entity.id, ModuleKey(name))
}

/// Complete a request against this entity and unlock it.
public fun complete_request(entity: &mut Entity, req: Request) {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(entity.is_locked(), ENotLocked);
    req.entity_id().do!(|id| assert!(id == entity.id.to_inner(), EWrongEntity));
    req.complete();
    entity.unlock();
}

// === View Functions ===

public fun id(entity: &Entity): ID {
    object::id(entity)
}

public fun key(entity: &Entity): EntityKey {
    entity.key
}

public fun has_module(entity: &Entity, name: String): bool {
    df::exists_(&entity.id, ModuleKey(name))
}

public fun has_module_with_type<T: store>(entity: &Entity, name: String): bool {
    df::exists_with_type<_, Module<T>>(&entity.id, ModuleKey(name))
}

public fun version(entity: &Entity): u64 {
    entity.version
}

public fun location_hash(entity: &Entity): vector<u8> {
    entity.location_hash
}

// === Private Functions ===

fun lock(entity: &mut Entity) {
    df::add(&mut entity.id, InFlight(), true);
}

fun unlock(entity: &mut Entity) {
    let _: bool = df::remove(&mut entity.id, InFlight());
}

fun is_locked(entity: &Entity): bool {
    df::exists_(&entity.id, InFlight())
}
