/// Thin wrapper around typed module state installed on an `Assembly`.
/// Adds a human-readable name and a version to the inner behavior type `T`.
module core::mod;

use core::internal::Permit;
use std::string::String;

// === Structs ===

public struct Module<T: store> has store {
    version: u64,
    inner: T,
    name: String,
}

// === Public Functions ===

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

public fun name<T: store>(m: &Module<T>): String {
    m.name
}

// === Package Functions ===

/// Only `core::assembly` may wrap module state.
public(package) fun new<T: store>(name: String, inner: T, version: u64): Module<T> {
    Module { version, inner, name }
}
