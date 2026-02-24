#[allow(unused_use)]
module extension_examples::turret;

use extension_examples::config::{Self, XAuth, ExtensionConfig};
use sui::{bcs, event};
use world::{character::Character, turret::{Self, Turret, OnlineReceipt}};

#[error(code = 0)]
const EInvalidOnlineReceipt: u64 = 0;

public struct PriorityListUpdatedEvent has copy, drop {
    turret_id: ID,
    priority_list: vector<u8>,
}

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

    turret::destroy_online_receipt(receipt, config::x_auth());
    event::emit(PriorityListUpdatedEvent {
        turret_id: object::id(turret),
        priority_list: result,
    });
    result
}
