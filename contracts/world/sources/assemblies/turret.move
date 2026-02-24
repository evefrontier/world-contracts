/// This module handles the functionality of in-game Smart Turrets.
///
/// A Turret is a programmable structure in space that projects offensive or defensive power over
/// a fixed location. Anchored to another owned Smart Assembly, it operates under builder-defined
/// rules enforced on chain for targeting priorities.
///
/// Builders control two key behaviours: InProximity (reacts to ships entering range) and
/// Aggression (responds to hostile actions when ships entering the range). A configurable on-chain priority queue
/// determines how targets are ranked and attacked. The owner can define custom logic through
/// extension contracts using the typed witness pattern to control the target priority queue.
module world::turret;

use std::type_name::{Self, TypeName};
use sui::{bcs, derived_object, event};
use world::{
    access::{Self, OwnerCap, AdminACL},
    character::Character,
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

/// Target for turret priority list. Uses character ID so the struct can be used in vectors.
public struct TurretTarget has copy, drop, store {
    target_id: ID,
    // target type either a ship or a NPC
    target_type_id: u64,
    // pilot character id, this is none for npcs
    target_character_id: ID,
    target_character_tribe: u32,
    // percentage of structure hit points remaining (0-100)
    hp_ratio: u64,
    // percentage of shield hit points remaining (0-100)
    shield_ratio: u64,
    // percentage of armor hit points remaining (0-100)
    armor_ratio: u64,
    // is this target attacking anyone on grid (structure or another player)
    is_agressor: bool,
    weight: u64,
}

/// Proof that a turret was online().
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
/// It applies the rules and decides weather the the new target should be added to the priority list or not.
/// `turret` - the programmable turret that is configured for defence or attack in game.
/// `owner_character` - the character that owns the turret
/// `priority_list` - is the list of targets (vector<TurretTarget>) that are currently in the priority list
/// `new_target` - is the new target`TurretTarget` that enters the proximity in-game
/// Returns the updated priority list(vector<TurretTarget>) as BCS vector<u8>.
public fun get_target_priority_list(
    turret: &Turret,
    owner_character: &Character,
    priority_list: vector<u8>,
    new_target: vector<u8>,
    receipt: OnlineReceipt,
): vector<u8> {
    // this is a additional check to ensure the receipt is valid and the turret is online
    assert!(receipt.turret_id() == object::id(turret), EInvalidOnlineReceipt);
    assert!(option::is_none(&turret.extension), EExtensionConfigured);

    let mut priority_list_vec = unpack_priority_list(priority_list);
    let new_target_decoded = peel_turret_target(new_target);

    apply_target_priority_rules(&mut priority_list_vec, owner_character, new_target_decoded);

    let result = bcs::to_bytes(&priority_list_vec);
    let OnlineReceipt { .. } = receipt;
    event::emit(PriorityListUpdatedEvent {
        turret_id: object::id(turret),
        priority_list: priority_list_vec,
    });
    result
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

/// Deserializes a TurretTarget from BCS bytes (field order: target_id, target_type_id,
/// target_character_id, target_character_tribe, hp_ratio, shield_ratio, armor_ratio, is_agressor, weight).
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
public fun is_agressor(target: &TurretTarget): bool {
    target.is_agressor
}

public fun target_id(target: &TurretTarget): ID {
    target.target_id
}

public fun target_type_id(target: &TurretTarget): u64 {
    target.target_type_id
}

public fun target_character_id(target: &TurretTarget): ID {
    target.target_character_id
}

public fun target_character_tribe(target: &TurretTarget): u32 {
    target.target_character_tribe
}

public fun weight(target: &TurretTarget): u64 {
    target.weight
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
    let target_id = object::id_from_address(bcs_data.peel_address());
    let target_type_id = bcs_data.peel_u64();
    let target_character_id = object::id_from_address(bcs_data.peel_address());
    let target_character_tribe = bcs_data.peel_u32();
    let hp_ratio = bcs_data.peel_u64();
    let shield_ratio = bcs_data.peel_u64();
    let armor_ratio = bcs_data.peel_u64();
    let is_agressor = bcs_data.peel_bool();
    let weight = bcs_data.peel_u64();
    TurretTarget {
        target_id,
        target_type_id,
        target_character_id,
        target_character_tribe,
        hp_ratio,
        shield_ratio,
        armor_ratio,
        is_agressor,
        weight,
    }
}

/// Default rules for the priority list.
/// If the new target is an aggressor, add it to the priority list.
/// If the new target is not an aggressor, add it to the priority list if it's not the same tribe as the owner character.
fun apply_target_priority_rules(
    priority_list: &mut vector<TurretTarget>,
    owner_character: &Character,
    new_target: TurretTarget,
) {
    if (new_target.is_agressor) {
        vector::push_back(priority_list, new_target);
    } else {
        if (new_target.target_character_tribe != owner_character.tribe()) {
            vector::push_back(priority_list, new_target);
        }
    };
}

// === Test Functions ===
#[test_only]
public fun destroy_online_receipt_test(receipt: OnlineReceipt) {
    let OnlineReceipt { .. } = receipt;
}
