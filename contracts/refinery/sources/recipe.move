/// Recipe module installed on a Refinery `Entity`.
///
/// Holds the refinery's conversion recipe and at most one in-flight `Job`. A job
/// snapshots the recipe's outputs + finish time at start, so an admin editing the
/// recipe never alters a job already running — the invariant carried over from
/// the v0 refinery RFC (evefrontier/world-contracts#162), which the v1 design
/// adopted for timed actions.
///
/// Two actions are exposed through the entity:
/// - `start_refine` consumes the input, snapshots outputs + finish time, and
///   issues the mint proof.
/// - `claim` gates on the finish time and mints the snapshotted outputs against
///   that proof.
///
/// NOTE (integration gap): v1 `core` has no inventory/`Item` primitive or `Mint`
/// handler yet, so input consumption and output minting are stubbed and flagged
/// below. This module is an honest design probe of the start/claim + snapshot +
/// proof shape on the real `core` primitives, not a merge-ready refinery.
module refinery::recipe;

use core::{
    action::{Self, Action},
    entity::Entity,
    mod::{Self, Module},
    request::Request,
    requirement
};
use std::{internal::Permit, string::{Self, String}};
use sui::clock::Clock;

// === Errors ===

const EJobInProgress: u64 = 0;
const ENoActiveJob: u64 = 1;
const EJobNotComplete: u64 = 2;
const EProofNotIssued: u64 = 3;
const ERecipeOutputsEmpty: u64 = 4;
const ERecipeOutputsLengthMismatch: u64 = 5;
const ERecipeZeroInput: u64 = 6;
const ERecipeZeroOutput: u64 = 7;
const EWrongVersion: u64 = 8;

// === Constants ===

const VERSION: u64 = 1;

// === Structs ===

/// A conversion rule: one input type/quantity -> many output types/quantities
/// after a processing delay. Mirrors the 21 live Stillness refinery schemas
/// catalogued in `docs/data/refinery_schemas.md`.
public struct Recipe has copy, drop, store {
    input_type_id: u64,
    input_quantity: u64,
    output_type_ids: vector<u64>,
    output_quantities: vector<u64>,
    processing_ms: u64,
}

/// An in-flight refining job. Outputs + finish time are snapshotted from the
/// recipe at start so later recipe edits cannot change a running job.
public struct Job has store {
    output_type_ids: vector<u64>,
    output_quantities: vector<u64>,
    finishes_at_ms: u64,
    /// The mint proof the start request issued; the claim request consumes it.
    proof_issued: bool,
}

/// State installed on the refinery entity under the name `recipe`.
public struct RecipeState has store {
    recipe: Recipe,
    active_job: Option<Job>,
}

/// Requirement marker for the `start_refine` action. Module-scoped to `recipe`,
/// so `entity::module_mut` binds the handler onto this refinery's recipe module.
public struct StartRefine has drop {}

/// Requirement marker for the `claim` action. Module-scoped to `recipe`.
public struct Claim has drop {}

// === Public Functions ===

/// Build a recipe value. Used by `refinery::create` and by clients/tests.
///
/// Validates shape up front so a malformed recipe can never become durable
/// module state (and later make minting ambiguous): non-zero input, at least one
/// output, equal-length output vectors, and non-zero output type ids/quantities.
public fun new_recipe(
    input_type_id: u64,
    input_quantity: u64,
    output_type_ids: vector<u64>,
    output_quantities: vector<u64>,
    processing_ms: u64,
): Recipe {
    assert!(input_type_id != 0 && input_quantity > 0, ERecipeZeroInput);
    let outputs = output_type_ids.length();
    assert!(outputs > 0, ERecipeOutputsEmpty);
    assert!(outputs == output_quantities.length(), ERecipeOutputsLengthMismatch);
    let mut i = 0;
    while (i < outputs) {
        assert!(output_type_ids[i] != 0 && output_quantities[i] > 0, ERecipeZeroOutput);
        i = i + 1;
    };
    Recipe { input_type_id, input_quantity, output_type_ids, output_quantities, processing_ms }
}

/// The `start_refine` action: a single module-scoped `StartRefine` requirement.
public fun start_action(): Action {
    action::new(vector[requirement::from_config(option::some(module_name()), StartRefine {})])
}

/// The `claim` action: a single module-scoped `Claim` requirement.
public fun claim_action(): Action {
    action::new(vector[requirement::from_config(option::some(module_name()), Claim {})])
}

