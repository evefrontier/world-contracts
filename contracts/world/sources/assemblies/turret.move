/// This module handles the functionality of in-game Smart Turrets.
///
/// A Turret is a programmable structure in space that projects offensive or defensive power over
/// a fixed location. Anchored to another owned Smart Assembly, it operates under builder-defined
/// rules enforced on chain for targeting priorities.
///
/// Builders control two key behaviours: InProximity (reacts to ships entering range) and
/// Aggression (responds to hostile actions like starting to attack the base or stopping to attack the base)
/// A configurable on-chain priority queue determines how targets are ranked and attacked.
/// The owner can define custom logic through extension contracts using the typed witness pattern to
/// control the target priority queue.
///
/// By default the game calls `world::turret::get_target_priority_list` to get the priority list of targets to attack.
/// If an extension is configured via the auth witness pattern (`authorize_extension`), the game
/// resolves the package id from the configured/authorised type name and calls the
/// `get_target_priority_list` function in the extension package where that auth type is defined.
module world::turret;

use std::{string::String, type_name::{Self, TypeName}};
use sui::{bcs, derived_object, event};
use world::{
    access::{Self, OwnerCap, AdminACL},
    character::{Self, Character},
    energy::EnergyConfig,
    extension_freeze,
    in_game_id::{Self, TenantItemId},
    location::{Self, Location, LocationRegistry},
    metadata::{Self, Metadata},
    network_node::{NetworkNode, UpdateEnergySources, OfflineAssemblies, HandleOrphanedAssemblies},
    object_registry::ObjectRegistry,
    status::{Self, AssemblyStatus}
};

// === Errors ===
#[error(code = 0)]
const ETurretNotAuthorized: vector<u8> = b"Caller is not authorized to authorize the Turret";
#[error(code = 1)]
const ENetworkNodeMismatch: vector<u8> = b"Network node mismatch";
#[error(code = 2)]
const ENotOnline: vector<u8> = b"Turret is not online";
#[error(code = 3)]
const ETurretTypeIdEmpty: vector<u8> = b"Turret type ID is empty";
#[error(code = 4)]
const ETurretItemIdEmpty: vector<u8> = b"Turret item ID is empty";
#[error(code = 5)]
const ETurretAlreadyExists: vector<u8> = b"Turret with this item ID already exists";
#[error(code = 6)]
const ETurretHasEnergySource: vector<u8> = b"Turret has an energy source";
#[error(code = 7)]
const EExtensionConfigured: vector<u8> = b"Extension is configured";
#[error(code = 8)]
const EInvalidOnlineReceipt: vector<u8> = b"Invalid online receipt";
#[error(code = 9)]
const EMetadataNotSet: vector<u8> = b"Metadata not set on assembly";
#[error(code = 10)]
const EExtensionConfigFrozen: vector<u8> = b"Extension configuration is frozen";
#[error(code = 11)]
const EExtensionNotConfigured: vector<u8> = b"Extension must be configured before freezing";

// Priority weight increments applied by default rules (effective_weight_and_excluded)
const STARTED_ATTACK_WEIGHT_INCREMENT: u64 = 10000;
const ENTERED_WEIGHT_INCREMENT: u64 = 1000;

// === Enums ===
/// Reason for invoking get_target_priority_list; the game sends exactly one per target candidate.
public enum BehaviourChangeReason has copy, drop, store {
    UNSPECIFIED,
    ENTERED, // target entered the proximity of the turret
    STARTED_ATTACK, // target started attacking the base
    STOPPED_ATTACK, // target stopped attacking the base
}

// === Structs ===
public struct Turret has key {
    id: UID,
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    status: AssemblyStatus,
    location: Location,
    energy_source_id: Option<ID>,
    metadata: Option<Metadata>,
    extension: Option<TypeName>,
}

