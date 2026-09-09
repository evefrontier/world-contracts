/// Thin wrapper around typed component state installed on an `Entity`.
/// Adds an optional display name and a version to the inner behavior type `T`.
/// Identity is the caller-supplied `component_id` (`u64`) used as the dynamic-field key.
module core::component;

use std::{internal::Permit, string::String};
use sui::{bcs, hash};

// === Structs ===

public struct Component<T: store> has store {
    version: u64,
    inner: T,
    name: Option<String>,
}

// === Public Functions ===

/// Deterministic slot for a well-known component name: first 8 bytes (LE) of
/// `blake2b256(name)` as a `u64`.
public fun id_from_name(name: vector<u8>): u64 {
    let mut b = bcs::new(hash::blake2b256(&name));
    b.peel_u64()
}

/// Unwrap the inner state. Requires a `Permit<T>`, so only `T`'s defining
/// package can extract it.
public fun unwrap<T: store>(c: Component<T>, _: Permit<T>): T {
    let Component { inner, .. } = c;
    inner
}

// === View Functions ===

public fun inner<T: store>(c: &Component<T>): &T {
    &c.inner
}

public fun inner_mut<T: store>(c: &mut Component<T>): &mut T {
    &mut c.inner
}

public fun version<T: store>(c: &Component<T>): u64 {
    c.version
}

public fun name<T: store>(c: &Component<T>): Option<String> {
    c.name
}

// === Package Functions ===

/// Only `core::entity` may wrap component state.
public(package) fun new<T: store>(name: Option<String>, inner: T, version: u64): Component<T> {
    Component { version, inner, name }
}
