/// Registry for deterministic killmail object IDs.
///
/// Every killmail derives its object ID from this registry using a `KillmailKey`
/// (`tenant + killmail_id`), guaranteeing each in-game killmail maps to exactly one on-chain
/// object.
module killmail::registry;

use std::string::String;
use sui::derived_object;

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Killmail registry version does not match the package version";
#[error(code = 1)]
const ETenantEmpty: vector<u8> = b"Tenant must be non-empty";
#[error(code = 2)]
const EKillmailIdZero: vector<u8> = b"Killmail ID must be non-zero";

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// Identity of one killmail: the game's killmail id within a tenant.
public struct KillmailKey has copy, drop, store {
    tenant: String,
    killmail_id: u64,
}

/// Shared parent for derived `Killmail` addresses.
public struct KillmailRegistry has key {
    id: UID,
    version: u64,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(KillmailRegistry { id: object::new(ctx), version: VERSION });
}

// === Public Functions ===

/// Build a killmail key. `tenant` is non-empty and `killmail_id` is non-zero.
public fun new_key(tenant: String, killmail_id: u64): KillmailKey {
    assert!(tenant.length() > 0, ETenantEmpty);
    assert!(killmail_id != 0, EKillmailIdZero);
    KillmailKey { tenant, killmail_id }
}

// === View Functions ===

public fun tenant(key: &KillmailKey): String { key.tenant }

public fun killmail_id(key: &KillmailKey): u64 { key.killmail_id }

public fun id(registry: &KillmailRegistry): ID { object::id(registry) }

public fun version(registry: &KillmailRegistry): u64 { registry.version }

/// Whether a killmail exists under `key`.
public fun exists(registry: &KillmailRegistry, key: KillmailKey): bool {
    derived_object::exists(&registry.id, key)
}

/// The object ID a killmail has, or will have, under `key`.
public fun derive_id(registry: &KillmailRegistry, key: KillmailKey): address {
    derived_object::derive_address(object::id(registry), key)
}

// === Package Functions ===

public(package) fun borrow_id(registry: &mut KillmailRegistry): &mut UID {
    assert!(registry.version == VERSION, EWrongVersion);
    &mut registry.id
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
