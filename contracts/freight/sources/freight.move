/// Additive freight receipt for cross-entity inventory delivery.
///
/// v1 inventory withdraws create transferable `Item`s with no `parent_id`. This
/// package binds one exact withdrawn `Item` to a source, destination, tenant,
/// and carrier so a later deposit can prove the haul was authorized — without
/// changing `core` or `inventory`.
///
/// Typical action composition:
/// - pickup: proximity (injected) → caller → inventory withdraw → freight pickup
/// - dropoff: proximity (injected) → caller → freight dropoff → inventory deposit
///
/// Current entity proximity is hash equality only (`location_service` TODO for
/// signed proofs). This receipt is the freight-layer authorization; it does not
/// claim cryptographic anti-teleport locality by itself.
module freight::freight;

use core::{entity::Entity, request::Request, requirement::{Self, Requirement}};
use inventory::item::Item;
use std::{internal::Permit, string::String};
use sui::{bcs, event};

// === Errors ===

#[error(code = 0)]
const EWrongEntity: vector<u8> = b"Request does not target this entity";
#[error(code = 1)]
const ENotAuthorized: vector<u8> = b"No caller recorded; action must carry a caller requirement";
#[error(code = 2)]
const EWrongDestination: vector<u8> = b"Freight receipt destination does not match this entity";
#[error(code = 3)]
const EWrongCarrier: vector<u8> = b"Freight receipt carrier does not match the authorized caller";
#[error(code = 4)]
const ETenantMismatch: vector<u8> = b"Freight cannot cross tenants";
#[error(code = 5)]
const EItemMismatch: vector<u8> = b"Item object id does not match the freight receipt";
#[error(code = 6)]
const ETypeMismatch: vector<u8> = b"Item type does not match the freight receipt";
#[error(code = 7)]
const EQuantityMismatch: vector<u8> = b"Item quantity does not match the freight receipt";

// === Structs ===

/// Pickup requirement config: the owner-approved destination entity id.
public struct Pickup has drop {
    destination: ID,
}

/// Dropoff requirement marker: validate and consume a `FreightReceipt`.
public struct Dropoff() has drop;

/// Consumable authorization for one exact Item haul from source to destination.
/// Transferable so the carrier can hold it between pickup and dropoff txs.
public struct FreightReceipt has key, store {
    id: UID,
    source: ID,
    destination: ID,
    carrier: ID,
    source_tenant: String,
    item_id: ID,
    type_id: u64,
    quantity: u64,
}

// === Events ===

public struct FreightPickedUp has copy, drop {
    receipt_id: ID,
    source: ID,
    destination: ID,
    carrier: ID,
    item_id: ID,
    type_id: u64,
    quantity: u64,
}

public struct FreightDelivered has copy, drop {
    receipt_id: ID,
    source: ID,
    destination: ID,
    carrier: ID,
    item_id: ID,
    type_id: u64,
    quantity: u64,
}

// === Public Functions ===

/// Build a pickup requirement that authorizes delivery to `destination`.
public fun pickup_requirement(destination: ID): Requirement {
    requirement::from_config(option::none(), Pickup { destination })
}

/// Build a dropoff requirement that consumes a matching `FreightReceipt`.
public fun dropoff_requirement(): Requirement {
    requirement::from_config(option::none(), Dropoff())
}

/// Issue a receipt binding `item` to this source entity and the destination
/// configured on the pickup requirement. Requires a prior caller requirement so
/// `request.authorized_id()` records the carrier.
///
/// Call after `inventory::withdraw` in the same request so the withdrawn Item is
/// the one bound into the receipt.
public fun pickup(
    entity: &Entity,
    request: &mut Request,
    item: &Item,
    ctx: &mut TxContext,
): FreightReceipt {
    let (requirement, frame) = request.take_next(pickup_permit());
    let destination = peel_destination(&requirement);
    frame.destroy_empty_frame();

    assert!(request.entity_id() == option::some(entity.id()), EWrongEntity);
    let carrier = request.authorized_id().destroy_or!(abort ENotAuthorized);

    let item_id = object::id(item);
    let type_id = item.type_id();
    let quantity = item.quantity();
    let source = entity.id();
    let receipt = FreightReceipt {
        id: object::new(ctx),
        source,
        destination,
        carrier,
        source_tenant: entity.key().tenant(),
        item_id,
        type_id,
        quantity,
    };
    let receipt_id = object::id(&receipt);
    event::emit(FreightPickedUp {
        receipt_id,
        source,
        destination,
        carrier,
        item_id,
        type_id,
        quantity,
    });
    receipt
}

/// Validate `receipt` against this destination entity, the authorized carrier,
/// and the exact `item`, then consume the receipt. Call before
/// `inventory::deposit` in the same request.
public fun dropoff(entity: &Entity, request: &mut Request, item: &Item, receipt: FreightReceipt) {
    let (_requirement, frame) = request.take_next(dropoff_permit());
    frame.destroy_empty_frame();

    assert!(request.entity_id() == option::some(entity.id()), EWrongEntity);
    assert!(entity.id() == receipt.destination, EWrongDestination);

    let carrier = request.authorized_id().destroy_or!(abort ENotAuthorized);
    assert!(carrier == receipt.carrier, EWrongCarrier);
    assert!(entity.key().tenant() == receipt.source_tenant, ETenantMismatch);
    assert!(object::id(item) == receipt.item_id, EItemMismatch);
    assert!(item.type_id() == receipt.type_id, ETypeMismatch);
    assert!(item.quantity() == receipt.quantity, EQuantityMismatch);

    let FreightReceipt {
        id,
        source,
        destination,
        carrier: receipt_carrier,
        source_tenant: _,
        item_id,
        type_id,
        quantity,
    } = receipt;
    let receipt_id = id.to_inner();
    event::emit(FreightDelivered {
        receipt_id,
        source,
        destination,
        carrier: receipt_carrier,
        item_id,
        type_id,
        quantity,
    });
    id.delete();
}

// === View Functions ===

public fun source(receipt: &FreightReceipt): ID {
    receipt.source
}

public fun destination(receipt: &FreightReceipt): ID {
    receipt.destination
}

public fun carrier(receipt: &FreightReceipt): ID {
    receipt.carrier
}

public fun source_tenant(receipt: &FreightReceipt): String {
    receipt.source_tenant
}

public fun item_id(receipt: &FreightReceipt): ID {
    receipt.item_id
}

public fun type_id(receipt: &FreightReceipt): u64 {
    receipt.type_id
}

public fun quantity(receipt: &FreightReceipt): u64 {
    receipt.quantity
}

// === Private Functions ===

/// Decode the destination id from a pickup requirement's BCS config.
fun peel_destination(requirement: &Requirement): ID {
    let mut b = bcs::new(requirement.data());
    object::id_from_address(b.peel_address())
}

fun pickup_permit(): Permit<Pickup> {
    internal::permit<Pickup>()
}

fun dropoff_permit(): Permit<Dropoff> {
    internal::permit<Dropoff>()
}
