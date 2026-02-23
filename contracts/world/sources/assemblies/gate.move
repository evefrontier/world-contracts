/// This module handles the functionality of in-game Smart Gates.
///
/// A Gate is a structure in space that enables travel across space.
/// Gates function by linking to another gate, creating a transport link for travel.
/// To link 2 gates, they must be at least 20KM away from each other and owned by the same character.
/// Gates are programmable structures where the owner can define custom rules through extension contracts.
///
/// By default, gates allow anyone to jump without requiring a ticket or pass.
/// However, if the owner configures the gate with extension logic using the typed witness pattern,
/// the gate will require a valid ticket/pass to jump. The pass must be obtained from the external
/// logic programmed by the owner. When extension logic is configured, the `jump` function
/// validates the pass/ticket before allowing the jump.
///
/// Extension pattern: https://github.com/evefrontier/world-contracts/blob/main/docs/architechture.md#layer-3-player-extensions-moddability
module world::gate;

use std::{bcs, type_name::{Self, TypeName}};
use sui::{clock::Clock, derived_object, event, hash, table::{Self, Table}};
use world::{
    access::{Self, OwnerCap, ServerAddressRegistry, AdminACL},
    character::{Self, Character},
    energy::EnergyConfig,
    in_game_id::{Self, TenantItemId},
    location::{Self, Location},
    metadata::{Self, Metadata},
    network_node::{NetworkNode, OfflineAssemblies, HandleOrphanedAssemblies, UpdateEnergySources},
    object_registry::ObjectRegistry,
    status::{Self, AssemblyStatus}
};

// === Errors ===
#[error(code = 0)]
const EGateTypeIdEmpty: vector<u8> = b"Gate TypeId is empty";
#[error(code = 1)]
const EGateItemIdEmpty: vector<u8> = b"Gate ItemId is empty";
#[error(code = 2)]
const EGateAlreadyExists: vector<u8> = b"Gate with this ItemId already exists";
#[error(code = 3)]
const EGateNotAuthorized: vector<u8> = b"Gate access not authorized";
#[error(code = 4)]
const EExtensionNotAuthorized: vector<u8> =
    b"Access only authorized for the custom contract of the registered type";
#[error(code = 5)]
const ENotOnline: vector<u8> = b"Gate is not online";
#[error(code = 6)]
const ENetworkNodeMismatch: vector<u8> =
    b"Provided network node does not match the gate's configured energy source";
#[error(code = 7)]
const EGatesAlreadyLinked: vector<u8> = b"Gates are already linked";
#[error(code = 8)]
const EGatesNotLinked: vector<u8> = b"Gates are not linked";
#[error(code = 9)]
const EOutOfRange: vector<u8> = b"Invalid distance in location proof";
#[error(code = 10)]
const EJumpPermitExpired: vector<u8> = b"Jump permit has expired";
#[error(code = 11)]
const EInvalidJumpPermit: vector<u8> = b"Invalid jump permit";
#[error(code = 12)]
const EGateHasEnergySource: vector<u8> = b"Gate has an energy source";
#[error(code = 13)]
const EGateOnline: vector<u8> = b"Gate should be offline";
#[error(code = 14)]
const EGatesLinked: vector<u8> = b"Gates are linked";

// === Structs ===
public struct GateConfig has key {
    id: UID,
    max_distance_by_type: Table<u64, u64>,
}

public struct Gate has key {
    id: UID,
    key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    linked_gate_id: Option<ID>,
    status: AssemblyStatus,
    location: Location,
    energy_source_id: Option<ID>,
    metadata: Option<Metadata>,
    extension: Option<TypeName>,
}

// Note : Can add more fields later
public struct JumpPermit has key, store {
    id: UID,
    character_id: ID,
    // Hash that binds this permit to a (source, destination) gate pair.
    // Computed in a direction-agnostic way so the same permit works for A->B and B->A.
    route_hash: vector<u8>,
    expires_at_timestamp_ms: u64,
}