/// Target information struct
public struct TargetCandidate has copy, drop, store {
    // unique identifier for the target candidate (ship_id/npc_id)
    item_id: u64,
    // target candidate type either a ship or a NPC
    type_id: u64,
    // target group id, this is none for npcs, This can help the turret to prioritize the targets
    // as the turret can be specialized against a specific group of ships <todo: doc link>
    group_id: u64,
    // Pilot character id; use 0 for NPCs
    character_id: u32,
    // Character tribe; use 0 for NPCs (same as character_id).
    character_tribe: u32,
    // percentage of structure hit points remaining (0-100)
    hp_ratio: u64,
    // percentage of shield hit points remaining (0-100)
    shield_ratio: u64,
    // percentage of armor hit points remaining (0-100)
    armor_ratio: u64,
    // is this target attacking anyone on grid (structure or another player)
    is_aggressor: bool,
    // priority weight of the target, this is used to sort the targets in the priority list
    priority_weight: u64,
    // One reason per candidate; game sends the single most relevant (e.g. STARTED_ATTACK over ENTERED when both apply).
    behaviour_change: BehaviourChangeReason,
}

/// Return Target info struct
/// Game starts shooting the target with the highest priority weight in the list,
/// If it has the same priority weight, it will shoot the first one in the list.
public struct ReturnTargetPriorityList has copy, drop, store {
    // unique identifier for the target candidate (ship_id/npc_id)
    target_item_id: u64,
    priority_weight: u64,
}

/// Proof that a turret was online
public struct OnlineReceipt {
    turret_id: ID,
}

// === Events ===
public struct TurretCreatedEvent has copy, drop {
    turret_id: ID,
    turret_key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
}

public struct PriorityListUpdatedEvent has copy, drop {
    turret_id: ID,
    priority_list: vector<TargetCandidate>,
}

public struct ExtensionAuthorizedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    extension_type: TypeName,
    previous_extension: Option<TypeName>,
    owner_cap_id: ID,
}

// === Public Functions ===
public fun authorize_extension<Auth: drop>(turret: &mut Turret, owner_cap: &OwnerCap<Turret>) {
    let turret_id = object::id(turret);
    assert!(access::is_authorized(owner_cap, turret_id), ETurretNotAuthorized);
    assert!(!extension_freeze::is_extension_frozen(&turret.id), EExtensionConfigFrozen);
    let previous_extension = turret.extension;
    turret.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
    event::emit(ExtensionAuthorizedEvent {
        assembly_id: turret_id,
        assembly_key: turret.key,
        extension_type: type_name::with_defining_ids<Auth>(),
        previous_extension,
        owner_cap_id: object::id(owner_cap),
    });
}

/// Freezes the turret's extension configuration so the owner can no longer change it (builds user trust).
/// Requires an extension to be configured. One-time; cannot be undone.
public fun freeze_extension_config(turret: &mut Turret, owner_cap: &OwnerCap<Turret>) {
    let turret_id = object::id(turret);
    assert!(access::is_authorized(owner_cap, turret_id), ETurretNotAuthorized);
    assert!(option::is_some(&turret.extension), EExtensionNotConfigured);
    assert!(!extension_freeze::is_extension_frozen(&turret.id), EExtensionConfigFrozen);
    extension_freeze::freeze_extension_config(&mut turret.id, turret_id);
}

public fun online(
    turret: &mut Turret,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<Turret>,
) {
    let turret_id = object::id(turret);
    assert!(access::is_authorized(owner_cap, turret_id), ETurretNotAuthorized);
    assert!(
        option::contains(&turret.energy_source_id, &object::id(network_node)),
        ENetworkNodeMismatch,
    );
    reserve_energy(turret, network_node, energy_config);
    turret.status.online(turret_id, turret.key);
}

public fun offline(
    turret: &mut Turret,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<Turret>,
) {
    let turret_id = object::id(turret);
    assert!(access::is_authorized(owner_cap, turret_id), ETurretNotAuthorized);
    assert!(
        option::contains(&turret.energy_source_id, &object::id(network_node)),
        ENetworkNodeMismatch,
    );
    release_energy(turret, network_node, energy_config);

    turret.status.offline(turret_id, turret.key);
}

