/// Identity module installed on a Character `Entity`.
///
/// Holds the character's tribe and the single wallet address bound to it.
///
/// TODO: support multi-address / multisig ownership (`VecSet<address>`) so that
/// multiple addresses can be bound to a single character.
module character::identity;

use core::{entity::Entity, mod::{Self, Module}, request::Request};
use std::{internal::Permit, string::{Self, String}};

// === Errors ===

const EWrongVersion: u64 = 0;
const EModuleMissing: u64 = 1;

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

public struct Identity has store {
    tribe_id: u32,
    owner: address,
}

// === View Functions ===

public fun tribe_id(entity: &Entity): u32 {
    borrow(entity).tribe_id
}

public fun owner(entity: &Entity): address {
    borrow(entity).owner
}

// === Public Functions ===

/// Build and install the identity module on a character entity.
public fun install(
    entity: &mut Entity,
    tribe_id: u32,
    owner: address,
    ctx: &mut TxContext,
): Request {
    let identity = Identity { tribe_id, owner };
    entity.install(module_name(), identity, VERSION, module_permit(), ctx)
}

/// Remove the identity module, discarding its state. Aborts if it was never installed.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(entity.has_module_with_type<Identity>(module_name()), EModuleMissing);

    let (m, req) = entity.uninstall<Identity>(module_name(), module_permit(), ctx);
    let Identity { tribe_id: _, owner: _ } = m.unwrap(module_permit());
    req
}

// === Private Functions ===

fun borrow(entity: &Entity): &Identity {
    let m: &Module<Identity> = entity.module_ref(module_name(), module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    m.inner()
}

fun module_name(): String {
    string::utf8(b"identity")
}

fun module_permit(): Permit<Identity> {
    internal::permit<Identity>()
}
