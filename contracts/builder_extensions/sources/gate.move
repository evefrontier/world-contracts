#[allow(unused_use)]
module builder_extensions::gate;

use sui::clock::Clock;
use world::{
    character::Character,
    gate::{Self, Gate},
    storage_unit::{Self as storage_unit, StorageUnit}
};

// === Errors ===
#[error(code = 0)]
const ENotStarterTribe: vector<u8> = b"Character is not a starter tribe";

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
    let validity_period = clock.timestamp_ms() + 5 * 24 * 60 * 60 * 1000;
    gate::issue_jump_permit<XAuth>(
        source_gate,
        destination_gate,
        character,
        XAuth {},
        validity_period,
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