/// Satisfy a `StartRefine` requirement: snapshot the recipe's outputs + finish
/// time into a new `Job` and issue the mint proof. Aborts if a job is already
/// in flight.
///
/// `module_mut` peeks the next requirement's module name, so it MUST be called
/// before `take_next` pops that requirement — otherwise it would bind onto the
/// following requirement. (Surfaced this ordering coupling while writing this
/// handler; see the PR description.)
public fun start_refine(
    entity: &mut Entity,
    request: &mut Request,
    clock: &Clock,
    _ctx: &mut TxContext,
) {
    let m: &mut Module<RecipeState> = entity.module_mut(request, module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    let (_requirement, frame) = request.take_next<StartRefine>(start_permit());

    let state = m.inner_mut();
    assert!(state.active_job.is_none(), EJobInProgress);

    let recipe = state.recipe;
    // TODO(core): consume `recipe.input_quantity` of `recipe.input_type_id` from
    // an inventory module here — needs a v1 `core` inventory/`Item` primitive
    // (the archived v0 `inventory` is not part of the modular core yet).
    let finishes_at_ms = clock.timestamp_ms() + recipe.processing_ms;
    state
        .active_job
        .fill(Job {
            output_type_ids: recipe.output_type_ids,
            output_quantities: recipe.output_quantities,
            finishes_at_ms,
            proof_issued: true,
        });

    frame.destroy_empty_frame();
}

/// Satisfy a `Claim` requirement: gate on the snapshotted finish time and the
/// issued proof, then mint the outputs and clear the job. Aborts if no job is
/// active, the proof was never issued, or the job has not finished.
public fun claim(entity: &mut Entity, request: &mut Request, clock: &Clock, _ctx: &mut TxContext) {
    let m: &mut Module<RecipeState> = entity.module_mut(request, module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    let (_requirement, frame) = request.take_next<Claim>(claim_permit());

    let state = m.inner_mut();
    assert!(state.active_job.is_some(), ENoActiveJob);

    let job_ref = state.active_job.borrow();
    assert!(job_ref.proof_issued, EProofNotIssued);
    assert!(clock.timestamp_ms() >= job_ref.finishes_at_ms, EJobNotComplete);

    let Job { output_type_ids: _output_type_ids, output_quantities: _output_quantities, .. } = state
        .active_job
        .extract();
    // TODO(core): mint `_output_quantities` of `_output_type_ids` into an
    // inventory module via the gated core `Mint` handler — the start request
    // issued the proof, the claim request mints against it. Stubbed until v1
    // core ships the `Mint` handler.

    frame.destroy_empty_frame();
}

// === View Functions ===

public fun recipe(entity: &Entity): Recipe {
    borrow_state(entity).recipe
}

public fun has_active_job(entity: &Entity): bool {
    borrow_state(entity).active_job.is_some()
}

/// Finish time of the in-flight job. Aborts if there is no active job.
public fun job_finishes_at(entity: &Entity): u64 {
    let state = borrow_state(entity);
    assert!(state.active_job.is_some(), ENoActiveJob);
    state.active_job.borrow().finishes_at_ms
}

public fun input_type_id(r: &Recipe): u64 { r.input_type_id }

public fun input_quantity(r: &Recipe): u64 { r.input_quantity }

public fun output_type_ids(r: &Recipe): vector<u64> { r.output_type_ids }

public fun output_quantities(r: &Recipe): vector<u64> { r.output_quantities }

public fun processing_ms(r: &Recipe): u64 { r.processing_ms }

// === Package Functions ===

/// Build and install the recipe module. Called by `refinery::create`.
public(package) fun install(entity: &mut Entity, recipe: Recipe, _ctx: &mut TxContext): Request {
    let state = RecipeState { recipe, active_job: option::none() };
    entity.install(module_name(), state, VERSION, module_permit(), _ctx)
}

// === Private Functions ===

fun borrow_state(entity: &Entity): &RecipeState {
    let m: &Module<RecipeState> = entity.module_ref(module_name(), module_permit());
    assert!(mod::version(m) == VERSION, EWrongVersion);
    m.inner()
}

fun module_name(): String {
    string::utf8(b"recipe")
}

fun module_permit(): Permit<RecipeState> {
    internal::permit<RecipeState>()
}

fun start_permit(): Permit<StartRefine> {
    internal::permit<StartRefine>()
}

fun claim_permit(): Permit<Claim> {
    internal::permit<Claim>()
}
