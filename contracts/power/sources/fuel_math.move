/// Pure fuel math. No grid state: callers pass the numbers and get a number back.
/// Power, fuel and fuel stats are fixed point at `SCALE` (4 decimals).
module power::fuel_math;

// === Constants ===

const SCALE: u64 = 10_000;
const MS_PER_SECOND: u64 = 1_000;
/// Fuel factor bounds, matching the game client: [1, 100] at `SCALE`.
const MIN_FUEL_FACTOR: u64 = 10_000;
const MAX_FUEL_FACTOR: u64 = 1_000_000;

// === Public Functions ===

public fun scale(): u64 {
    SCALE
}

/// Fuel burned per second of load: `impulse / max(1, burden / containment_reduction)`,
/// clamped to [1, 100]. All values at `SCALE`.
public fun fuel_factor(impulse: u64, containment_burden: u64, containment_reduction: u64): u64 {
    let reduction = containment_reduction.max(SCALE) as u128;
    let burden_ratio = ((containment_burden as u128) * (SCALE as u128) / reduction).max(
        SCALE as u128,
    );
    let factor = (impulse as u128) * (SCALE as u128) / burden_ratio;
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

/// One online Generator's burn over `elapsed_ms`. Rounds up.
/// Zero impulse has no fuel factor, so the Generator burns its base rate instead.
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
        return divide_round_up((base_fuel_rate as u128) * elapsed_ms, MS_PER_SECOND as u128)
    };
    let share = load * (max_output_mw as u128) / (capacity_mw as u128);
    let factor = fuel_factor(impulse, containment_burden, containment_reduction);
    divide_round_up(
        share * (SCALE as u128) * elapsed_ms,
        (factor as u128) * (MS_PER_SECOND as u128),
    )
}

// === Private Functions ===

fun divide_round_up(numerator: u128, denominator: u128): u128 {
    (numerator + denominator - 1) / denominator
}
