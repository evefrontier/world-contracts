/// A named, ordered list of `Requirement`s exposed by an `Entity`.
///
/// An action executes no logic itself; `entity::interact` turns it into a
/// `Request` that the transaction must satisfy.
module core::action;

use core::{request::{Self, Request}, requirement::Requirement};

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

public struct Action has drop, store {
    requirements: vector<Requirement>,
    version: u64,
}

// === Public Functions ===

/// Requirements are stored reversed so `pop_back` during request resolution
/// yields them in declaration order.
public fun new(mut requirements: vector<Requirement>): Action {
    requirements.reverse();
    Action { requirements, version: VERSION }
}

// === View Functions ===

public fun requirements(action: &Action): &vector<Requirement> {
    &action.requirements
}

public fun version(action: &Action): u64 {
    action.version
}

// === Package Functions ===

/// Build a `Request` from this action. `pre_requirements` are pushed after the
/// action's own (reversed) requirements, so they `pop_back` first and therefore
/// resolve before the action's declared requirements (e.g. a proximity check the
/// entity injects ahead of the action).
public(package) fun to_request(
    action: &Action,
    entity_id: Option<ID>,
    pre_requirements: vector<Requirement>,
): Request {
    let mut requirements = action.requirements.map_ref!(|r| r.clone());
    pre_requirements.do!(|r| requirements.push_back(r));
    request::new(entity_id, requirements)
}
