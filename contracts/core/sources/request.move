/// Transaction-scoped checklist for one action.
///
/// `Request` has no abilities: it cannot be stored, copied, or dropped. Once an
/// action creates it, the transaction must satisfy every requirement and
/// `complete` it (via `entity::complete_request`).
///
/// A module can also gate its own operation on a non-entity object (e.g. a frozen
/// record): `new_for<T>` starts a request tagged with the issuing type `T`, and only
/// `complete_for<T>` finishes it. Entities never accept a tagged request.
module core::request;

use core::requirement::Requirement;
use std::{internal::Permit, type_name::{Self, TypeName}};

// === Errors ===

#[error(code = 0)]
const EWrongRequirementType: vector<u8> = b"Next requirement does not match the expected type";
#[error(code = 1)]
const EFrameNotEmpty: vector<u8> = b"Frame still holds an unconsumed requirement";
#[error(code = 2)]
const ERequestNotComplete: vector<u8> = b"Request has unsatisfied requirements";
#[error(code = 3)]
const ENoRequirements: vector<u8> = b"Request has no requirements to take";
#[error(code = 4)]
const EWrongIssuer: vector<u8> = b"Request was issued by a different module";

// === Structs ===

public struct Request {
    /// Entity this request targets, if any.
    entity_id: Option<ID>,
    /// Entity id the presented `AccessCap` authorises, resolved by an access
    /// handler mid-request, if any. Transient: it lives only for this request
    /// and is dropped on `complete`.
    authorized_id: Option<ID>,
    /// Type that issued a non-entity request via `new_for`; `none` for entity requests.
    issuer: Option<TypeName>,
    /// Outstanding requirements, stored in reverse of declaration order.
    requires: vector<Requirement>,
}

/// Requirements spawned by a handler before they are pushed back onto a request.
public struct Frame {
    pending: vector<Requirement>,
}

// === Public Functions ===

/// Start a request for an operation of the module that defines `T`, outside any
/// entity. `requires` is in declaration order. Finish it with `complete_for<T>`.
public fun new_for<T>(_: Permit<T>, mut requires: vector<Requirement>): Request {
    requires.reverse();
    Request {
        entity_id: option::none(),
        authorized_id: option::none(),
        issuer: option::some(type_name::with_original_ids<T>()),
        requires,
    }
}

/// Complete a request started by `new_for<T>`. Aborts unless `T` issued it and every
/// requirement has been satisfied.
public fun complete_for<T>(request: Request, _: Permit<T>) {
    let Request { issuer, requires, .. } = request;
    assert!(issuer == option::some(type_name::with_original_ids<T>()), EWrongIssuer);
    assert!(requires.length() == 0, ERequestNotComplete);
}

/// Pop the next requirement, proving the caller owns type `T` via a `Permit`.
/// Returns the requirement plus a `Frame` the handler can push follow-ups into.
///
/// Only the requirement *type* is checked here. Entity-id and component-id
/// targeting are enforced when the handler borrows the component via
/// `entity::component_mut`, which reads `entity_id()` and `next().component_id()`
/// off the request.
public fun take_next<T>(request: &mut Request, _: Permit<T>): (Requirement, Frame) {
    assert!(request.requires.length() > 0, ENoRequirements);
    let next = request.requires.pop_back();
    assert!(next.is<T>(), EWrongRequirementType);
    (next, Frame { pending: vector[] })
}

/// Add a newly-spawned requirement to a `Frame`.
public fun require(frame: &mut Frame, requirement: Requirement) {
    frame.pending.push_back(requirement);
}

/// Discard an empty `Frame` without touching the request.
public fun destroy_empty_frame(frame: Frame) {
    let Frame { pending } = frame;
    assert!(pending.length() == 0, EFrameNotEmpty);
    pending.destroy_empty();
}

/// Push a handler's spawned requirements back onto the request.
public fun enqueue(request: &mut Request, frame: Frame) {
    let Frame { pending } = frame;
    pending.destroy!(|r| request.requires.push_back(r));
}

// === View Functions ===

public fun entity_id(r: &Request): Option<ID> {
    r.entity_id
}

/// Entity id the presented cap authorises, recorded by an access handler, if one ran.
public fun authorized_id(r: &Request): Option<ID> {
    r.authorized_id
}

/// Type that issued a `new_for` request, if any.
public fun issuer(r: &Request): Option<TypeName> {
    r.issuer
}

public fun requires(r: &Request): &vector<Requirement> {
    &r.requires
}

/// Borrow the next requirement (the one `take_next` would pop) without removing
/// it. Used by `entity::component_mut` to read the target component id.
public fun next(r: &Request): &Requirement {
    let len = r.requires.length();
    assert!(len > 0, ENoRequirements);
    &r.requires[len - 1]
}

// === Package Functions ===

public(package) fun new(entity_id: Option<ID>, requires: vector<Requirement>): Request {
    Request { entity_id, authorized_id: option::none(), issuer: option::none(), requires }
}

/// Record the entity id the presented cap authorises, resolved by an access
/// handler mid-request.
public(package) fun set_authorized_id(request: &mut Request, authorized_id: ID) {
    request.authorized_id = option::some(authorized_id);
}

/// Complete an entity request. Aborts if a module issued it via `new_for`, or unless
/// every requirement has been satisfied.
public(package) fun complete(request: Request) {
    let Request { issuer, requires, .. } = request;
    assert!(issuer.is_none(), EWrongIssuer);
    assert!(requires.length() == 0, ERequestNotComplete);
}

// === Test Functions ===

#[test_only]
public fun new_for_testing(entity_id: Option<ID>, requires: vector<Requirement>): Request {
    Request { entity_id, authorized_id: option::none(), issuer: option::none(), requires }
}

#[test_only]
public fun destroy(r: Request) {
    let Request { .. } = r;
}