// === Events ===
public struct GateCreatedEvent has copy, drop {
    assembly_id: ID,
    assembly_key: TenantItemId,
    owner_cap_id: ID,
    type_id: u64,
    location_hash: vector<u8>,
    status: status::Status,
}

public struct GateLinkedEvent has copy, drop {
    source_gate_id: ID,
    source_gate_key: TenantItemId,
    destination_gate_id: ID,
    destination_gate_key: TenantItemId,
}

public struct GateUnlinkedEvent has copy, drop {
    source_gate_id: ID,
    source_gate_key: TenantItemId,
    destination_gate_id: ID,
    destination_gate_key: TenantItemId,
}

public struct JumpEvent has copy, drop {
    source_gate_id: ID,
    source_gate_key: TenantItemId,
    destination_gate_id: ID,
    destination_gate_key: TenantItemId,
    character_id: ID,
    character_key: TenantItemId,
}

// === Public Functions ===
public fun authorize_extension<Auth: drop>(gate: &mut Gate, owner_cap: &OwnerCap<Gate>) {
    let gate_id = object::id(gate);
    assert!(access::is_authorized(owner_cap, gate_id), EGateNotAuthorized);
    gate.extension.swap_or_fill(type_name::with_defining_ids<Auth>());
}

public fun online(
    gate: &mut Gate,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<Gate>,
) {
    let gate_id = object::id(gate);
    assert!(access::is_authorized(owner_cap, gate_id), EGateNotAuthorized);
    assert!(
        option::contains(&gate.energy_source_id, &object::id(network_node)),
        ENetworkNodeMismatch,
    );
    reserve_energy(gate, network_node, energy_config);

    gate.status.online(gate_id, gate.key);
}

public fun offline(
    gate: &mut Gate,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    owner_cap: &OwnerCap<Gate>,
) {
    let gate_id = object::id(gate);
    assert!(access::is_authorized(owner_cap, gate_id), EGateNotAuthorized);
    assert!(
        option::contains(&gate.energy_source_id, &object::id(network_node)),
        ENetworkNodeMismatch,
    );
    release_energy(gate, network_node, energy_config);

    gate.status.offline(gate_id, gate.key);
}

public fun link_gates(
    source_gate: &mut Gate,
    destination_gate: &mut Gate,
    gate_config: &GateConfig,
    server_registry: &ServerAddressRegistry,
    admin_acl: &AdminACL,
    source_gate_owner_cap: &OwnerCap<Gate>,
    destination_gate_owner_cap: &OwnerCap<Gate>,
    distance_proof: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // TODO: Remove admin_acl once a location service is exposed for signed server proofs.
    // Until then, this txn must be an authorized sponsored transaction.
    admin_acl.verify_sponsor(ctx);
    let source_gate_id = object::id(source_gate);
    let destination_gate_id = object::id(destination_gate);

    // Verify authorization
    assert!(access::is_authorized(source_gate_owner_cap, source_gate_id), EGateNotAuthorized);
    assert!(
        access::is_authorized(destination_gate_owner_cap, destination_gate_id),
        EGateNotAuthorized,
    );

    // Verify gates are not already linked
    assert!(
        option::is_none(&source_gate.linked_gate_id) && option::is_none(&destination_gate.linked_gate_id),
        EGatesAlreadyLinked,
    );

    // Verify distance using location proof
    verify_gates_within_range(
        source_gate,
        server_registry,
        gate_config,
        distance_proof,
        clock,
        ctx,
    );

    // Link the gates
    source_gate.linked_gate_id = option::some(destination_gate_id);
    destination_gate.linked_gate_id = option::some(source_gate_id);

    event::emit(GateLinkedEvent {
        source_gate_id,
        source_gate_key: source_gate.key,
        destination_gate_id,
        destination_gate_key: destination_gate.key,
    });
}

