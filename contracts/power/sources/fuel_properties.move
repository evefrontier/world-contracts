/// Fuel values read from a NeoType `Variant`, converted to the grid's `SCALE`.
///
/// Variant values and mass quantities are at 1e9; the grid keeps fuel at `SCALE`
/// (1e4), so both divide by 10⁵. Property IDs are fixed in the game's static data.
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
const EFuelPropertyTooLarge: vector<u8> = b"Fuel property does not fit in u64 at SCALE";

// === Constants ===

const IMPULSE: u32 = 208;
const THERMAL_INEFFICIENCY: u32 = 209;
const CONTAINMENT_BURDEN: u32 = 210;
const VOLATILITY: u32 = 211;
/// 1e9 (variant values, mass) over 1e4 (`SCALE`).
const TO_SCALE: u64 = 100_000;

// === Public Functions ===

/// `(impulse, containment_burden, volatility, thermal_inefficiency)` at `SCALE`,
/// rounded down. Aborts unless the variant is counted by mass and has all four,
/// each non-negative and within `u64` at `SCALE`.
public fun from_variant(variant: &Variant): (u64, u64, u64, u64) {
    assert!(variant.kind() == variant::mass(), ENotMass);
    (
        read(variant, IMPULSE),
        read(variant, CONTAINMENT_BURDEN),
        read(variant, VOLATILITY),
        read(variant, THERMAL_INEFFICIENCY),
    )
}

/// A mass amount (base units, 1e-9 kg) at `SCALE`. Aborts unless it is a whole
/// number of 0.0001 kg, so no fuel is lost to rounding.
public fun amount_to_scale(amount: u64): u64 {
    assert!(amount % TO_SCALE == 0, EAmountNotWholeStep);
    amount / TO_SCALE
}

// === View Functions ===

public fun impulse_id(): u32 { IMPULSE }

public fun thermal_inefficiency_id(): u32 { THERMAL_INEFFICIENCY }

public fun containment_burden_id(): u32 { CONTAINMENT_BURDEN }

public fun volatility_id(): u32 { VOLATILITY }

/// Divisor from 1e9 to `SCALE`.
public fun to_scale(): u64 { TO_SCALE }

// === Private Functions ===

/// Scale before the range check, so values above `u64` at 1e9 still load.
fun read(variant: &Variant, property_id: u32): u64 {
    let value = variant.value(property_id).destroy_or!(abort EMissingFuelProperty);
    assert!(!value.negative(), ENegativeFuelProperty);
    let scaled = value.magnitude() / (TO_SCALE as u128);
    assert!(scaled <= (std::u64::max_value!() as u128), EFuelPropertyTooLarge);
    scaled as u64
}
