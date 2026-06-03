/// Package-authorship proof used across the core request and module APIs.
///
/// A `Permit<T>` is unforgeable proof that the holder's package defines `T`.
/// It gates the two privileged operations of the architecture:
/// - satisfying a `Requirement` of type `T` (`request::take_next`)
/// - borrowing or unwrapping a `Module<T>` (`assembly::module_mut`, `mod::unwrap`)
module core::internal;

use std::type_name;

// === Errors ===

const ENotPackageAuthor: u64 = 0;

// === Structs ===

public struct Permit<phantom T> has drop {}

// === Public Functions ===

/// Mint a `Permit<T>` by presenting a `drop` witness `W` defined in the same
/// package as `T`. Move only lets a package construct its own structs, so a
/// same-package witness is unforgeable proof that the caller authored `T`.
///
/// Keeping `T` and the witness `W` separate lets `T` be a non-`drop` type such
/// as module state that holds a `Table`. For requirement markers (which are
/// `drop`) the witness can simply be the marker itself.
public fun permit<T, W: drop>(_witness: W): Permit<T> {
    assert!(same_package<T, W>(), ENotPackageAuthor);
    Permit {}
}

// === Private Functions ===

/// True when `T` and `W` originate from the same (original) package address.
fun same_package<T, W>(): bool {
    type_name::with_original_ids<T>().address_string()
        == type_name::with_original_ids<W>().address_string()
}

// === Test Functions ===

#[test_only]
public fun permit_for_testing<T>(): Permit<T> {
    Permit {}
}