// TODO:  Should we allow this ?
public fun unlink_gates(
    source_gate: &mut Gate,
    destination_gate: &mut Gate,
    source_gate_owner_cap: &OwnerCap<Gate>,
    destination_gate_owner_cap: &OwnerCap<Gate>,
) {
    let source_gate_id = object::id(source_gate);
    let destination_gate_id = object::id(destination_gate);

    // Verify authorization
    assert!(access::is_authorized(source_gate_owner_cap, source_gate_id), EGateNotAuthorized);
    assert!(
        access::is_authorized(destination_gate_owner_cap, destination_gate_id),
        EGateNotAuthorized,
    );
    unlink(source_gate, destination_gate);
}

public fun issue_jump_permit<Auth: drop>(
    source_gate: &Gate,
    destination_gate: &Gate,
    character: &Character,
    _: Auth,
    expires_at_timestamp_ms: u64,
    ctx: &mut TxContext,
) {
    assert!(option::is_some(&destination_gate.extension), EExtensionNotAuthorized);
    assert!(option::is_some(&source_gate.extension), EExtensionNotAuthorized);

    let extension_type = option::borrow(&source_gate.extension);
    assert!(extension_type == &type_name::with_defining_ids<Auth>(), EExtensionNotAuthorized);
    // Require destination gate to be configured with the same extension witness type as well,
    // so the resulting permit is valid for jumping both directions between the two gates.
    // TODO: Should we make this optional ?
    let destination_extension_type = option::borrow(&destination_gate.extension);
    assert!(
        destination_extension_type == &type_name::with_defining_ids<Auth>(),
        EExtensionNotAuthorized,
    );

    let source_gate_id = object::id(source_gate);
    let destination_gate_id = object::id(destination_gate);

    // Bind the permit to the (source, destination) gate pair in a direction-agnostic way
    // so that the holder can jump both ways between the two linked gates.
    let route_hash = compute_route_hash(source_gate_id, destination_gate_id);

    let jump_permit = JumpPermit {
        id: object::new(ctx),
        route_hash,
        character_id: object::id(character),
        expires_at_timestamp_ms,
    };
    transfer::transfer(jump_permit, character.character_address());
}

/// Default jump from one gate to another (no permit required).
/// Only allowed when no extension logic is configured.
public fun jump(
    source_gate: &Gate,
    destination_gate: &Gate,
    character: &Character,
    admin_acl: &AdminACL,
    ctx: &mut TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    // Default jump is only allowed when no extension is configured
    assert!(option::is_none(&source_gate.extension), EExtensionNotAuthorized);
    jump_internal(source_gate, destination_gate, character);
}

/// Jump from one gate to another using a jump permit.
/// Requires extension logic to be configured and a valid Auth witness type from that extension.
public fun jump_with_permit(
    source_gate: &Gate,
    destination_gate: &Gate,
    character: &Character,
    jump_permit: JumpPermit,
    admin_acl: &AdminACL,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    validate_jump_permit(source_gate, destination_gate, character, jump_permit, clock);
    jump_internal(source_gate, destination_gate, character);
}

/// Updates the gate's energy source and removes it from the UpdateEnergySources hot potato.
/// Must be called for each gate in the hot potato returned by connect_assemblies.
public fun update_energy_source_connected_gate(
    gate: &mut Gate,
    mut update_energy_sources: UpdateEnergySources,
    network_node: &NetworkNode,
): UpdateEnergySources {
    if (update_energy_sources.update_energy_sources_ids_length() > 0) {
        let gate_id = object::id(gate);
        let found = update_energy_sources.remove_energy_sources_assembly_id(gate_id);
        if (found) {
            assert!(!gate.status.is_online(), ENotOnline);
            gate.energy_source_id = option::some(object::id(network_node));
        };
    };
    update_energy_sources
}

/// Brings a connected gate offline and removes it from the hot potato
public fun offline_connected_gate(
    gate: &mut Gate,
    mut offline_assemblies: OfflineAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): OfflineAssemblies {
    if (offline_assemblies.ids_length() > 0) {
        let gate_id = object::id(gate);

        let found = offline_assemblies.remove_assembly_id(gate_id);
        if (found) {
            if (gate.status.is_online()) {
                gate.status.offline(gate_id, gate.key);
                release_energy(gate, network_node, energy_config);
            };
        }
    };
    offline_assemblies
}

