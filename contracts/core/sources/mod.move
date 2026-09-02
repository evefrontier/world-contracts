/// Thin wrapper around typed module state installed on an `Entity`.
/// Adds an optional display name and a version to the inner behavior type `T`.
/// Identity is the caller-supplied `module_id` (`u64`) used as the dynamic-field key, not `name`.
module core::mod;

use std::{internal::Permit, string::String};
use sui::{bcs, hash};

// === Structs ===

public struct Module<T: store> has store {
    version: u64,
    inner: T,
    name: Option<String>,
    type_id: u64,
    is_creation_module: bool,
}

// === Public Functions ===

/// Deterministic slot for a well-known module name: first 8 bytes (LE) of
/// `blake2b256(name)` as a `u64`.
public fun id_from_name(name: vector<u8>): u64 {
    let mut b = bcs::new(hash::blake2b256(&name));
    b.peel_u64()
}

/// Unwrap the inner state. Requires a `Permit<T>`, so only `T`'s defining
/// package can extract it.
public fun unwrap<T: store>(m: Module<T>, _: Permit<T>): T {
    let Module { inner, .. } = m;
    inner
}

// === View Functions ===

public fun inner<T: store>(m: &Module<T>): &T {
    &m.inner
}

public fun inner_mut<T: store>(m: &mut Module<T>): &mut T {
    &mut m.inner
}

public fun version<T: store>(m: &Module<T>): u64 {
    m.version
}

public fun name<T: store>(m: &Module<T>): Option<String> {
    m.name
}

public fun type_id<T: store>(m: &Module<T>): u64 {
    m.type_id
}

public fun is_creation_module<T: store>(m: &Module<T>): bool {
    m.is_creation_module
}

// === Package Functions ===

/// Only `core::entity` may wrap module state.
public(package) fun new<T: store>(
    name: Option<String>,
    inner: T,
    version: u64,
    type_id: u64,
    is_creation_module: bool,
): Module<T> {
    Module { version, inner, name, type_id, is_creation_module }
}
