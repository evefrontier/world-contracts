/// Example builder extension for `world::gate` using the typed-witness extension pattern.
///
/// This module demonstrates how builders/players can enforce custom jump rules by issuing a
/// `world::gate::JumpPermit` from extension logic:
/// - Gate owners configure a gate to use this extension by authorizing the witness type `XAuth`
///   on the gate (via `world::gate::authorize_extension<XAuth>`).
/// - Once configured, travelers must use `world::gate::jump_with_permit`; default `jump` is not allowed.
/// - This extension issues permits through `issue_jump_permit`, which:
///   - checks a simple rule (character must belong to the configured starter `tribe`)
///   - sets an expiry window (currently 5 days from `Clock`)
///   - calls `world::gate::issue_jump_permit<XAuth>` to mint a single-use permit to the character.
///
/// `GateRules` is a shared object holding configurable parameters,
#[allow(unused_use)]
module extension_examples::gate;

use sui::clock::Clock;
use world::{
    character::Character,
    gate::{Self, Gate},
    storage_unit::{Self as storage_unit, StorageUnit}
};

// === Errors ===
#[error(code = 0)]
const ENotStarterTribe: vector<u8> = b"Character is not a starter tribe";

// This can be any type that is authorized to call the `issue_jump_permit` function.
// eg: AlgorithimicWarfareAuth, TribalAuth, GoonCorpAuth, etc.
public struct XAuth has drop {}

// Can add more rules
public struct GateRules has key {
    id: UID,
    tribe: u32,
}

// TODO : Change this to OwnerCap of the gate ?
/// Admin capability for updating rules
public struct AdminCap has key, store {
    id: UID,
}

/// Builder extension example:
/// Issue a `JumpPermit` to only starter tribes
public fun issue_jump_permit(
    gate_rules: &GateRules,
    source_gate: &Gate,
    destination_gate: &Gate,
    character: &Character,
    _: &AdminCap,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Check if the character's tribe is a starter tribe
    assert!(character.tribe() == gate_rules.tribe, ENotStarterTribe);

    // 5 days in milliseconds.
    let expires_at_timestamp_ms = clock.timestamp_ms() + 5 * 24 * 60 * 60 * 1000;
    gate::issue_jump_permit<XAuth>(
        source_gate,
        destination_gate,
        character,
        XAuth {},
        expires_at_timestamp_ms,
        ctx,
    );
}

// === View Functions ===
public fun tribe(gate_rules: &GateRules): u32 {
    gate_rules.tribe
}

// === Admin Functions ===
public fun update_tribe_rules(gate_rules: &mut GateRules, _: &AdminCap, tribe: u32) {
    gate_rules.tribe = tribe;
}

// === Init ===
fun init(ctx: &mut TxContext) {
    let admin_cap = AdminCap { id: object::new(ctx) };
    transfer::transfer(admin_cap, ctx.sender());

    transfer::share_object(GateRules { id: object::new(ctx), tribe: 0 });
}