/// Brings a connected gate offline, releases energy, clears energy source, and removes it from the hot potato
/// Must be called for each gate in the hot potato returned by nwn.unanchor()
/// Returns the updated HandleOrphanedAssemblies; after all are processed, call destroy_network_node with it
public fun offline_orphaned_gate(
    gate: &mut Gate,
    mut orphaned_assemblies: HandleOrphanedAssemblies,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
): HandleOrphanedAssemblies {
    if (orphaned_assemblies.orphaned_assemblies_length() > 0) {
        let gate_id = object::id(gate);
        let found = orphaned_assemblies.remove_orphaned_assembly_id(gate_id);
        if (found) {
            // Bring gate offline and release energy if needed
            if (gate.status.is_online()) {
                gate.status.offline(gate_id, gate.key);
                release_energy(gate, network_node, energy_config);
            };

            gate.energy_source_id = option::none();
        }
    };
    orphaned_assemblies
}

// === View Functions ===
public fun status(gate: &Gate): &AssemblyStatus {
    &gate.status
}

public fun location(gate: &Gate): &Location {
    &gate.location
}

public fun is_online(gate: &Gate): bool {
    gate.status.is_online()
}

public fun are_gates_linked(gate_a: &Gate, gate_b: &Gate): bool {
    let gate_a_id = object::id(gate_a);
    let gate_b_id = object::id(gate_b);
    option::contains(&gate_a.linked_gate_id, &gate_b_id) &&
        option::contains(&gate_b.linked_gate_id, &gate_a_id)
}

public fun linked_gate_id(gate: &Gate): Option<ID> {
    gate.linked_gate_id
}

public fun owner_cap_id(gate: &Gate): ID {
    gate.owner_cap_id
}

/// Returns the gate's energy source (network node) ID if set
public fun energy_source_id(gate: &Gate): &Option<ID> {
    &gate.energy_source_id
}

/// Returns the configured extension type (if any)
public fun extension_type(gate: &Gate): &Option<TypeName> {
    &gate.extension
}

/// Returns true if the gate is configured with extension logic
public fun is_extension_configured(gate: &Gate): bool {
    option::is_some(&gate.extension)
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
): Gate {
    assert!(type_id != 0, EGateTypeIdEmpty);
    assert!(item_id != 0, EGateItemIdEmpty);

    let gate_key = in_game_id::create_key(item_id, character::tenant(character));
    assert!(!registry.object_exists(gate_key), EGateAlreadyExists);

    let gate_uid = derived_object::claim(registry.borrow_registry_id(), gate_key);
    let gate_id = object::uid_to_inner(&gate_uid);
    let network_node_id = object::id(network_node);

    // Create owner cap first with just the ID
    let owner_cap = access::create_owner_cap_by_id<Gate>(gate_id, admin_acl, ctx);
    let owner_cap_id = object::id(&owner_cap);

    let gate = Gate {
        id: gate_uid,
        key: gate_key,
        owner_cap_id,
        type_id,
        linked_gate_id: option::none(),
        status: status::anchor(gate_id, gate_key),
        location: location::attach(location_hash),
        energy_source_id: option::some(network_node_id),
        metadata: std::option::some(
            metadata::create_metadata(
                gate_id,
                gate_key,
                b"".to_string(),
                b"".to_string(),
                b"".to_string(),
            ),
        ),
        extension: option::none(),
    };

    network_node.connect_assembly(gate_id);
    access::transfer_owner_cap(owner_cap, object::id_address(character));

    event::emit(GateCreatedEvent {
        assembly_id: gate_id,
        assembly_key: gate_key,
        owner_cap_id,
        type_id: gate.type_id,
        location_hash: gate.location.hash(),
        status: status::status(&gate.status),
    });

    gate
}

public fun share_gate(gate: Gate, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    transfer::share_object(gate);
}

