/// This module handles the functionality of the in-game Refinery Assembly.
///
/// A Refinery is a programmable on-chain industrial structure. It consumes input
/// items, runs a timed processing job per a registered `Recipe`, and produces
/// output items into the same inventory.
///
/// Like the StorageUnit, behaviour is customizable via the typed witness pattern
/// (see `authorize_extension`). Two access modes are supported:
///
/// 1. **Extension-based access**
///    - `deposit_input<Auth>`, `withdraw_input<Auth>`, `start_job<Auth>`, `claim_outputs<Auth>`
///    - Allows custom contracts to drive the refinery on behalf of the owner
///
/// 2. **Owner-direct access**
///    - `*_by_owner` variants, gated by `OwnerCap` + sender == character address
///
/// # Job model (v1)
///
/// At most **one** active job per refinery at any time. `start_job`:
///   - looks up the recipe by `input_type_id`
///   - consumes `recipe.input_quantity` from the input inventory
///   - records `started_at_ms` / `finishes_at_ms` on the refinery
///   - emits `JobStartedEvent`
///
/// `claim_outputs`:
///   - asserts no remaining processing time
///   - mints each output type into the inventory in place (per-type quantity from the recipe)
///   - clears the active job slot
///   - emits `JobClaimedEvent`
///
/// Input and output items share one inventory keyed by `owner_cap_id` — recipes are
/// forbidden from naming the input as an output (enforced in `world::recipe`), so
/// there is no ambiguity.
///
/// Future: multi-input recipes, variable yield, parallel jobs, throughput modifiers.
module world::refinery;

use std::{string::String, type_name::{Self, TypeName}};
use sui::{clock::Clock, derived_object, dynamic_field as df, event};
use world::{
    access::{Self, OwnerCap, AdminACL},
    character::Character,
    extension_freeze,
    in_game_id::{Self, TenantItemId},
    inventory::{Self, Inventory, Item},
    location::{Self, Location},
    metadata::{Self, Metadata},
    network_node::NetworkNode,
    object_registry::ObjectRegistry,
    recipe::{Self, RecipeRegistry},
    status::{Self, AssemblyStatus}
};

// === Errors ===
#[error(code = 0)]
const ERefineryTypeIdEmpty: vector<u8> = b"Refinery TypeId is empty";
#[error(code = 1)]
const ERefineryItemIdEmpty: vector<u8> = b"Refinery ItemId is empty";
#[error(code = 2)]
const ERefineryAlreadyExists: vector<u8> = b"Refinery with the same Item Id already exists";
#[error(code = 3)]
const EExtensionNotAuthorized: vector<u8> =
    b"Access only authorized for the custom contract of the registered type";
#[error(code = 4)]
const EInventoryNotAuthorized: vector<u8> = b"Inventory Access not authorized";
#[error(code = 5)]
const ENotOnline: vector<u8> = b"Refinery is not online";
#[error(code = 6)]
const ETenantMismatch: vector<u8> = b"Item cannot be transferred across tenants";
#[error(code = 7)]
const ESenderCannotAccessCharacter: vector<u8> = b"Address cannot access Character";
#[error(code = 8)]
const EItemParentMismatch: vector<u8> = b"Item was not withdrawn from this refinery";
#[error(code = 9)]
const EJobInProgress: vector<u8> = b"Refinery already has an active job";
#[error(code = 10)]
const ENoActiveJob: vector<u8> = b"Refinery has no active job";
#[error(code = 11)]
const EJobNotComplete: vector<u8> = b"Active job has not finished processing";
#[error(code = 12)]
const ERecipeNotFound: vector<u8> = b"No recipe registered for the requested input type";
// (note: EInsufficientInput removed — inventory::withdraw_item already aborts with
//  EInventoryInsufficientQuantity when there isn't enough input.)
#[error(code = 14)]
const EExtensionConfigFrozen: vector<u8> = b"Extension configuration is frozen";
#[error(code = 15)]
const EExtensionNotConfigured: vector<u8> = b"Extension must be configured before freezing";
#[error(code = 16)]
const ENoExtensionToRevoke: vector<u8> = b"No extension authorization to revoke";

// === Structs ===