/// Updates the turret's energy source and removes it from the UpdateEnergySources hot potato.
/// Must be called for each turret in the hot potato returned by connect_assemblies.
public fun update_energy_source_connected_turret(
    turret: &mut Turret,
    mut update_energy_sources: UpdateEnergySources,
    network_node: &NetworkNode,
): UpdateEnergySources {
    if (update_energy_sources.update_energy_sources_ids_length() > 0) {
        let turret_id = object::id(turret);
        let found = update_energy_sources.remove_energy_sources_assembly_id(turret_id);
        if (found) {
            assert!(!turret.status.is_online(), ENotOnline);
            turret.energy_source_id = option::some(object::id(network_node));
        };
    };
    update_energy_sources
}

/// Brings a connected turret offline and removes it from the hot potato
public fun offline_connected_turret(
    turret: &mut Turret,
    mut offline_assemblies: OfflineAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): OfflineAssemblies {
    if (offline_assemblies.ids_length() > 0) {
        let turret_id = object::id(turret);

        let found = offline_assemblies.remove_assembly_id(turret_id);
        if (found) {
            if (turret.status.is_online()) {
                turret.status.offline(turret_id, turret.key);
                release_energy(turret, network_node, energy_config);
            };
        }
    };
    offline_assemblies
}

/// Brings a connected turret offline, releases energy, clears energy source, and removes it from the hot potato
/// Must be called for each turret in the hot potato returned by nwn.unanchor()
/// Returns the updated HandleOrphanedAssemblies; after all are processed, call destroy_network_node with it
public fun offline_orphaned_turret(
    turret: &mut Turret,
    mut orphaned_assemblies: HandleOrphanedAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): HandleOrphanedAssemblies {
    if (orphaned_assemblies.orphaned_assemblies_length() > 0) {
        let turret_id = object::id(turret);
        let found = orphaned_assemblies.remove_orphaned_assembly_id(turret_id);
        if (found) {
            // Bring turret offline and release energy if needed
            if (turret.status.is_online()) {
                turret.status.offline(turret_id, turret.key);
                release_energy(turret, network_node, energy_config);
            };

            turret.energy_source_id = option::none();
        }
    };
    orphaned_assemblies
}

/// Returns a receipt proving the turret is online. Aborts if turret is offline.
public fun verify_online(turret: &Turret): OnlineReceipt {
    assert!(turret.status.is_online(), ENotOnline);
    OnlineReceipt { turret_id: object::id(turret) }
}

// This behaviour of this function can be customized by the builder through the extension contract.
/// Called by the game whenever target behaviour changes (e.g. a ship enters range, starts or stops attacking).
/// The game sends exactly one behaviour_change per candidate; if both ENTERED and STARTED_ATTACK apply,
/// the game sends STARTED_ATTACK (higher priority). This function applies the rules and returns which
/// targets to shoot and at what priority weight.
/// - `turret`: the programmable turret.
/// - `owner_character`: the character that owns the turret.
/// - `target_candidate_list`: BCS of vector<TargetCandidate> (targets in proximity, each with one behaviour_change).
/// Returns BCS of vector<ReturnTargetPriorityList> (target_item_id, priority_weight).
/// The game shoots the target with the highest priority weight,
/// if it has the same priority weight, it will shoot the first one in the list.
public fun get_target_priority_list(
    turret: &Turret,
    owner_character: &Character,
    target_candidate_list: vector<u8>,
    receipt: OnlineReceipt,
): vector<u8> {
    assert!(receipt.turret_id() == object::id(turret), EInvalidOnlineReceipt);
    assert!(option::is_none(&turret.extension), EExtensionConfigured);

    let candidates = unpack_candidate_list(target_candidate_list);
    let return_list = build_return_priority_list(&candidates, owner_character);
    let OnlineReceipt { .. } = receipt;
    event::emit(PriorityListUpdatedEvent {
        turret_id: object::id(turret),
        priority_list: candidates,
    });
    bcs::to_bytes(&return_list)
}