public fun update_energy_source(
    gate: &mut Gate,
    network_node: &mut NetworkNode,
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    let gate_id = object::id(gate);
    let nwn_id = object::id(network_node);
    assert!(!gate.status.is_online(), ENotOnline);

    network_node.connect_assembly(gate_id);
    gate.energy_source_id = option::some(nwn_id);
}

public fun unanchor(
    gate: Gate,
    network_node: &mut NetworkNode,
    energy_config: &EnergyConfig,
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    let Gate {
        id,
        key,
        status,
        location,
        metadata,
        energy_source_id,
        type_id,
        linked_gate_id,
        ..,
    } = gate;

    let nwn_id = object::id(network_node);
    assert!(option::contains(&energy_source_id, &nwn_id), ENetworkNodeMismatch);

    // Verify gate is not linked before unanchoring
    assert!(option::is_none(&linked_gate_id), EGatesLinked);

    // Release energy if gate is online
    if (status.is_online()) {
        release_energy_by_type(network_node, energy_config, type_id);
    };

    // Disconnect gate from network node
    let gate_id = object::uid_to_inner(&id);
    network_node.disconnect_assembly(gate_id);
    status.unanchor(gate_id, key);

    // TODO: drop everything
    location.remove();
    metadata.do!(|metadata| metadata.delete());
    let _ = option::destroy_with_default(energy_source_id, nwn_id);
    id.delete();
}

public fun unanchor_orphan(gate: Gate, admin_acl: &AdminACL, ctx: &TxContext) {
    admin_acl.verify_sponsor(ctx);
    let Gate {
        id,
        key,
        status,
        location,
        metadata,
        energy_source_id,
        linked_gate_id,
        ..,
    } = gate;

    assert!(option::is_none(&energy_source_id), EGateHasEnergySource);
    assert!(!status.is_online(), EGateOnline);
    // Verify gate is not linked before unanchoring
    assert!(option::is_none(&linked_gate_id), EGatesNotLinked);

    let gate_id = object::uid_to_inner(&id);
    status.unanchor(gate_id, key);
    location.remove();
    metadata.do!(|metadata| metadata.delete());
    id.delete();
}

public fun set_max_distance(
    gate_config: &mut GateConfig,
    admin_acl: &AdminACL,
    type_id: u64,
    max_distance: u64,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    assert!(type_id != 0, EGateTypeIdEmpty);
    assert!(max_distance > 0, EOutOfRange);

    if (gate_config.max_distance_by_type.contains(type_id)) {
        gate_config.max_distance_by_type.remove(type_id);
    };
    gate_config.max_distance_by_type.add(type_id, max_distance);
}

public fun unlink_gates_by_admin(
    source_gate: &mut Gate,
    destination_gate: &mut Gate,
    admin_acl: &AdminACL,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    unlink(source_gate, destination_gate);
}

// === Package Functions ===
public(package) fun max_distance(gate_config: &GateConfig, type_id: u64): u64 {
    assert!(type_id != 0, EGateTypeIdEmpty);
    if (gate_config.max_distance_by_type.contains(type_id)) {
        *gate_config.max_distance_by_type.borrow(type_id)
    } else {
        abort EGateTypeIdEmpty
    }
}

// === Private Functions ===
fun reserve_energy(gate: &Gate, network_node: &mut NetworkNode, energy_config: &EnergyConfig) {
    let network_node_id = object::id(network_node);
    network_node
        .borrow_energy_source()
        .reserve_energy(
            network_node_id,
            energy_config,
            gate.type_id,
        );
}