public struct Refinery has key {
    id: UID,
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    status: AssemblyStatus,
    location: Location,
    inventory_keys: vector<ID>,
    energy_source_id: Option<ID>,
    metadata: Option<Metadata>,
    extension: Option<TypeName>,
    active_job: Option<Job>,
}

/// Snapshot of a running processing job. Stored inline on `Refinery` to keep the
/// "one job at a time" invariant trivial to enforce. Output recipe details are
/// snapshotted at start so admins changing a recipe mid-flight don't change
/// already-running jobs.
public struct Job has copy, drop, store {
    input_type_id: u64,
    input_quantity: u32,
    output_type_ids: vector<u64>,
    output_quantities: vector<u32>,
    started_at_ms: u64,
    finishes_at_ms: u64,
}

// === Events ===

public struct RefineryCreatedEvent has copy, drop {
    refinery_id: ID,
    assembly_key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    max_capacity: u64,
    location_hash: vector<u8>,
}

public struct ExtensionAuthorizedEvent has copy, drop {
    refinery_id: ID,
    assembly_key: TenantItemId,
    owner_cap_id: ID,
    extension_type: TypeName,
    previous_extension: Option<TypeName>,
}

public struct ExtensionRevokedEvent has copy, drop {
    refinery_id: ID,
    assembly_key: TenantItemId,
    owner_cap_id: ID,
    extension_type: TypeName,
}

public struct JobStartedEvent has copy, drop {
    refinery_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    input_type_id: u64,
    input_quantity: u32,
    started_at_ms: u64,
    finishes_at_ms: u64,
    output_type_ids: vector<u64>,
    output_quantities: vector<u32>,
}

public struct JobClaimedEvent has copy, drop {
    refinery_id: ID,
    assembly_key: TenantItemId,
    character_id: ID,
    input_type_id: u64,
    output_type_ids: vector<u64>,
    output_quantities: vector<u32>,
    claimed_at_ms: u64,
}

// === Anchor / share ===

