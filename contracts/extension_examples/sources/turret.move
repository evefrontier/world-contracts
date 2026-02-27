/// Extension contract for custom turret targeting behaviour.
///
/// The game calls `get_target_priority_list` on behaviour change with a target candidate list
/// (vector<TargetCandidate>; one behaviour_change per candidate. e.g. STARTED_ATTACK if both ENTERED and STARTED_ATTACK apply).
/// You apply rules and return BCS of vector<ReturnTargetPriorityList> (target_item_id, priority_weight).
///
/// The caller receives an `OnlineReceipt` from the world to prove the turret is online; the receipt
/// is a hot potato and must be consumed. Before returning, the extension must call
/// `turret::destroy_online_receipt(receipt, auth_witness)` from the world so the receipt is
/// destroyed and the call is valid.
module extension_examples::turret;

use sui::{bcs, event};
use world::{character::Character, turret::{Self, Turret, OnlineReceipt}};

#[error(code = 0)]
const EInvalidOnlineReceipt: vector<u8> = b"Invalid online receipt";

public struct PriorityListUpdatedEvent has copy, drop {
    turret_id: ID,
    priority_list: vector<u8>,
}

public struct TurretAuth has drop {}

// More details to make decisions
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
// Example: build return list (target_item_id, priority_weight) from the priority list.
// Extension uses turret::unpack_candidate_list(target_candidate_list) to get vector<TargetCandidate>.
public fun get_target_priority_list(
    turret: &Turret,
    _: &Character,
    target_candidate_list: vector<u8>,
    receipt: OnlineReceipt,
): vector<u8> {
    assert!(receipt.turret_id() == object::id(turret), EInvalidOnlineReceipt);

    let _ = turret::unpack_candidate_list(target_candidate_list);
    // Return empty priority list for this example; extension can build return_list from candidates.
    // TODO: The return list is mutable expecting the extension to mutate it.
    let mut return_list = vector::empty<turret::ReturnTargetPriorityList>();
    let result = bcs::to_bytes(&return_list);

    turret::destroy_online_receipt(receipt, TurretAuth {});
    event::emit(PriorityListUpdatedEvent {
        turret_id: object::id(turret),
        priority_list: result,
    });
    result
}
