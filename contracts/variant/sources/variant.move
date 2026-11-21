/// NeoType variants on chain.
///
/// A `Variant` holds one variant's property values. The game service registers it once
/// at an object derived from its `VariantKey`, and it is frozen at once: a variant's
/// values never change. Stacks and items store only the key; contracts read the values
/// by passing `&Variant`.
///
/// Registration follows the request pattern: `register` returns the record with an
/// admin-gated `Request` (issued via `request::new_for`); the transaction satisfies it,
/// then `complete_registration` freezes the record.
module variant::variant;

use core::{admin_service, request::{Self, Request}};
use std::{internal::Permit, string::String};
use sui::{derived_object, event, vec_map::{Self, VecMap}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Variant registry version does not match the package version";
#[error(code = 1)]
const ETenantEmpty: vector<u8> = b"Tenant must be non-empty";
#[error(code = 2)]
const ETypeIdZero: vector<u8> = b"Type ID must be non-zero";
#[error(code = 3)]
const EVariantAlreadyRegistered: vector<u8> = b"A variant with this key is already registered";
#[error(code = 4)]
const EZeroUnitVolume: vector<u8> = b"Unit volume must be non-zero";
#[error(code = 5)]
const EPropertyLengthMismatch: vector<u8> =
    b"Property IDs, magnitudes and signs must have the same length";
#[error(code = 6)]
const EPropertyIdsNotAscending: vector<u8> = b"Property IDs must be strictly ascending";
#[error(code = 7)]
const EValuesWithoutVariant: vector<u8> = b"A record with variant ID 0 holds no values";
#[error(code = 8)]
const ENegativeZero: vector<u8> = b"Zero must not be marked negative";
#[error(code = 9)]
const ENegativeValue: vector<u8> = b"Property value is negative";
#[error(code = 10)]
const EValueTooLarge: vector<u8> = b"Property value does not fit in u64";

// === Constants ===

const VERSION: u64 = 1;
/// Property values are fixed-point at 1e9 (the proto's nanos).
const VALUE_SCALE: u128 = 1_000_000_000;
const UNITS_DECIMALS: u8 = 0;
const MASS_DECIMALS: u8 = 9;

// === Structs ===

/// Issuer of registration requests.
public struct Register() has drop;

/// Identity of one variant. Stacks and items carry this, not the values.
public struct VariantKey has copy, drop, store {
    tenant: String,
    type_id: u64,
    variant_id: u64, // game variantID; 0 = no variant
}

/// How a type is counted. Display only: quantity arithmetic never branches on it.
public enum QuantityKind has copy, drop, store {
    Units, // base unit = 1 item
    Mass, // base unit = 1e-9 kg (the proto's nanos)
}

/// A signed property value.
public struct Value has copy, drop, store {
    magnitude: u128, // at 1e9: |units| × 1e9 + |nanos|
    negative: bool,
}

/// One variant's values. Frozen at registration; never changes, never deleted.
public struct Variant has key {
    id: UID, // derived from VariantRegistry + key
    key: VariantKey,
    // The `QuantityKind` as its decimals (0 or 9): freezing an object with an enum field
    // crashes the Move compiler (sui 1.78-1.83), so `kind()` derives the enum from this.
    decimals: u8,
    unit_volume: u64, // m³ per kg (Mass) or per item (Units), at 1e9
    values: VecMap<u32, Value>, // property_id -> value, ascending by id
}

/// Shared parent for derived `Variant` addresses.
public struct VariantRegistry has key {
    id: UID,
    version: u64,
}

// === Events ===

public struct VariantRegistered has copy, drop {
    key: VariantKey,
    id: ID,
    kind: QuantityKind,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(VariantRegistry { id: object::new(ctx), version: VERSION });
}

// === Public Functions ===

/// Build a variant key.
public fun new_key(tenant: String, type_id: u64, variant_id: u64): VariantKey {
    assert!(tenant.length() > 0, ETenantEmpty);
    assert!(type_id != 0, ETypeIdZero);
    VariantKey { tenant, type_id, variant_id }
}

/// Counted in whole items.
public fun units(): QuantityKind { QuantityKind::Units }

/// Counted by mass in 1e-9 kg.
public fun mass(): QuantityKind { QuantityKind::Mass }

// === View Functions ===

public fun key(variant: &Variant): VariantKey { variant.key }

/// How the variant's quantities are counted.
public fun kind(variant: &Variant): QuantityKind {
    if (variant.decimals == MASS_DECIMALS) QuantityKind::Mass else QuantityKind::Units
}

/// Display decimals of a quantity: 0 for `Units`, 9 for `Mass`.
public fun decimals(variant: &Variant): u8 { variant.decimals }

public fun unit_volume(variant: &Variant): u64 { variant.unit_volume }

public fun values(variant: &Variant): &VecMap<u32, Value> { &variant.values }

/// Display decimals of a quantity kind.
public fun kind_decimals(kind: QuantityKind): u8 {
    match (kind) {
        QuantityKind::Units => UNITS_DECIMALS,
        QuantityKind::Mass => MASS_DECIMALS,
    }
}

/// The value of `property_id`, if the variant has it.
public fun value(variant: &Variant, property_id: u32): Option<Value> {
    variant.values.try_get(&property_id)
}

/// The value of `property_id` at 1e9 as a `u64`; aborts if negative or too large.
public fun value_u64(variant: &Variant, property_id: u32): Option<u64> {
    variant.value(property_id).map!(|property_value| {
        assert!(!property_value.negative, ENegativeValue);
        assert!(property_value.magnitude <= (std::u64::max_value!() as u128), EValueTooLarge);
        property_value.magnitude as u64
    })
}

/// Property IDs, ascending.
public fun property_ids(variant: &Variant): vector<u32> { variant.values.keys() }

public fun tenant(key: &VariantKey): String { key.tenant }

public fun type_id(key: &VariantKey): u64 { key.type_id }

public fun variant_id(key: &VariantKey): u64 { key.variant_id }

public fun magnitude(property_value: &Value): u128 { property_value.magnitude }

public fun negative(property_value: &Value): bool { property_value.negative }

/// Fixed-point scale of property values (1e9).
public fun value_scale(): u128 { VALUE_SCALE }

public fun version(registry: &VariantRegistry): u64 { registry.version }

/// Whether a variant is registered under `key`.
public fun exists(registry: &VariantRegistry, key: VariantKey): bool {
    derived_object::exists(&registry.id, key)
}

/// The object ID a variant has, or will have, under `key`.
public fun derive_id(registry: &VariantRegistry, key: VariantKey): address {
    derived_object::derive_address(object::id(registry), key)
}

// === Admin Functions ===

/// Start registering a variant. Returns the record and an admin-gated `Request`: the
/// transaction must satisfy it (`admin_service::verify_admin`), then call
/// `complete_registration`. `property_ids` must be strictly ascending; `magnitudes` and
/// `negatives` line up with them. `unit_volume` is m³ per kg (`Mass`,
/// the service's 1 / density) or per item (`Units`), at 1e9.
public fun register(
    registry: &mut VariantRegistry,
    tenant: String,
    type_id: u64,
    variant_id: u64,
    kind: QuantityKind,
    unit_volume: u64,
    property_ids: vector<u32>,
    magnitudes: vector<u128>,
    negatives: vector<bool>,
): (Variant, Request) {
    assert!(registry.version == VERSION, EWrongVersion);
    let key = new_key(tenant, type_id, variant_id);
    assert!(!registry.exists(key), EVariantAlreadyRegistered);
    assert!(unit_volume > 0, EZeroUnitVolume);

    let count = property_ids.length();
    assert!(magnitudes.length() == count && negatives.length() == count, EPropertyLengthMismatch);
    assert!(variant_id != 0 || count == 0, EValuesWithoutVariant);
    1u64.range_do!(count, |i| {
        assert!(property_ids[i - 1] < property_ids[i], EPropertyIdsNotAscending);
    });

    let values = magnitudes.zip_map!(negatives, |magnitude, negative| {
        assert!(!negative || magnitude > 0, ENegativeZero);
        Value { magnitude, negative }
    });
    let values = vec_map::from_keys_values(property_ids, values);
    let variant = Variant {
        id: derived_object::claim(&mut registry.id, key),
        key,
        decimals: kind.kind_decimals(),
        unit_volume,
        values,
    };
    let request = request::new_for(register_permit(), vector[admin_service::admin_requirement()]);
    (variant, request)
}

/// Finish a registration once its request is satisfied: freeze the record.
public fun complete_registration(variant: Variant, request: Request) {
    request.complete_for(register_permit());
    event::emit(VariantRegistered {
        key: variant.key,
        id: variant.id.to_inner(),
        kind: variant.kind(),
    });
    transfer::freeze_object(variant);
}

// === Private Functions ===

/// Only this module defines `Register`, so only it can issue and complete registrations.
fun register_permit(): Permit<Register> {
    internal::permit<Register>()
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun registered_key(event: &VariantRegistered): VariantKey { event.key }

#[test_only]
public fun registered_id(event: &VariantRegistered): ID { event.id }

/// Register and freeze a variant without the admin check, for other packages'
/// tests. Returns the record's ID.
#[test_only]
public fun register_for_testing(
    registry: &mut VariantRegistry,
    tenant: String,
    type_id: u64,
    variant_id: u64,
    kind: QuantityKind,
    unit_volume: u64,
    property_ids: vector<u32>,
    magnitudes: vector<u128>,
    negatives: vector<bool>,
): ID {
    let (variant, request) = registry.register(
        tenant,
        type_id,
        variant_id,
        kind,
        unit_volume,
        property_ids,
        magnitudes,
        negatives,
    );
    request.destroy();
    let id = variant.id.to_inner();
    transfer::freeze_object(variant);
    id
}