public fun anchor(
    registry: &mut ObjectRegistry,
    network_node: &mut NetworkNode,
    character: &Character,
    admin_acl: &AdminACL,
    item_id: u64,
    type_id: u64,
    max_capacity: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): Refinery {
    assert!(type_id != 0, ERefineryTypeIdEmpty);
    assert!(item_id != 0, ERefineryItemIdEmpty);

    let refinery_key = in_game_id::create_key(item_id, character.tenant());
    assert!(!registry.object_exists(refinery_key), ERefineryAlreadyExists);

    let assembly_uid = derived_object::claim(registry.borrow_registry_id(), refinery_key);
    let assembly_id = object::uid_to_inner(&assembly_uid);
    let network_node_id = object::id(network_node);

    let owner_cap = access::create_owner_cap_by_id<Refinery>(assembly_id, admin_acl, ctx);
    let owner_cap_id = object::id(&owner_cap);

    let mut refinery = Refinery {
        id: assembly_uid,
        key: refinery_key,
        owner_cap_id,
        type_id,
        status: status::anchor(assembly_id, refinery_key),
        location: location::attach(location_hash),
        inventory_keys: vector[],
        energy_source_id: option::some(network_node_id),
        metadata: option::some(
            metadata::create_metadata(
                assembly_id,
                refinery_key,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        extension: option::none(),
        active_job: option::none(),
    };

    access::transfer_owner_cap(owner_cap, object::id_address(character));

    network_node.connect_assembly(assembly_id);

    let inv = inventory::create(max_capacity);
    refinery.inventory_keys.push_back(owner_cap_id);
    df::add(&mut refinery.id, owner_cap_id, inv);

    event::emit(RefineryCreatedEvent {
        refinery_id: assembly_id,
        assembly_key: refinery_key,
        owner_cap_id,
        type_id,
        max_capacity,
        location_hash,
    });

    refinery
}

public fun share_refinery(refinery: Refinery, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    transfer::share_object(refinery);
}

// === Extension ===

public fun authorize_extension<Auth: drop>(
    refinery: &mut Refinery,
    owner_cap: &OwnerCap<Refinery>,
) {
    check_owner_cap(refinery, owner_cap);
    assert!(!extension_freeze::is_extension_frozen(&refinery.id), EExtensionConfigFrozen);

    let new_type = type_name::with_defining_ids<Auth>();
    let previous = refinery.extension;
    refinery.extension = option::some(new_type);

    event::emit(ExtensionAuthorizedEvent {
        refinery_id: object::id(refinery),
        assembly_key: refinery.key,
        owner_cap_id: refinery.owner_cap_id,
        extension_type: new_type,
        previous_extension: previous,
    });
}

public fun revoke_extension_authorization(
    refinery: &mut Refinery,
    owner_cap: &OwnerCap<Refinery>,
) {
    check_owner_cap(refinery, owner_cap);
    assert!(!extension_freeze::is_extension_frozen(&refinery.id), EExtensionConfigFrozen);
    assert!(refinery.extension.is_some(), ENoExtensionToRevoke);
    let removed = refinery.extension.extract();

    event::emit(ExtensionRevokedEvent {
        refinery_id: object::id(refinery),
        assembly_key: refinery.key,
        owner_cap_id: refinery.owner_cap_id,
        extension_type: removed,
    });
}

public fun freeze_extension_config(refinery: &mut Refinery, owner_cap: &OwnerCap<Refinery>) {
    check_owner_cap(refinery, owner_cap);
    assert!(refinery.extension.is_some(), EExtensionNotConfigured);
    let refinery_id = object::id(refinery);
    extension_freeze::freeze_extension_config(&mut refinery.id, refinery_id);
}

// === Online / offline ===

public fun online(refinery: &mut Refinery, owner_cap: &OwnerCap<Refinery>) {
    check_owner_cap(refinery, owner_cap);
    let refinery_id = object::id(refinery);
    refinery.status.online(refinery_id, refinery.key);
}

public fun offline(refinery: &mut Refinery, owner_cap: &OwnerCap<Refinery>) {
    check_owner_cap(refinery, owner_cap);
    let refinery_id = object::id(refinery);
    refinery.status.offline(refinery_id, refinery.key);
}

// === Inventory: extension-gated ===

public fun deposit_input<Auth: drop>(
    refinery: &mut Refinery,
    character: &Character,
    item: Item,
    _: Auth,
    _: &mut TxContext,
) {
    check_extension_authorized<Auth>(refinery);
    assert!(refinery.status.is_online(), ENotOnline);
    let refinery_id = object::id(refinery);
    assert!(inventory::tenant(&item) == refinery.key.tenant(), ETenantMismatch);
    assert!(inventory::parent_id(&item) == refinery_id, EItemParentMismatch);

    let inv = df::borrow_mut<ID, Inventory>(&mut refinery.id, refinery.owner_cap_id);
    inventory::deposit_item(inv, refinery_id, refinery.key, character, item);
}

public fun withdraw_input<Auth: drop>(
    refinery: &mut Refinery,
    character: &Character,
    _: Auth,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): Item {
    check_extension_authorized<Auth>(refinery);
    assert!(refinery.status.is_online(), ENotOnline);
    let refinery_id = object::id(refinery);
    let inv = df::borrow_mut<ID, Inventory>(&mut refinery.id, refinery.owner_cap_id);
    inventory::withdraw_item(
        inv,
        refinery_id,
        refinery.key,
        character,
        type_id,
        quantity,
        refinery.location.hash(),
        ctx,
    )
}

// === Inventory: owner-direct ===

public fun deposit_input_by_owner<T: key>(
    refinery: &mut Refinery,
    item: Item,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    check_owner_cap_generic(refinery, owner_cap);
    let refinery_id = object::id(refinery);
    assert!(refinery.status.is_online(), ENotOnline);
    assert!(inventory::tenant(&item) == refinery.key.tenant(), ETenantMismatch);
    assert!(inventory::parent_id(&item) == refinery_id, EItemParentMismatch);

    let inv = df::borrow_mut<ID, Inventory>(&mut refinery.id, refinery.owner_cap_id);
    inventory::deposit_item(inv, refinery_id, refinery.key, character, item);
}

public fun withdraw_input_by_owner<T: key>(
    refinery: &mut Refinery,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    type_id: u64,
    quantity: u32,
    ctx: &mut TxContext,
): Item {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    check_owner_cap_generic(refinery, owner_cap);
    let refinery_id = object::id(refinery);
    assert!(refinery.status.is_online(), ENotOnline);

    let inv = df::borrow_mut<ID, Inventory>(&mut refinery.id, refinery.owner_cap_id);
    inventory::withdraw_item(
        inv,
        refinery_id,
        refinery.key,
        character,
        type_id,
        quantity,
        refinery.location.hash(),
        ctx,
    )
}

// === Jobs ===

/// Extension-gated. Looks up a recipe by `input_type_id`, consumes
/// `recipe.input_quantity` from inventory, and records the job start.
public fun start_job<Auth: drop>(
    refinery: &mut Refinery,
    character: &Character,
    recipes: &RecipeRegistry,
    clock: &Clock,
    input_type_id: u64,
    _: Auth,
    ctx: &mut TxContext,
) {
    check_extension_authorized<Auth>(refinery);
    start_job_internal(refinery, character, recipes, clock, input_type_id, ctx);
}

public fun start_job_by_owner<T: key>(
    refinery: &mut Refinery,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    recipes: &RecipeRegistry,
    clock: &Clock,
    input_type_id: u64,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    check_owner_cap_generic(refinery, owner_cap);
    start_job_internal(refinery, character, recipes, clock, input_type_id, ctx);
}

/// Extension-gated. Mints recipe outputs into the inventory and clears the active job.
public fun claim_outputs<Auth: drop>(
    refinery: &mut Refinery,
    character: &Character,
    clock: &Clock,
    _: Auth,
    _: &mut TxContext,
) {
    check_extension_authorized<Auth>(refinery);
    claim_outputs_internal(refinery, character, clock);
}

public fun claim_outputs_by_owner<T: key>(
    refinery: &mut Refinery,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(character.character_address() == ctx.sender(), ESenderCannotAccessCharacter);
    check_owner_cap_generic(refinery, owner_cap);
    claim_outputs_internal(refinery, character, clock);
}

// === Views ===

public fun id(refinery: &Refinery): ID { object::id(refinery) }
public fun key(refinery: &Refinery): TenantItemId { refinery.key }
public fun owner_cap_id(refinery: &Refinery): ID { refinery.owner_cap_id }
public fun type_id(refinery: &Refinery): u64 { refinery.type_id }
public fun status(refinery: &Refinery): &AssemblyStatus { &refinery.status }
public fun location(refinery: &Refinery): &Location { &refinery.location }
public fun energy_source_id(refinery: &Refinery): &Option<ID> { &refinery.energy_source_id }
public fun has_active_job(refinery: &Refinery): bool { refinery.active_job.is_some() }
public fun active_job(refinery: &Refinery): &Option<Job> { &refinery.active_job }

public fun job_input_type_id(job: &Job): u64 { job.input_type_id }
public fun job_input_quantity(job: &Job): u32 { job.input_quantity }
public fun job_output_type_ids(job: &Job): &vector<u64> { &job.output_type_ids }
public fun job_output_quantities(job: &Job): &vector<u32> { &job.output_quantities }
public fun job_started_at_ms(job: &Job): u64 { job.started_at_ms }
public fun job_finishes_at_ms(job: &Job): u64 { job.finishes_at_ms }

public fun inventory(refinery: &Refinery, owner_cap_id: ID): &Inventory {
    df::borrow(&refinery.id, owner_cap_id)
}

#[test_only]
public fun item_quantity(refinery: &Refinery, owner_cap_id: ID, type_id: u64): u32 {
    let inv = df::borrow<ID, Inventory>(&refinery.id, owner_cap_id);
    inv.item_quantity(type_id)
}

// === Internal ===

fun check_extension_authorized<Auth: drop>(refinery: &Refinery) {
    assert!(refinery.extension.is_some(), EExtensionNotAuthorized);
    let expected = type_name::with_defining_ids<Auth>();
    assert!(*refinery.extension.borrow() == expected, EExtensionNotAuthorized);
}

fun check_owner_cap(refinery: &Refinery, owner_cap: &OwnerCap<Refinery>) {
    assert!(object::id(owner_cap) == refinery.owner_cap_id, EInventoryNotAuthorized);
}

fun check_owner_cap_generic<T: key>(refinery: &Refinery, owner_cap: &OwnerCap<T>) {
    assert!(object::id(owner_cap) == refinery.owner_cap_id, EInventoryNotAuthorized);
}

fun start_job_internal(
    refinery: &mut Refinery,
    character: &Character,
    recipes: &RecipeRegistry,
    clock: &Clock,
    input_type_id: u64,
    _ctx: &mut TxContext,
) {
    assert!(refinery.status.is_online(), ENotOnline);
    assert!(refinery.active_job.is_none(), EJobInProgress);
    assert!(recipe::has_recipe(recipes, input_type_id), ERecipeNotFound);

    let r = recipe::borrow_recipe(recipes, input_type_id);
    let needed = recipe::input_quantity(r);
    let processing = recipe::processing_time_ms(r);
    let output_type_ids = *recipe::output_type_ids(r);
    let output_quantities = *recipe::output_quantities(r);

    let refinery_id = object::id(refinery);
    let location_hash = refinery.location.hash();
    let refinery_key = refinery.key;
    let inv = df::borrow_mut<ID, Inventory>(&mut refinery.id, refinery.owner_cap_id);

    // `inventory::withdraw_item` aborts with EInventoryInsufficientQuantity if there
    // isn't enough input on hand — no separate pre-check needed (and there's no
    // non-test-only quantity reader on Inventory today).
    // Consume the input by withdrawing then immediately sink-transferring the transit Item.
    let consumed = inventory::withdraw_item(
        inv,
        refinery_id,
        refinery_key,
        character,
        input_type_id,
        needed,
        location_hash,
        _ctx,
    );
    // Sink the transit Item to 0x0 — input has been logically consumed.
    // NB: a public `inventory::destroy_item` would be cleaner; sink-transfer works
    // because Items at 0x0 are unreachable from any character-derived inventory key.
    transfer::public_transfer(consumed, @0x0);

    let now_ms = clock.timestamp_ms();
    let job = Job {
        input_type_id,
        input_quantity: needed,
        output_type_ids,
        output_quantities,
        started_at_ms: now_ms,
        finishes_at_ms: now_ms + processing,
    };
    refinery.active_job = option::some(job);

    event::emit(JobStartedEvent {
        refinery_id,
        assembly_key: refinery.key,
        character_id: character.id(),
        input_type_id,
        input_quantity: needed,
        started_at_ms: now_ms,
        finishes_at_ms: now_ms + processing,
        output_type_ids,
        output_quantities,
    });
}

fun claim_outputs_internal(
    refinery: &mut Refinery,
    character: &Character,
    clock: &Clock,
) {
    assert!(refinery.status.is_online(), ENotOnline);
    assert!(refinery.active_job.is_some(), ENoActiveJob);
    let now_ms = clock.timestamp_ms();
    let job_ref = refinery.active_job.borrow();
    assert!(now_ms >= job_ref.finishes_at_ms, EJobNotComplete);

    let job = refinery.active_job.extract();
    let Job {
        input_type_id,
        input_quantity: _,
        output_type_ids,
        output_quantities,
        started_at_ms: _,
        finishes_at_ms: _,
    } = job;

    let refinery_id = object::id(refinery);
    let tenant = refinery.key.tenant();
    let refinery_key = refinery.key;
    let inv = df::borrow_mut<ID, Inventory>(&mut refinery.id, refinery.owner_cap_id);

    let n = vector::length(&output_type_ids);
    let mut i = 0;
    while (i < n) {
        let out_type = *vector::borrow(&output_type_ids, i);
        let out_qty = *vector::borrow(&output_quantities, i);
        // Placeholder item_id; production code should use a counter on the refinery
        // for stable item_ids — left as a follow-up.
        let placeholder_item_id = out_type;
        // Volume of 1 is a sentinel; the first ever mint at this type_id locks volume.
        inventory::mint_items(
            inv,
            refinery_id,
            refinery_key,
            character,
            tenant,
            placeholder_item_id,
            out_type,
            1,
            out_qty,
        );
        i = i + 1;
    };

    event::emit(JobClaimedEvent {
        refinery_id,
        assembly_key: refinery.key,
        character_id: character.id(),
        input_type_id,
        output_type_ids,
        output_quantities,
        claimed_at_ms: now_ms,
    });
}