public fun destroy_online_receipt<Auth: drop>(receipt: OnlineReceipt, _: Auth) {
    let OnlineReceipt { .. } = receipt;
}

/// Deserializes vector<TargetCandidate> from BCS bytes.
public fun unpack_candidate_list(candidate_list_bytes: vector<u8>): vector<TargetCandidate> {
    if (vector::length(&candidate_list_bytes) == 0) {
        return vector::empty()
    };
    let mut bcs_data = bcs::new(candidate_list_bytes);
    bcs_data.peel_vec!(|bcs| peel_target_candidate_from_bcs(bcs))
}

/// Alias for unpack_candidate_list (e.g. for extensions).
public fun unpack_priority_list(candidate_list_bytes: vector<u8>): vector<TargetCandidate> {
    unpack_candidate_list(candidate_list_bytes)
}

/// Deserializes vector<ReturnTargetPriorityList> from BCS bytes.
public fun unpack_return_priority_list(return_bytes: vector<u8>): vector<ReturnTargetPriorityList> {
    if (vector::length(&return_bytes) == 0) {
        return vector::empty()
    };
    let mut bcs_data = bcs::new(return_bytes);
    bcs_data.peel_vec!(|bcs| peel_return_target_priority_list_from_bcs(bcs))
}

/// Deserializes a TargetCandidate from BCS bytes (field order: item_id, type_id, group_id,
/// character_id, character_tribe, hp_ratio, shield_ratio, armor_ratio, is_aggressor, priority_weight, behaviour_change u8).
public fun peel_target_candidate(candidate_bytes: vector<u8>): TargetCandidate {
    let mut bcs_data = bcs::new(candidate_bytes);
    peel_target_candidate_from_bcs(&mut bcs_data)
}

public fun update_metadata_name(turret: &mut Turret, owner_cap: &OwnerCap<Turret>, name: String) {
    assert!(access::is_authorized(owner_cap, object::id(turret)), ETurretNotAuthorized);
    assert!(option::is_some(&turret.metadata), EMetadataNotSet);
    let metadata = option::borrow_mut(&mut turret.metadata);
    metadata.update_name(turret.key, name);
}

public fun update_metadata_description(
    turret: &mut Turret,
    owner_cap: &OwnerCap<Turret>,
    description: String,
) {
    assert!(access::is_authorized(owner_cap, object::id(turret)), ETurretNotAuthorized);
    assert!(option::is_some(&turret.metadata), EMetadataNotSet);
    let metadata = option::borrow_mut(&mut turret.metadata);
    metadata.update_description(turret.key, description);
}

public fun update_metadata_url(turret: &mut Turret, owner_cap: &OwnerCap<Turret>, url: String) {
    assert!(access::is_authorized(owner_cap, object::id(turret)), ETurretNotAuthorized);
    assert!(option::is_some(&turret.metadata), EMetadataNotSet);
    let metadata = option::borrow_mut(&mut turret.metadata);
    metadata.update_url(turret.key, url);
}

/// Reveals plain-text location (solarsystem, x, y, z) for this turret. Admin ACL only. Optional; enables dapps (e.g. route maps).
/// Temporary: use until the offchain location reveal service is ready.
public fun reveal_location(
    turret: &Turret,
    registry: &mut LocationRegistry,
    admin_acl: &AdminACL,
    solarsystem: u64,
    x: String,
    y: String,
    z: String,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    location::reveal_location(
        registry,
        object::id(turret),
        turret.key,
        turret.type_id,
        turret.owner_cap_id,
        location::hash(&turret.location),
        solarsystem,
        x,
        y,
        z,
    );
}

// === View Functions ===
public fun status(turret: &Turret): &AssemblyStatus {
    &turret.status
}