fun release_energy(gate: &Gate, network_node: &mut NetworkNode, energy_config: &EnergyConfig) {
    release_energy_by_type(network_node, energy_config, gate.type_id);
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

/// Verifies that two gates are within the maximum allowed distance using a location proof.
fun verify_gates_within_range(
    source_gate: &Gate,
    server_registry: &ServerAddressRegistry,
    gate_config: &GateConfig,
    distance_proof: vector<u8>,
    _clock: &Clock,
    ctx: &mut TxContext,
) {
    let max_distance = max_distance(gate_config, source_gate.type_id);

    source_gate
        .location
        .verify_distance(
            server_registry,
            distance_proof,
            max_distance,
            ctx,
        );
}

fun compute_route_hash(gate_a_id: ID, gate_b_id: ID): vector<u8> {
    let a_bytes = bcs::to_bytes(&gate_a_id);
    let b_bytes = bcs::to_bytes(&gate_b_id);
    let mut concatenated = a_bytes;
    vector::append(&mut concatenated, b_bytes);

    // Hash with Blake2b-256 (returns 32 bytes)
    hash::blake2b256(&concatenated)
}

fun jump_internal(source_gate: &Gate, destination_gate: &Gate, character: &Character) {
    let source_gate_id = object::id(source_gate);
    let destination_gate_id = object::id(destination_gate);

    // Verify both gates are online
    assert!(source_gate.status.is_online(), ENotOnline);
    assert!(destination_gate.status.is_online(), ENotOnline);

    // Verify gates are linked
    assert!(option::contains(&source_gate.linked_gate_id, &destination_gate_id), EGatesNotLinked);

    event::emit(JumpEvent {
        source_gate_id,
        source_gate_key: source_gate.key,
        destination_gate_id,
        destination_gate_key: destination_gate.key,
        character_id: object::id(character),
        character_key: character::key(character),
    });
}

fun validate_jump_permit(
    source_gate: &Gate,
    destination_gate: &Gate,
    character: &Character,
    jump_permit: JumpPermit,
    clock: &Clock,
) {
    let source_gate_id = object::id(source_gate);
    let destination_gate_id = object::id(destination_gate);

    // Validate jump permit then invalidate it
    assert!(jump_permit.expires_at_timestamp_ms > clock.timestamp_ms(), EJumpPermitExpired);
    assert!(jump_permit.character_id == object::id(character), EInvalidJumpPermit);
    assert!(
        jump_permit.route_hash == compute_route_hash(source_gate_id, destination_gate_id)
        || jump_permit.route_hash == compute_route_hash(destination_gate_id, source_gate_id),
        EInvalidJumpPermit,
    );

    // TODO: We can allow the permit to be used multiple times and make the invalidation action chosen by the builder extension logic later.
    // Invalidate the permit by deleting the object
    let JumpPermit { id, .. } = jump_permit;
    id.delete();
}

fun unlink(source_gate: &mut Gate, destination_gate: &mut Gate) {
    let source_gate_id = object::id(source_gate);
    let destination_gate_id = object::id(destination_gate);

    // Verify gates are linked
    assert!(
        option::contains(&source_gate.linked_gate_id, &destination_gate_id) &&
            option::contains(&destination_gate.linked_gate_id, &source_gate_id),
        EGatesNotLinked,
    );

    // Unlink the gates
    source_gate.linked_gate_id = option::none();
    destination_gate.linked_gate_id = option::none();

    event::emit(GateUnlinkedEvent {
        source_gate_id,
        source_gate_key: source_gate.key,
        destination_gate_id,
        destination_gate_key: destination_gate.key,
    });
}

// === Package Functions (Init) ===
fun init(ctx: &mut TxContext) {
    transfer::share_object(GateConfig {
        id: object::new(ctx),
        max_distance_by_type: table::new(ctx),
    });
}

// === Test Functions ===
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun test_jump(source_gate: &Gate, destination_gate: &Gate, character: &Character) {
    assert!(option::is_none(&source_gate.extension), EExtensionNotAuthorized);
    jump_internal(source_gate, destination_gate, character);
}

#[test_only]
public fun test_jump_with_permit(
    source_gate: &Gate,
    destination_gate: &Gate,
    character: &Character,
    jump_permit: JumpPermit,
    clock: &Clock,
) {
    validate_jump_permit(source_gate, destination_gate, character, jump_permit, clock);
    jump_internal(source_gate, destination_gate, character);
}
