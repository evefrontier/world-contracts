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

use std::type_name::{Self, TypeName};
use sui::{bcs, derived_object, event};
use world::{
    access::{Self, OwnerCap, AdminACL},
    character::{Self, Character},
    energy::EnergyConfig,
    in_game_id::{Self, TenantItemId},
    location::{Self, Location},
    metadata::Metadata,
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

// === Enums ===
public enum AffectedTargetChangeType has copy, drop, store {
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
public struct TurretTarget has copy, drop, store {
    item_id: u64, // TODO: is the item id enough or should we add the object id?
    // target type either a ship or a NPC
    type_id: u64,
    // target group id, this is none for npcs, This can help the turret to prioritize the targets
    // as the turret can be specialized against a specific group of ships <todo: doc link>
    group_id: u64,
    // pilot character id, this is none for npcs
    character_id: u32,
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
}

/// Affected target information struct
public struct AffectedTarget has copy, drop, store {
    target_item_id: u64,
    change_type: AffectedTargetChangeType,
}

/// Return Target info struct
/// Game starts shooting the target with the highest priority weight in the list,
/// If it has the same priority weight, it will shoot the first one in the list.
public struct ReturnTargetPriorityList has copy, drop, store {
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
    priority_list: vector<TurretTarget>,
}

// === Public Functions ===
public fun authorize_extension<Auth: drop>(turret: &mut Turret, owner_cap: &OwnerCap<Turret>) {
    let turret_id = object::id(turret);
    assert!(access::is_authorized(owner_cap, turret_id), ETurretNotAuthorized);
    turret.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
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
/// A function that is invoked by the game when a new target enters the proximity of the turret.
/// It applies the rules and decides whether the new target should be added to the priority list or not.
/// This function is called by the game whenever there is a change in the target in proximity of the turret.
/// `turret` - the programmable turret that is configured for defence or attack in game.
/// `owner_character` - the character that owns the turret
/// `priority_list` - is the list of targets (vector<TurretTarget>) in proximity ordered by priority, index 0 being the lowest priority
/// `affected_targets` - is the list of target ids(vector<AffectedTarget>) that have changed its behaviour in the TurretTarget list
/// Either entered in proximity or started attacking or stopped attacking. Many targets can be affected at the same time.
/// Returns a priority_list(vector<ReturnTargetPriorityList>) that contains the target ids and their priority weights.
/// The game receives the priority list and starts shooting the target with the highest priority weight,
/// If it has the same priority weight, it will shoot the first one in the list in the order of the list.
public fun get_target_priority_list(
    turret: &Turret,
    owner_character: &Character,
    priority_list: vector<u8>,
    affected_targets: vector<u8>,
    receipt: OnlineReceipt,
): vector<u8> {
    // this is an additional check to ensure the receipt is valid and the turret is online
    assert!(receipt.turret_id() == object::id(turret), EInvalidOnlineReceipt);
    assert!(option::is_none(&turret.extension), EExtensionConfigured);

    let priority_list_vec = unpack_priority_list(priority_list);
    let affected = unpack_affected_targets(affected_targets);

    let return_list = build_return_priority_list(&priority_list_vec, owner_character, &affected);
    let OnlineReceipt { .. } = receipt;
    event::emit(PriorityListUpdatedEvent {
        turret_id: object::id(turret),
        priority_list: priority_list_vec,
    });
    bcs::to_bytes(&return_list)
}

public fun destroy_online_receipt<Auth: drop>(receipt: OnlineReceipt, _: Auth) {
    let OnlineReceipt { .. } = receipt;
}

/// Deserializes vector<TurretTarget> from BCS bytes.
public fun unpack_priority_list(priority_list_bytes: vector<u8>): vector<TurretTarget> {
    if (vector::length(&priority_list_bytes) == 0) {
        return vector::empty()
    };
    let mut bcs_data = bcs::new(priority_list_bytes);
    bcs_data.peel_vec!(|bcs| peel_turret_target_from_bcs(bcs))
}

/// Deserializes vector<AffectedTarget> from BCS bytes.
public fun unpack_affected_targets(affected_targets_bytes: vector<u8>): vector<AffectedTarget> {
    if (vector::length(&affected_targets_bytes) == 0) {
        return vector::empty()
    };
    let mut bcs_data = bcs::new(affected_targets_bytes);
    bcs_data.peel_vec!(|bcs| peel_affected_target_from_bcs(bcs))
}

/// Deserializes vector<ReturnTargetPriorityList> from BCS bytes.
public fun unpack_return_priority_list(return_bytes: vector<u8>): vector<ReturnTargetPriorityList> {
    if (vector::length(&return_bytes) == 0) {
        return vector::empty()
    };
    let mut bcs_data = bcs::new(return_bytes);
    bcs_data.peel_vec!(|bcs| peel_return_target_priority_list_from_bcs(bcs))
}

/// Deserializes a TurretTarget from BCS bytes (field order: item_id, type_id, group_id,
/// character_id, character_tribe, hp_ratio, shield_ratio, armor_ratio, is_aggressor, priority_weight).
public fun peel_turret_target(target_bytes: vector<u8>): TurretTarget {
    let mut bcs_data = bcs::new(target_bytes);
    peel_turret_target_from_bcs(&mut bcs_data)
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

public fun type_id(turret: &Turret): u64 {
    turret.type_id
}

/// Returns whether the target is an aggressor.
public fun is_aggressor(target: &TurretTarget): bool {
    target.is_aggressor
}

public fun item_id(target: &TurretTarget): u64 {
    target.item_id
}

/// Returns the target's type id (ship/NPC type).
public fun target_type_id(target: &TurretTarget): u64 {
    target.type_id
}

public fun group_id(target: &TurretTarget): u64 {
    target.group_id
}

public fun character_id(target: &TurretTarget): u32 {
    target.character_id
}

public fun character_tribe(target: &TurretTarget): u32 {
    target.character_tribe
}

public fun priority_weight(target: &TurretTarget): u64 {
    target.priority_weight
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
        metadata: option::none(),
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
        id,
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
    location.remove();
    metadata.do!(|metadata| metadata.delete());
    let _ = option::destroy_with_default(energy_source_id, nwn_id);
    id.delete();
}

public fun unanchor_orphan(turret: Turret, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    let Turret {
        id,
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

fun peel_turret_target_from_bcs(bcs_data: &mut bcs::BCS): TurretTarget {
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
    TurretTarget {
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
    }
}

fun peel_affected_target_from_bcs(bcs_data: &mut bcs::BCS): AffectedTarget {
    let target_item_id = bcs_data.peel_u64();
    let change_type = peel_affected_target_change_type(bcs_data.peel_u8());
    AffectedTarget { target_item_id, change_type }
}

fun peel_affected_target_change_type(v: u8): AffectedTargetChangeType {
    if (v == 0) { AffectedTargetChangeType::UNSPECIFIED } else if (v == 1) {
        AffectedTargetChangeType::ENTERED
    } else if (v == 2) { AffectedTargetChangeType::STARTED_ATTACK } else if (v == 3) {
        AffectedTargetChangeType::STOPPED_ATTACK
    } else { AffectedTargetChangeType::UNSPECIFIED }
}

fun peel_return_target_priority_list_from_bcs(bcs_data: &mut bcs::BCS): ReturnTargetPriorityList {
    let target_item_id = bcs_data.peel_u64();
    let priority_weight = bcs_data.peel_u64();
    ReturnTargetPriorityList { target_item_id, priority_weight }
}

/// Default rules for turret to shoot:
/// - Same tribe as owner and not aggressor: exclude from the return list
/// - STOPPED_ATTACK (in affected): exclude from the return list
/// - STARTED_ATTACK (in affected): add 10000 to priority weight
/// - ENTERED (in affected): add 1000 to priority weight if not same tribe as owner or is aggressor
/// - UNSPECIFIED: no change to weight
fun effective_weight_and_excluded(
    target: &TurretTarget,
    owner_character: &Character,
    affected: &vector<AffectedTarget>,
): (u64, bool) {
    let mut weight = target.priority_weight;
    let same_tribe = target.character_tribe == character::tribe(owner_character);
    let mut excluded = same_tribe && !target.is_aggressor;
    let mut j = 0u64;
    let aff_len = vector::length(affected);
    while (j < aff_len) {
        let affected_target = vector::borrow(affected, j);
        if (affected_target.target_item_id == target.item_id) {
            if (affected_target.change_type == AffectedTargetChangeType::STOPPED_ATTACK) {
                excluded = true;
            } else if (affected_target.change_type == AffectedTargetChangeType::STARTED_ATTACK) {
                weight = weight + 10000;
            } else if (affected_target.change_type == AffectedTargetChangeType::ENTERED) {
                if (
                    target.character_tribe != character::tribe(owner_character) || target.is_aggressor == true
                ) {
                    weight = weight + 1000;
                }
            }
        };
        j = j + 1;
    };
    (weight, excluded)
}

/// Builds the return list from the priority_list
fun build_return_priority_list(
    priority_list: &vector<TurretTarget>,
    owner_character: &Character,
    affected: &vector<AffectedTarget>,
): vector<ReturnTargetPriorityList> {
    let mut result = vector::empty();
    let mut i = 0u64;
    let len = vector::length(priority_list);
    while (i < len) {
        let t = vector::borrow(priority_list, i);
        let (weight, excluded) = effective_weight_and_excluded(t, owner_character, affected);
        if (!excluded && !return_list_contains_id(&result, t.item_id)) {
            vector::push_back(
                &mut result,
                ReturnTargetPriorityList {
                    target_item_id: t.item_id,
                    priority_weight: weight,
                },
            );
        };
        i = i + 1;
    };
    result
}

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