public fun location(turret: &Turret): &Location {
    &turret.location
}

public fun is_online(turret: &Turret): bool {
    turret.status.is_online()
}

public fun owner_cap_id(turret: &Turret): ID {
    turret.owner_cap_id
}

/// Returns the turret's energy source (network node) ID if set
public fun energy_source_id(turret: &Turret): &Option<ID> {
    &turret.energy_source_id
}

/// if its authorized, return the configured extension type (if any)
public fun extension_type(turret: &Turret): TypeName {
    *option::borrow(&turret.extension)
}

/// Returns true if the turret is configured with extension logic
public fun is_extension_configured(turret: &Turret): bool {
    option::is_some(&turret.extension)
}

/// Returns true if the turret's extension configuration is frozen (owner cannot change extension).
public fun is_extension_frozen(turret: &Turret): bool {
    extension_freeze::is_extension_frozen(&turret.id)
}

public fun type_id(turret: &Turret): u64 {
    turret.type_id
}

/// Returns whether the target is an aggressor.
public fun is_aggressor(candidate: &TargetCandidate): bool {
    candidate.is_aggressor
}

public fun item_id(candidate: &TargetCandidate): u64 {
    candidate.item_id
}

/// Returns the target's type id (ship/NPC type).
public fun target_type_id(candidate: &TargetCandidate): u64 {
    candidate.type_id
}

public fun group_id(candidate: &TargetCandidate): u64 {
    candidate.group_id
}

public fun character_id(candidate: &TargetCandidate): u32 {
    candidate.character_id
}

public fun character_tribe(candidate: &TargetCandidate): u32 {
    candidate.character_tribe
}

public fun priority_weight(candidate: &TargetCandidate): u64 {
    candidate.priority_weight
}

public fun behaviour_change(candidate: &TargetCandidate): BehaviourChangeReason {
    candidate.behaviour_change
}

/// Returns the target item id from a ReturnTargetPriorityList entry.
public fun return_target_item_id(entry: &ReturnTargetPriorityList): u64 {
    entry.target_item_id
}

/// Returns the priority weight from a ReturnTargetPriorityList entry.
public fun return_priority_weight(entry: &ReturnTargetPriorityList): u64 {
    entry.priority_weight
}

/// Constructs a ReturnTargetPriorityList entry (for extensions and tests).
public fun new_return_target_priority_list(
    target_item_id: u64,
    priority_weight: u64,
): ReturnTargetPriorityList {
    ReturnTargetPriorityList { target_item_id, priority_weight }
}

/// Returns the turret ID from an OnlineReceipt.
public fun turret_id(receipt: &OnlineReceipt): ID {
    receipt.turret_id
}

