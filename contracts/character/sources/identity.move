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

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Identity module version does not match the package version";
#[error(code = 1)]
const EModuleMissing: vector<u8> = b"Identity module is not installed on this entity";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"identity";

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

public fun module_id(): u64 {
    mod::id_from_name(NAME)
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
    entity.install(
        module_id(),
        option::some(module_label()),
        identity,
        VERSION,
        module_permit(),
        ctx,
    )
}

/// Remove the identity module, discarding its state. Aborts if it was never installed.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(entity.has_module_with_type<Identity>(module_id()), EModuleMissing);

    let (m, req) = entity.uninstall<Identity>(module_id(), module_permit(), ctx);
    let Identity { tribe_id: _, owner: _ } = m.unwrap(module_permit());
    req
}

// === Private Functions ===

fun borrow(entity: &Entity): &Identity {
    let m: &Module<Identity> = entity.module_ref(module_id(), module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    m.inner()
}

fun module_label(): String {
    string::utf8(NAME)
}

fun module_permit(): Permit<Identity> {
    internal::permit<Identity>()
}
