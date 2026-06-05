/// Identity module installed on a Character `Entity`.
///
/// Holds the character's tribe and the single wallet address bound to it.
///
/// TODO: support multi-address / multisig ownership (`VecSet<address>`) so that
/// multiple addresses can be bound to a single character.
module character::identity;

use core::{entity::Entity, mod::Module, request::Request};
use std::{internal::Permit, string::{Self, String}};

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

public struct Identity has store {
    /// Tribe the character belongs to.
    tribe_id: u32,
    /// Single address for now: client lookups rely on the Sui GraphQL
    /// `ObjectFilter.owner` scalar, which filters by exactly one address per query.
    /// TODO: support multi-address / multisig (`VecSet<address>`).
    owner: address,
}

// === View Functions ===

public fun tribe_id(entity: &Entity): u32 {
    borrow(entity).tribe_id
}

public fun owner(entity: &Entity): address {
    borrow(entity).owner
}

// === Package Functions ===

/// Build and install the identity module. Called by `character::create`.
public(package) fun install(
    entity: &mut Entity,
    tribe_id: u32,
    owner: address,
    ctx: &mut TxContext,
): Request {
    let identity = Identity { tribe_id, owner };
    entity.install(module_name(), identity, VERSION, module_permit(), ctx)
}

// === Private Functions ===

fun borrow(entity: &Entity): &Identity {
    let m: &Module<Identity> = entity.module_ref(module_name(), module_permit());
    m.inner()
}

fun module_name(): String {
    string::utf8(b"identity")
}

fun module_permit(): Permit<Identity> {
    internal::permit<Identity>()
}