// === Admin Functions ===
public fun anchor(
    registry: &mut ObjectRegistry,
    network_node: &mut NetworkNode,
    character: &Character,
    admin_acl: &AdminACL,
    item_id: u64,
    type_id: u64,
    location_hash: vector<u8>,
    ctx: &mut TxContext,
): Turret {
    assert!(type_id != 0, ETurretTypeIdEmpty);
    assert!(item_id != 0, ETurretItemIdEmpty);

    let turret_key = in_game_id::create_key(item_id, character.tenant());
    assert!(!registry.object_exists(turret_key), ETurretAlreadyExists);

    let turret_uid = derived_object::claim(registry.borrow_registry_id(), turret_key);
    let turret_id = object::uid_to_inner(&turret_uid);
    let network_node_id = object::id(network_node);

    // Create owner cap first with just the ID
    let owner_cap = access::create_owner_cap_by_id<Turret>(turret_id, admin_acl, ctx);
    let owner_cap_id = object::id(&owner_cap);

    let turret = Turret {
        id: turret_uid,
        key: turret_key,
        owner_cap_id,
        type_id,
        status: status::anchor(turret_id, turret_key),
        location: location::attach(location_hash),
        energy_source_id: option::some(network_node_id),
        metadata: std::option::some(
            metadata::create_metadata(
                turret_id,
                turret_key,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        extension: option::none(),
    };

    network_node.connect_assembly(turret_id);
    access::transfer_owner_cap(owner_cap, object::id_address(character));

    event::emit(TurretCreatedEvent {
        turret_id,
        turret_key,
        owner_cap_id,
        type_id,
    });
    turret
}

public fun share_turret(turret: Turret, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    transfer::share_object(turret);
}

public fun update_energy_source(
    turret: &mut Turret,
    network_node: &mut NetworkNode,
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    let turret_id = object::id(turret);
    let nwn_id = object::id(network_node);
    assert!(!turret.status.is_online(), ENotOnline);

    network_node.connect_assembly(turret_id);
    turret.energy_source_id = option::some(nwn_id);
}

public fun unanchor(
    turret: Turret,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    let Turret {
        mut id,
        key,
        status,
        location,
        metadata,
        energy_source_id,
        type_id,
        ..,
    } = turret;

    let nwn_id = object::id(network_node);
    assert!(option::contains(&energy_source_id, &nwn_id), ENetworkNodeMismatch);

    // Release energy if turret is online
    if (status.is_online()) {
        release_energy_by_type(network_node, energy_config, type_id);
    };

    // Disconnect turret from network node
    let turret_id = object::uid_to_inner(&id);
    network_node.disconnect_assembly(turret_id);
    status.unanchor(turret_id, key);

    // TODO: drop everything
    extension_freeze::remove_frozen_marker_if_present(&mut id);
    location.remove();
    metadata.do!(|metadata| metadata.delete());
    let _ = option::destroy_with_default(energy_source_id, nwn_id);
    id.delete();
}

public fun unanchor_orphan(turret: Turret, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    let Turret {
        mut id,
        key,
        status,
        location,
        metadata,
        energy_source_id,
        ..,
    } = turret;

    assert!(option::is_none(&energy_source_id), ETurretHasEnergySource);
    assert!(!status.is_online(), ENotOnline);

    let turret_id = object::uid_to_inner(&id);
    status.unanchor(turret_id, key);
    extension_freeze::remove_frozen_marker_if_present(&mut id);
    location.remove();
    metadata.do!(|metadata| metadata.delete());
    id.delete();
}

// === Package Functions ===

// === Private Functions ===
fun reserve_energy(turret: &Turret, network_node: &mut NetworkNode, energy_config: &EnergyConfig) {
    let network_node_id = object::id(network_node);
    network_node
        .borrow_energy_source()
        .reserve_energy(
            network_node_id,
            energy_config,
            turret.type_id,
        );
}

fun release_energy(turret: &Turret, network_node: &mut NetworkNode, energy_config: &EnergyConfig) {
    release_energy_by_type(network_node, energy_config, turret.type_id);
}

fun release_energy_by_type(
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    type_id: u64,
) {
    let network_node_id = object::id(network_node);
    network_node
        .borrow_energy_source()
        .release_energy(
            network_node_id,
            energy_config,
            type_id,
        );
}

fun peel_target_candidate_from_bcs(bcs_data: &mut bcs::BCS): TargetCandidate {
    let item_id = bcs_data.peel_u64();
    let type_id = bcs_data.peel_u64();
    let group_id = bcs_data.peel_u64();
    let character_id = bcs_data.peel_u32();
    let character_tribe = bcs_data.peel_u32();
    let hp_ratio = bcs_data.peel_u64();
    let shield_ratio = bcs_data.peel_u64();
    let armor_ratio = bcs_data.peel_u64();
    let is_aggressor = bcs_data.peel_bool();
    let priority_weight = bcs_data.peel_u64();
    let behaviour_change = peel_behaviour_change_reason(bcs_data.peel_u8());
    TargetCandidate {
        item_id,
        type_id,
        group_id,
        character_id,
        character_tribe,
        hp_ratio,
        shield_ratio,
        armor_ratio,
        is_aggressor,
        priority_weight,
        behaviour_change,
    }
}

fun peel_behaviour_change_reason(v: u8): BehaviourChangeReason {
    if (v == 0) { BehaviourChangeReason::UNSPECIFIED } else if (v == 1) {
        BehaviourChangeReason::ENTERED
    } else if (v == 2) { BehaviourChangeReason::STARTED_ATTACK } else if (v == 3) {
        BehaviourChangeReason::STOPPED_ATTACK
    } else { BehaviourChangeReason::UNSPECIFIED }
}

fun peel_return_target_priority_list_from_bcs(bcs_data: &mut bcs::BCS): ReturnTargetPriorityList {
    let target_item_id = bcs_data.peel_u64();
    let priority_weight = bcs_data.peel_u64();
    ReturnTargetPriorityList { target_item_id, priority_weight }
}

/// Default rules for turret to shoot:
/// - Owner (matching character_id): always exclude from the return list
/// - Same tribe as owner and not aggressor: exclude from the return list
/// - STOPPED_ATTACK (candidate's behaviour_change): exclude from the return list
/// - STARTED_ATTACK: add STARTED_ATTACK_WEIGHT_INCREMENT to priority weight
/// - ENTERED: add ENTERED_WEIGHT_INCREMENT to priority weight if not same tribe as owner or is aggressor
/// - UNSPECIFIED: no change to weight
fun effective_weight_and_excluded(
    candidate: &TargetCandidate,
    owner_character: &Character,
): (u64, bool) {
    let mut weight = candidate.priority_weight;
    let owner_character_id = owner_character.key().item_id() as u32;
    let is_owner = candidate.character_id != 0 && candidate.character_id == owner_character_id;
    let same_tribe = candidate.character_tribe == character::tribe(owner_character);
    let mut excluded = is_owner || (same_tribe && !candidate.is_aggressor);
    let reason = candidate.behaviour_change;
    if (reason == BehaviourChangeReason::STOPPED_ATTACK) {
        excluded = true;
    } else if (reason == BehaviourChangeReason::STARTED_ATTACK) {
        weight = weight + STARTED_ATTACK_WEIGHT_INCREMENT;
    } else if (reason == BehaviourChangeReason::ENTERED) {
        if (
            candidate.character_tribe != character::tribe(owner_character) || candidate.is_aggressor == true
        ) {
            weight = weight + ENTERED_WEIGHT_INCREMENT;
        }
    };
    (weight, excluded)
}

/// Builds the return list from the candidate list.
fun build_return_priority_list(
    candidates: &vector<TargetCandidate>,
    owner_character: &Character,
): vector<ReturnTargetPriorityList> {
    let mut result = vector::empty();
    let mut i = 0u64;
    let len = vector::length(candidates);
    while (i < len) {
        let target_candidate = vector::borrow(candidates, i);
        let (weight, excluded) = effective_weight_and_excluded(target_candidate, owner_character);
        // TODO: The game always send a non-duplicate target item id in the target candidate list
        if (!excluded) {
            vector::push_back(
                &mut result,
                ReturnTargetPriorityList {
                    target_item_id: target_candidate.item_id,
                    priority_weight: weight,
                },
            );
        };
        i = i + 1;
    };
    result
}

#[allow(unused_function)]
/// Checks if the return list contains the target item id.
fun return_list_contains_id(list: &vector<ReturnTargetPriorityList>, search_key: u64): bool {
    let mut i = 0u64;
    let len = vector::length(list);
    while (i < len) {
        let entry = vector::borrow(list, i);
        if (entry.target_item_id == search_key) {
            return true
        };
        i = i + 1;
    };
    false
}

// === Test Functions ===
#[test_only]
public fun destroy_online_receipt_test(receipt: OnlineReceipt) {
    let OnlineReceipt { .. } = receipt;
}

#[test_only]
public fun metadata(turret: &Turret): &Option<Metadata> {
    &turret.metadata
}
