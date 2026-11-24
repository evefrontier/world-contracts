/// Fuel values read from a NeoType `Variant`.
///
/// Variant values, mass quantities and the grid's `SCALE` are all 1e9, so values
/// load as they are. Property IDs are fixed in the game's static data.
module power::fuel_properties;

use variant::variant::{Self, Variant};

// === Errors ===

#[error(code = 0)]
const EMissingFuelProperty: vector<u8> = b"Variant lacks a fuel property";
#[error(code = 1)]
const ENotMass: vector<u8> = b"Fuel must be counted by mass";
#[error(code = 2)]
const EAmountNotWholeStep: vector<u8> = b"Fuel amount must be a whole multiple of 0.0001 kg";
#[error(code = 3)]
const ENegativeFuelProperty: vector<u8> = b"Fuel property is negative";
#[error(code = 4)]
const EFuelPropertyTooLarge: vector<u8> = b"Fuel property does not fit in u64";
#[error(code = 5)]
const EBelowMinimum: vector<u8> = b"Siphoned fuel must be at least 0.01 kg";

// === Constants ===

const IMPULSE: u32 = 208;
const THERMAL_INEFFICIENCY: u32 = 209;
const CONTAINMENT_BURDEN: u32 = 210;
const VOLATILITY: u32 = 211;
/// 0.0001 kg (the game's precision) in base units.
const MASS_STEP: u64 = 100_000;
/// 0.01 kg, the game's smallest stack (`CONTINUOUS_MIN_SPLIT`), in base units.
const MIN_STACK: u64 = 10_000_000;

// === Public Functions ===

/// `(impulse, containment_burden, volatility, thermal_inefficiency)` at `SCALE`
/// (1e9). Aborts unless the variant is counted by mass and has all four, each
/// non-negative and within `u64`.
public fun from_variant(variant: &Variant): (u64, u64, u64, u64) {
    assert!(variant.kind() == variant::mass(), ENotMass);
    (
        read(variant, IMPULSE),
        read(variant, CONTAINMENT_BURDEN),
        read(variant, VOLATILITY),
        read(variant, THERMAL_INEFFICIENCY),
    )
}

/// Abort unless `amount` (base units, 1e-9 kg) is a whole number of 0.0001 kg,
/// the game's precision, so fuel the game sends or gets back never needs rounding.
public fun assert_whole_step(amount: u64) {
    assert!(amount % MASS_STEP == 0, EAmountNotWholeStep);
}

/// Abort unless `amount` is at least 0.01 kg, so fuel taken out of a bay can
/// become a stack the game (and inventory) accepts.
public fun assert_min_stack(amount: u64) {
    assert!(amount >= MIN_STACK, EBelowMinimum);
}

// === View Functions ===

public fun impulse_id(): u32 { IMPULSE }

public fun thermal_inefficiency_id(): u32 { THERMAL_INEFFICIENCY }

public fun containment_burden_id(): u32 { CONTAINMENT_BURDEN }

public fun volatility_id(): u32 { VOLATILITY }

/// 0.0001 kg in base units: fuel amounts are whole multiples of it.
public fun mass_step(): u64 { MASS_STEP }

/// 0.01 kg in base units: the smallest siphon.
public fun min_stack(): u64 { MIN_STACK }

// === Private Functions ===

fun read(variant: &Variant, property_id: u32): u64 {
    let value = variant.value(property_id).destroy_or!(abort EMissingFuelProperty);
    assert!(!value.negative(), ENegativeFuelProperty);
    let magnitude = value.magnitude();
    assert!(magnitude <= (std::u64::max_value!() as u128), EFuelPropertyTooLarge);
    magnitude as u64
}
