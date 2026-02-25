/// Extension contract for custom turret targeting behaviour.
///
/// This module lets builders change how a turret decides whether to attack a target. The game calls
/// `get_target_priority_list` with the current priority list, a new target, and an
/// `OnlineReceipt`. You can add rules based on these inputs—e.g. target type, tribe, hp/shield/armor
/// ratios, aggressor flag—to filter or reorder targets (attack or ignore).
///
/// The caller receives an `OnlineReceipt` from the world to prove the turret is online; the receipt
/// is a hot potato and must be consumed. Before returning, the extension must call
/// `turret::destroy_online_receipt(receipt, auth_witness)` from the world so the receipt is
/// destroyed and the call is valid.
module extension_examples::turret;

use sui::{bcs, event};
use world::{character::Character, turret::{Self, Turret, OnlineReceipt}};

#[error(code = 0)]
const EInvalidOnlineReceipt: u64 = 0;

public struct PriorityListUpdatedEvent has copy, drop {
    turret_id: ID,
    priority_list: vector<u8>,
}

public struct TurretAuth has drop {}

// More details to make the decisions 
// The below are the groupIDs for the different ship types and the turrets that are specialized against them
// This can help the turret to prioritize the targets based on the ship type and the turret that is specialized against it
// Shuttle - groupID: 31
// Corvette - groupID: 237
// Frigate - groupID: 25
// Destroyer - groupID: 420
// Cruiser - groupID: 26
// Combat Battlecruiser - groupID: 419
// Turret - Autocannon (92402)
//   - Specialized against: Shuttle(31), Corvette(237)
// Turret - Plasma (92403)
//   - Specialized against: Frigate(25), Destroyer(420)
// Turret - Howitzer (92484)
//   - Specialized against: Cruiser(26), Combat Battlecruiser(419)
// Regardless of the target, add it to the priority list as a example
public fun get_target_priority_list(
    turret: &Turret,
    _: &Character,
    priority_list: vector<u8>,
    new_target: vector<u8>,
    receipt: OnlineReceipt,
): vector<u8> {
    assert!(receipt.turret_id() == object::id(turret), EInvalidOnlineReceipt);

    let mut list = turret::unpack_priority_list(priority_list);
    let target = turret::peel_turret_target(new_target);
    vector::push_back(&mut list, target);
    // add additional rules
    let result = bcs::to_bytes(&list);

    turret::destroy_online_receipt(receipt, TurretAuth {});
    event::emit(PriorityListUpdatedEvent {
        turret_id: object::id(turret),
        priority_list: result,
    });
    result
}
