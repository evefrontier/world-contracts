/// Pure fuel math. No grid state: callers pass the numbers and get a number back.
/// Power (MW), fuel quantity, stats, rates and burn are all fixed point at
/// `SCALE` (1e9: the proto's nanos), the same units as variant values and the
/// game service, so nothing is converted at the boundary.
module power::fuel_math;

// === Constants ===

const SCALE: u64 = 1_000_000_000;
const MS_PER_SECOND: u64 = 1_000;

// === Public Functions ===

public fun scale(): u64 {
    SCALE
}

public fun ms_per_second(): u64 {
    MS_PER_SECOND
}

// TODO: the stand-ins below are a sharp bend; swap for the smooth curve once
// its formula and precision are shared.
/// Usable impulse: the pool's impulse, capped at the Generator's impulse_limit. Fixed point at SCALE.
public fun usable_impulse(pool_impulse: u64, impulse_limit: u64): u64 {
    pool_impulse.min(impulse_limit)
}

/// Share of rated output the pool's volatility allows:
/// `min(volatility × SCALE ÷ volatility_limit, SCALE)`, at `SCALE`. Any
/// volatility above zero gives a share of at least 1, so the fuel still burns.
public fun volatility_share(pool_volatility: u64, volatility_limit: u64): u64 {
    let share = (pool_volatility as u128) * (SCALE as u128) / (volatility_limit as u128);
    let share = (share.min(SCALE as u128)) as u64;
    if (pool_volatility > 0) share.max(1) else share
}

/// MW a Generator sends out at `share`, both at `SCALE`: `max_output_mw × share ÷ SCALE`,
/// floored, but at least 1 (1e-9 MW) while both are above zero.
public fun generator_output(max_output_mw: u64, share: u64): u64 {
    let output = ((max_output_mw as u128) * (share as u128) / (SCALE as u128)) as u64;
    if (max_output_mw > 0 && share > 0) output.max(1) else output
}

// === Package Functions ===

/// Quantity-weighted average of the pool's stat and the stat just added.
public(package) fun blend(
    pooled_stat: u64,
    pooled_quantity: u64,
    added_stat: u64,
    added_quantity: u64,
): u64 {
    let total =
        (pooled_stat as u128) * (pooled_quantity as u128)
            + (added_stat as u128) * (added_quantity as u128);
    (total / ((pooled_quantity + added_quantity) as u128)) as u64
}

/// `blend`, rounded up: for a fuel's `unit_volume`, so a blend's volume is never
/// under-counted against a bay's capacity. Each blend may round up by 1, so many
/// small deposits into a large bay can leave it slightly above the exact average.
public(package) fun blend_up(
    pooled_stat: u64,
    pooled_quantity: u64,
    added_stat: u64,
    added_quantity: u64,
): u64 {
    let total =
        (pooled_stat as u128) * (pooled_quantity as u128)
            + (added_stat as u128) * (added_quantity as u128);
    total.div_ceil((pooled_quantity + added_quantity) as u128) as u64
}

/// Volume in nano-m³ of `quantity` (1e-9 kg) at `unit_volume` (m³ per kg at
/// `SCALE`, 1 / density), rounded up: `ceil(quantity × unit_volume ÷ SCALE)`.
public(package) fun volume(quantity: u64, unit_volume: u64): u128 {
    ((quantity as u128) * (unit_volume as u128)).div_ceil(SCALE as u128)
}

/// One online Generator's burn over `elapsed_ms`, at `SCALE`, rounded up:
/// its load (`load × output ÷ capacity_mw`) over `usable_impulse` (at `SCALE`).
/// The share stays in the numerator, so a load that does not split evenly
/// still burns. Capped at `u64::MAX`, so a sum over generators fits a u128.
public(package) fun generator_burn(
    usable_impulse: u64,
    capacity_mw: u64,
    output_mw: u64,
    load: u128,
    elapsed_ms: u128,
): u128 {
    // MW and fuel share `SCALE`; this one cancels the impulse's.
    let numerator = (load as u256) * (output_mw as u256) * (SCALE as u256) * (elapsed_ms as u256);
    let denominator = (capacity_mw as u256) * (usable_impulse as u256) * (MS_PER_SECOND as u256);
    let burn = (numerator + denominator - 1) / denominator;
    (burn.min(std::u64::max_value!() as u256)) as u128
}

// === Test Functions ===

/// 1 MW split across two equal generators at impulse 1: each burns 0.5 a second.
#[test]
fun half_share_burns_half_the_load() {
    assert!(generator_burn(SCALE, 2 * SCALE, SCALE, SCALE as u128, 1) == 500_000);
    assert!(generator_burn(SCALE, 2 * SCALE, SCALE, SCALE as u128, 1_000) == 500_000_000);
    assert!(generator_burn(SCALE, 2 * SCALE, SCALE, SCALE as u128, 3_000) == 1_500_000_000);
}

/// 10 MW at impulse 46.6666 burns 0.214286 a second; burden plays no part.
#[test]
fun scaled_impulse_burns() {
    assert!(
        generator_burn(46_666_600_000, 10 * SCALE, 10 * SCALE, 10 * (SCALE as u128), 1_000) == 214_286_021,
    );
}

/// A tiny impulse with a huge load caps at `u64::MAX`.
#[test]
fun burn_caps_at_u64_max() {
    let max = std::u64::max_value!();
    assert!(generator_burn(1, max, max, max as u128, 1_000_000) == max as u128);
}

/// The pool's impulse is used up to the Generator's limit.
#[test]
fun usable_impulse_caps_at_limit() {
    assert!(usable_impulse(25 * SCALE, 50 * SCALE) == 25 * SCALE);
    assert!(usable_impulse(90 * SCALE, 50 * SCALE) == 50 * SCALE);
}

/// Share scales with volatility up to the limit, then stays at `SCALE`.
#[test]
fun volatility_share_caps_at_scale() {
    assert!(volatility_share(SCALE / 2, SCALE) == SCALE / 2);
    assert!(volatility_share(SCALE, SCALE) == SCALE);
    assert!(volatility_share(3 * SCALE, SCALE) == SCALE);
    assert!(volatility_share(0, SCALE) == 0);
    assert!(volatility_share(1, 30 * SCALE) == 1);
}

/// Output is rated × share, floored, but at least 1 for any share.
#[test]
fun generator_output_floors() {
    assert!(generator_output(15 * SCALE, SCALE) == 15 * SCALE);
    assert!(generator_output(15 * SCALE, SCALE / 2) == 7_500_000_000);
    assert!(generator_output(15, SCALE / 2) == 7);
    assert!(generator_output(15 * SCALE, 1) == 15);
    assert!(generator_output(1, 1) == 1);
    assert!(generator_output(15 * SCALE, 0) == 0);
}

/// A fractional rating keeps its fraction.
#[test]
fun fractional_mw_output() {
    assert!(generator_output(2_500_000_000, SCALE) == 2_500_000_000);
    assert!(generator_output(500_000_000, SCALE / 2) == 250_000_000);
}
