/// A named, ordered list of `Requirement`s exposed by an `Assembly`.
///
/// An action executes no logic itself; `assembly::interact` turns it into a
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

public(package) fun to_request(action: &Action, assembly_id: Option<ID>): Request {
    request::new(assembly_id, action.requirements.map_ref!(|r| r.clone()))
}
