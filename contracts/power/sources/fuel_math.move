/// Pure fuel math. No grid state: callers pass the numbers and get a number back.
/// Power, fuel stats and rates come in as plain integers. Fuel quantity and burn
/// are fixed point at `SCALE` (4 decimals), so a short settle still burns a fraction.
module power::fuel_math;

// === Constants ===

const SCALE: u64 = 10_000;
const MS_PER_SECOND: u64 = 1_000;
/// Fuel factor bounds, matching the game client: [1, 100], held at `SCALE`.
const MIN_FUEL_FACTOR: u64 = 10_000;
const MAX_FUEL_FACTOR: u64 = 1_000_000;

// === Public Functions ===

public fun scale(): u64 {
    SCALE
}

/// Fuel burned per second of load: `impulse / max(1, burden / containment_reduction)`,
/// clamped to [1, 100]. Plain stats in, factor out at `SCALE`.
public fun fuel_factor(impulse: u64, containment_burden: u64, containment_reduction: u64): u64 {
    let scale = SCALE as u128;
    let reduction = containment_reduction.max(1) as u128;
    let burden_ratio = ((containment_burden as u128) * scale / reduction).max(scale);
    let factor = (impulse as u128) * scale * scale / burden_ratio;
    (factor.min(MAX_FUEL_FACTOR as u128) as u64).max(MIN_FUEL_FACTOR)
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

/// One online Generator's burn over `elapsed_ms`, at `SCALE`. Rounds up. Every
/// input is plain. Zero impulse has no fuel factor, so the Generator burns its
/// base rate instead.
public(package) fun generator_burn(
    impulse: u64,
    containment_burden: u64,
    capacity_mw: u64,
    max_output_mw: u64,
    containment_reduction: u64,
    base_fuel_rate: u64,
    load: u128,
    elapsed_ms: u128,
): u128 {
    if (impulse == 0) {
        return divide_round_up(
                (base_fuel_rate as u128) * (SCALE as u128) * elapsed_ms,
                MS_PER_SECOND as u128,
            )
    };
    let factor = fuel_factor(impulse, containment_burden, containment_reduction);
    // Share stays in the numerator. Dividing it off first drops a nonzero load
    // when that load does not split evenly across generators. One `SCALE` lifts
    // plain MW to fuel units, the other cancels the factor's.
    let numerator =
        (load as u256) * (max_output_mw as u256) * ((SCALE * SCALE) as u256)
            * (elapsed_ms as u256);
    let denominator = (capacity_mw as u256) * (factor as u256) * (MS_PER_SECOND as u256);
    (((numerator + denominator - 1) / denominator) as u128)
}

/// Fuel modules' burn over `elapsed_ms` at a combined `rate` per second, both at
/// `SCALE`. Rounds up.
public(package) fun rate_burn(rate: u64, elapsed_ms: u128): u128 {
    divide_round_up((rate as u128) * elapsed_ms, MS_PER_SECOND as u128)
}

// === Private Functions ===

fun divide_round_up(numerator: u128, denominator: u128): u128 {
    (numerator + denominator - 1) / denominator
}

// === Test Functions ===

/// 1 MW split across two equal generators at fuel factor 1: each burns 0.5 a second.
#[test]
fun half_share_burns_half_the_load() {
    let one_ms = generator_burn(1, 1, 2, 1, 1, 0, 1, 1);
    let one_second = generator_burn(1, 1, 2, 1, 1, 0, 1, 1_000);
    let three_seconds = generator_burn(1, 1, 2, 1, 1, 0, 1, 3_000);
    assert!(one_ms == 5);
    assert!(one_second == 5_000);
    assert!(three_seconds == 15_000);
}

/// 10 MW at impulse 46, burden 7, reduction 10 (factor 46) burns 0.2174 a second.
#[test]
fun plain_stats_burn() {
    let one_second = generator_burn(46, 7, 10, 10, 10, 0, 10, 1_000);
    assert!(one_second == 2_174);
}

/// Zero impulse burns the base rate: 2 units a second is 20_000 at `SCALE`.
#[test]
fun zero_impulse_burns_base_rate() {
    assert!(generator_burn(0, 0, 10, 10, 10, 2, 10, 1_000) == 20_000);
    assert!(generator_burn(0, 0, 10, 10, 10, 2, 10, 1) == 20);
}
