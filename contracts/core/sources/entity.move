/// `Entity` in-game can be a ship or a structure. It stays small: modules and actions are
/// stored as dynamic fields, so installing behavior never changes its type.
///
/// On-chain object IDs are derived from `ObjectRegistry` using a tenant-scoped game
/// identifier (`id + tenant`), so each in-game ID maps to exactly one entity.
///
/// Lifecycle operations (`install`, `uninstall`, `enable_action`,
/// `disable_action`, `interact`, `request_delete`) lock the entity and return a
/// `Request` the transaction must satisfy. `complete_request` unlocks;
/// `delete` consumes the object and a `DeleteTicket` minted only by `request_delete`.
module core::entity;

use core::{
    access_cap::{Self, AccessCap, ReturnReceipt},
    action::Action,
    admin_service,
    behavior_type::BehaviorType,
    entity_key::{Self, EntityKey},
    location_service,
    mod::{Self, Module},
    object_registry::ObjectRegistry,
    request::{Self, Request}
};
use std::{internal::Permit, string::String};
use sui::{derived_object, dynamic_field as df, event, transfer::Receiving, vec_map::{Self, VecMap}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Entity version does not match the package version";
#[error(code = 1)]
const ENotLocked: vector<u8> = b"Entity is not locked";
#[error(code = 2)]
const EWrongEntity: vector<u8> = b"Module does not belong to this entity";
#[error(code = 3)]
const ERequirementNotModuleScoped: vector<u8> = b"Requirement is not module-scoped";
#[error(code = 4)]
const EUnknownAction: vector<u8> = b"Action is not enabled on this entity";
#[error(code = 5)]
const EModuleExists: vector<u8> = b"Module is already installed";
#[error(code = 6)]
const EModuleMissing: vector<u8> = b"Module is not installed";
#[error(code = 7)]
const EActionExists: vector<u8> = b"Action is already enabled";
#[error(code = 8)]
const EEntityAlreadyExists: vector<u8> = b"Entity already exists for this key";
#[error(code = 9)]
const EModulesRemain: vector<u8> = b"Uninstall all modules before deleting the entity";
#[error(code = 10)]
const ELocked: vector<u8> = b"Entity is locked";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

public struct ModuleKey(u64) has copy, drop, store;
public struct ActionsKey() has copy, drop, store;
public struct InFlight() has copy, drop, store;

public struct Entity has key {
    id: UID,
    version: u64,
    /// Tenant-scoped game identifier used to derive this entity's object ID.
    key: EntityKey,
    module_ids: vector<u64>,
}

/// Proof that delete started via `request_delete`.
/// `request_delete` mints it and only `delete` consumes it.
public struct DeleteTicket {
    entity_id: ID,
}

// === Events ===

public struct EntityCreated has copy, drop {
    entity_id: ID,
    key: EntityKey,
}

public struct EntityDeleted has copy, drop {
    entity_id: ID,
    key: EntityKey,
}

// === Public Functions ===

/// Claim an entity with a deterministic ID derived from `id + tenant`. The same
/// in-game ID can only ever back a single entity. Locked on return with an admin
/// requirement: the caller must `admin_service::verify_admin` then
/// `complete_request` before configuring the entity.
public fun new(registry: &mut ObjectRegistry, id: u64, tenant: String): (Entity, Request) {
    let key = entity_key::new(id, tenant);
    assert!(!registry.exists(key), EEntityAlreadyExists);

    let uid = derived_object::claim(registry.borrow_id(), key);
    let mut entity = Entity { id: uid, version: VERSION, key, module_ids: vector[] };
    df::add(&mut entity.id, ActionsKey(), vec_map::empty<String, Action>());

    event::emit(EntityCreated { entity_id: entity.id.to_inner(), key });
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

/// Mint an `AccessCap` for this entity and transfer it to `owner`.
/// `owner` is a Sui address: either an account address or an object ID
/// (object-owner), per Sui ownership semantics.
public fun mint_access(
    entity: &mut Entity,
    owner: address,
    transferable: bool,
    ctx: &mut TxContext,
): Request {
    assert!(entity.version == VERSION, EWrongVersion);
    access_cap::mint(entity.id.to_inner(), owner, transferable, ctx);
    entity.lock();
    request::new(
        option::some(entity.id.to_inner()),
        vector[admin_service::admin_requirement()],
    )
}

/// Borrow an `AccessCap` parked on this entity (object-owned). `entity_cap` must
/// be this entity's own cap, proving the caller owns it. Returns the parked cap
/// and a non-droppable receipt that must be consumed by `return_access` or
/// `access_cap::transfer_with_receipt`.
public fun borrow_access(
    entity: &mut Entity,
    entity_cap: &AccessCap,
    ticket: Receiving<AccessCap>,
): (AccessCap, ReturnReceipt) {
    assert!(entity.version == VERSION, EWrongVersion);
    access_cap::borrow(&mut entity.id, entity_cap, ticket)
}

/// Put a borrowed cap back on this entity, consuming the receipt.
public fun return_access(entity: &mut Entity, cap: AccessCap, receipt: ReturnReceipt) {
    assert!(entity.version == VERSION, EWrongVersion);
    access_cap::return_to(&mut entity.id, cap, receipt)
}

/// Install module state `T` under `module_id`. `name` is an optional
/// display label and is not unique. The `Permit<T>` proves the caller's package
/// authored `T`. Returns a `Request` the transaction must complete.
public fun install<T: store>(
    entity: &mut Entity,
    module_id: u64,
    type_id: u64,
    behavior_type_id: Option<BehaviorType>,
    name: Option<String>,
    inner: T,
    version: u64,
    _: Permit<T>,
    _ctx: &mut TxContext,
): Request {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(!df::exists(&entity.id, ModuleKey(module_id)), EModuleExists);

    df::add(
        &mut entity.id,
        ModuleKey(module_id),
        mod::new(name, inner, version, type_id, behavior_type_id),
    );
    entity.module_ids.push_back(module_id);
    entity.lock();
    request::new(
        option::some(entity.id.to_inner()),
        vector[admin_service::admin_requirement()],
    )
}

/// Remove the module at `module_id`, returning its wrapped state to the caller.
public fun uninstall<T: store>(
    entity: &mut Entity,
    module_id: u64,
    _: Permit<T>,
    _ctx: &mut TxContext,
): (Module<T>, Request) {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(df::exists_with_type<_, Module<T>>(&entity.id, ModuleKey(module_id)), EModuleMissing);

    let m: Module<T> = df::remove(&mut entity.id, ModuleKey(module_id));
    let (found, i) = entity.module_ids.index_of(&module_id);
    assert!(found, EModuleMissing);
    entity.module_ids.remove(i);
    entity.lock();
    let req = request::new(
        option::some(entity.id.to_inner()),
        vector[admin_service::admin_requirement()],
    );
    (m, req)
}

/// Expose a programmable `action` under `name`. Owner-gated: only the entity's
/// owner (holder of its `AccessCap`) may configure which actions exist and their
/// requirements, so a requirement on an action is trusted by construction.
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
    request::new(
        option::some(entity.id.to_inner()),
        vector[access_cap::owner_requirement()],
    )
}

/// Remove a previously-exposed action. Owner-gated, like `enable_action`.
public fun disable_action(entity: &mut Entity, name: String, _ctx: &mut TxContext): Request {
    assert!(entity.version == VERSION, EWrongVersion);

    let actions: &mut VecMap<String, Action> = df::borrow_mut(&mut entity.id, ActionsKey());
    assert!(actions.contains(&name), EUnknownAction);
    let (_, _action) = actions.remove(&name);

    entity.lock();
    request::new(
        option::some(entity.id.to_inner()),
        vector[access_cap::owner_requirement()],
    )
}

/// Interact with a registered action, producing the `Request` to satisfy. A
/// proximity requirement for `target_location_hash` is injected ahead of the
/// action's own requirements, so it must be resolved first.
public fun interact(
    entity: &mut Entity,
    action: String,
    target_location_hash: vector<u8>,
    _ctx: &mut TxContext,
): Request {
    assert!(entity.version == VERSION, EWrongVersion);

    let actions: &VecMap<String, Action> = df::borrow(&entity.id, ActionsKey());
    assert!(actions.contains(&action), EUnknownAction);
    let request = actions
        .get(&action)
        .to_request(
            option::some(entity.id.to_inner()),
            vector[location_service::proximity_requirement(target_location_hash)],
        );

    entity.lock();
    request
}

/// Mutable access to a module, only valid mid-interaction. The target module
/// id is read off the request's next requirement (not the caller's args), so
/// a handler can never mutate the wrong module.
public fun module_mut<T: store>(entity: &mut Entity, req: &Request, _: Permit<T>): &mut Module<T> {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(entity.is_locked(), ENotLocked);
    assert!(req.entity_id().is_some_and!(|id| id == entity.id.to_inner()), EWrongEntity);

    let module_id = req.next().module_id().destroy_or!(abort ERequirementNotModuleScoped);
    df::borrow_mut(&mut entity.id, ModuleKey(module_id))
}

/// Read-only access to a module by `module_id`. `Permit<T>` enforces that only the
/// package that authored `T` can read it; no lock is required since nothing
/// is mutated.
public fun module_ref<T: store>(entity: &Entity, module_id: u64, _: Permit<T>): &Module<T> {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(df::exists_with_type<_, Module<T>>(&entity.id, ModuleKey(module_id)), EModuleMissing);
    df::borrow(&entity.id, ModuleKey(module_id))
}

/// Start admin teardown. Aborts if any module is still installed. The request
/// carries `admin_requirement` today; more requirements can be added later.
/// Finish with `verify_admin` (and any future handlers) then `delete`.
public fun request_delete(entity: &mut Entity): (Request, DeleteTicket) {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(!entity.is_locked(), ELocked);
    assert!(entity.module_ids.is_empty(), EModulesRemain);
    entity.lock();
    let entity_id = entity.id.to_inner();
    let req = request::new(
        option::some(entity_id),
        vector[admin_service::admin_requirement()],
    );
    (req, DeleteTicket { entity_id })
}

/// Consume the entity after `request_delete` and a completed request. Strips
/// remaining DFs and deletes the UID. The derived `EntityKey` stays claimed.
public fun delete(mut entity: Entity, req: Request, ticket: DeleteTicket) {
    assert!(entity.version == VERSION, EWrongVersion);
    assert!(entity.is_locked(), ENotLocked);
    assert!(entity.module_ids.is_empty(), EModulesRemain);
    let DeleteTicket { entity_id } = ticket;
    assert!(entity_id == entity.id.to_inner(), EWrongEntity);
    req.entity_id().do!(|id| assert!(id == entity.id.to_inner(), EWrongEntity));
    req.complete();
    entity.unlock();

    let _: VecMap<String, Action> = df::remove(&mut entity.id, ActionsKey());
    let Entity { id, version: _, key, module_ids: _ } = entity;
    event::emit(EntityDeleted { entity_id: id.to_inner(), key });
    id.delete();
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

public fun has_module(entity: &Entity, module_id: u64): bool {
    df::exists(&entity.id, ModuleKey(module_id))
}

public fun has_module_with_type<T: store>(entity: &Entity, module_id: u64): bool {
    df::exists_with_type<_, Module<T>>(&entity.id, ModuleKey(module_id))
}

public fun version(entity: &Entity): u64 {
    entity.version
}

public fun module_ids(entity: &Entity): &vector<u64> {
    &entity.module_ids
}

// === Private Functions ===

fun lock(entity: &mut Entity) {
    df::add(&mut entity.id, InFlight(), true);
}

fun unlock(entity: &mut Entity) {
    let _: bool = df::remove(&mut entity.id, InFlight());
}

fun is_locked(entity: &Entity): bool {
    df::exists(&entity.id, InFlight())
}
