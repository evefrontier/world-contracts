#[allow(unused_use)]
module builder_extensions::turret;

use sui::{bcs, event};
use world::turret::{Self, TurretTarget, OnlineReceipt, SmartTurret};

const EReceiptTurretMismatch: u64 = 1;

public struct TurretAuth has drop {}

public struct PriorityListUpdatedEvent has copy, drop {
    turret_id: ID,
    priority_list: vector<u8>,
}

// Struct-based entry (used when world dispatches to extension).
public fun get_target_priority_list(
    mut priority_list: vector<TurretTarget>,
    smart_turret: &SmartTurret,
    new_target: TurretTarget,
    receipt: OnlineReceipt,
): vector<TurretTarget> {
    assert!(
        turret::receipt_turret_id(&receipt) == turret::smart_turret_turret_id(smart_turret),
        EReceiptTurretMismatch,
    );
    if (turret::is_agressor(&new_target)) {
        vector::push_back(&mut priority_list, new_target);
    } else if (turret::target_character_tribe(&new_target) != turret::owner_tribe(smart_turret)) {
        vector::push_back(&mut priority_list, new_target);
    };
    priority_list
}

// TS-friendly entry: priority_list and new_target as BCS bytes. Returns updated list as BCS vector<u8>.
public fun get_target_priority_list_with_params(
    priority_list: vector<u8>,
    receipt: &OnlineReceipt,
    owner_tribe: u32,
    new_target: vector<u8>,
): vector<u8> {
    let mut list = turret::unpack_priority_list(priority_list);
    let target = turret::peel_turret_target(new_target);
    if (turret::is_agressor(&target)) {
        vector::push_back(&mut list, target);
    } else if (turret::target_character_tribe(&target) != owner_tribe) {
        vector::push_back(&mut list, target);
    };
    let result = bcs::to_bytes(&list);
    event::emit(PriorityListUpdatedEvent {
        turret_id: turret::receipt_turret_id(receipt),
        priority_list: result,
    });
    result
}
