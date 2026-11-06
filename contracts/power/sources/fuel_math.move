/// Pure fuel math. No grid state: callers pass the numbers and get a number back.
/// Power comes in as plain integers. Fuel quantity, stats, rates and burn are
/// fixed point at `SCALE` (4 decimals), so stats keep fractions and a short
/// settle still burns a fraction.
module power::fuel_math;

// === Constants ===

const SCALE: u64 = 10_000;
const MS_PER_SECOND: u64 = 1_000;

// === Public Functions ===

public fun scale(): u64 {
    SCALE
}

// TODO: the stand-ins below are a sharp bend; swap for the smooth curve once
// its formula and precision are shared.

/// Impulse a Generator can use from its pool: `min(pool impulse, impulse_limit)`, at `SCALE`.
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

/// Plain MW a Generator sends out at `share` (at `SCALE`): `max_output_mw × share ÷ SCALE`,
/// floored, but at least 1 MW while both are above zero.
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
    // One `SCALE` lifts plain MW to fuel units, the other cancels the impulse's.
    let numerator =
        (load as u256) * (output_mw as u256) * ((SCALE * SCALE) as u256) * (elapsed_ms as u256);
    let denominator = (capacity_mw as u256) * (usable_impulse as u256) * (MS_PER_SECOND as u256);
    let burn = (numerator + denominator - 1) / denominator;
    (burn.min(std::u64::max_value!() as u256)) as u128
}

// === Test Functions ===

/// 1 MW split across two equal generators at impulse 1: each burns 0.5 a second.
#[test]
fun half_share_burns_half_the_load() {
    assert!(generator_burn(10_000, 2, 1, 1, 1) == 5);
    assert!(generator_burn(10_000, 2, 1, 1, 1_000) == 5_000);
    assert!(generator_burn(10_000, 2, 1, 1, 3_000) == 15_000);
}

/// 10 MW at impulse 46.6666 burns 0.2143 a second; burden plays no part.
#[test]
fun scaled_impulse_burns() {
    assert!(generator_burn(466_666, 10, 10, 10, 1_000) == 2_143);
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
    assert!(usable_impulse(250_000, 500_000) == 250_000);
    assert!(usable_impulse(900_000, 500_000) == 500_000);
}

/// Share scales with volatility up to the limit, then stays at `SCALE`.
#[test]
fun volatility_share_caps_at_scale() {
    assert!(volatility_share(5_000, 10_000) == 5_000);
    assert!(volatility_share(10_000, 10_000) == 10_000);
    assert!(volatility_share(30_000, 10_000) == 10_000);
    assert!(volatility_share(0, 10_000) == 0);
    assert!(volatility_share(1, 30_000) == 1);
}

/// Output is rated × share, floored, but at least 1 MW for any share.
#[test]
fun generator_output_floors() {
    assert!(generator_output(15, 10_000) == 15);
    assert!(generator_output(15, 5_000) == 7);
    assert!(generator_output(15, 1) == 1);
    assert!(generator_output(15, 0) == 0);
}
