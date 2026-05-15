// Recipe registry — describes how a refinery converts one input item type into a set of
// output item types over a defined processing time.
//
// Recipes are admin-curated. Each `Recipe` is keyed by the input `type_id`, so a refinery
// only needs to know its input slot's type to look up what it can produce. A single recipe
// can produce **multiple** output types (e.g. ore → tritanium + pyerite + waste).
//
// # Bridging
//
// Like other on-chain data, the source of truth for which recipes exist is the game server,
// which mints them into the on-chain `RecipeRegistry` via `register_recipe`. The registry
// is a shared object so any assembly that needs to consult a recipe can do so.
//
// # Quantity semantics
//
// `input_quantity` is the *minimum batch size* — `refinery::start_job` consumes exactly
// this many units of the input per job. Output quantities are per-batch.
//
// # Future
//
// - Variable-yield recipes (RNG output bands).
// - Per-character efficiency modifiers (skills, ship bonuses).
// - Per-refinery throughput modifiers.
// - Multiple inputs per recipe.
module world::recipe;

use std::string::String;
use sui::{dynamic_field as df, event};
use world::access::AdminACL;

// === Errors ===
#[error(code = 0)]
const ERecipeAlreadyExists: vector<u8> = b"Recipe for this input type already exists";
#[error(code = 1)]
const ERecipeNotFound: vector<u8> = b"Recipe not found for the given input type";
#[error(code = 2)]
const ERecipeInvalid: vector<u8> = b"Recipe must specify a non-zero input quantity and processing time";
#[error(code = 3)]
const ERecipeOutputsEmpty: vector<u8> = b"Recipe must have at least one output";
#[error(code = 4)]
const ERecipeInputTypeMismatch: vector<u8> = b"Recipe input type does not match its registry key";

// === Structs ===

/// Shared registry holding every refinery recipe. Keyed by input `type_id`.
public struct RecipeRegistry has key {
    id: UID,
}

/// A single conversion rule. Stored as a dynamic field value on `RecipeRegistry`,
/// keyed by `RecipeKey { input_type_id }`.
///
/// `outputs` is parallel: `output_type_ids[i]` is produced in `output_quantities[i]`
/// units per batch.
public struct Recipe has copy, drop, store {
    name: String,
    input_type_id: u64,
    input_quantity: u32,
    output_type_ids: vector<u64>,
    output_quantities: vector<u32>,
    processing_time_ms: u64,
}

/// Dynamic-field key for `Recipe` lookup.
public struct RecipeKey has copy, drop, store {
    input_type_id: u64,
}

// === Events ===

public struct RecipeRegisteredEvent has copy, drop {
    input_type_id: u64,
    name: String,
    input_quantity: u32,
    output_type_ids: vector<u64>,
    output_quantities: vector<u32>,
    processing_time_ms: u64,
}

public struct RecipeUpdatedEvent has copy, drop {
    input_type_id: u64,
    name: String,
    input_quantity: u32,
    output_type_ids: vector<u64>,
    output_quantities: vector<u32>,
    processing_time_ms: u64,
}

public struct RecipeRemovedEvent has copy, drop {
    input_type_id: u64,
}

// === Init ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(RecipeRegistry { id: object::new(ctx) });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

// === Admin ===

public fun register_recipe(
    registry: &mut RecipeRegistry,
    admin_acl: &AdminACL,
    name: String,
    input_type_id: u64,
    input_quantity: u32,
    output_type_ids: vector<u64>,
    output_quantities: vector<u32>,
    processing_time_ms: u64,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    validate_recipe_args(
        input_type_id,
        input_quantity,
        &output_type_ids,
        &output_quantities,
        processing_time_ms,
    );
    let key = RecipeKey { input_type_id };
    assert!(!df::exists_(&registry.id, key), ERecipeAlreadyExists);
    let recipe = Recipe {
        name,
        input_type_id,
        input_quantity,
        output_type_ids,
        output_quantities,
        processing_time_ms,
    };
    df::add(&mut registry.id, key, recipe);

    event::emit(RecipeRegisteredEvent {
        input_type_id,
        name,
        input_quantity,
        output_type_ids,
        output_quantities,
        processing_time_ms,
    });
}

/// Overwrite an existing recipe. Aborts if no recipe is registered for `input_type_id`.
public fun update_recipe(
    registry: &mut RecipeRegistry,
    admin_acl: &AdminACL,
    name: String,
    input_type_id: u64,
    input_quantity: u32,
    output_type_ids: vector<u64>,
    output_quantities: vector<u32>,
    processing_time_ms: u64,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    validate_recipe_args(
        input_type_id,
        input_quantity,
        &output_type_ids,
        &output_quantities,
        processing_time_ms,
    );
    let key = RecipeKey { input_type_id };
    assert!(df::exists_(&registry.id, key), ERecipeNotFound);
    let _old: Recipe = df::remove(&mut registry.id, key);
    let recipe = Recipe {
        name,
        input_type_id,
        input_quantity,
        output_type_ids,
        output_quantities,
        processing_time_ms,
    };
    df::add(&mut registry.id, key, recipe);

    event::emit(RecipeUpdatedEvent {
        input_type_id,
        name,
        input_quantity,
        output_type_ids,
        output_quantities,
        processing_time_ms,
    });
}

public fun remove_recipe(
    registry: &mut RecipeRegistry,
    admin_acl: &AdminACL,
    input_type_id: u64,
    ctx: &TxContext,
) {
    admin_acl.verify_sponsor(ctx);
    let key = RecipeKey { input_type_id };
    assert!(df::exists_(&registry.id, key), ERecipeNotFound);
    let _removed: Recipe = df::remove(&mut registry.id, key);
    event::emit(RecipeRemovedEvent { input_type_id });
}

// === Views ===

public fun has_recipe(registry: &RecipeRegistry, input_type_id: u64): bool {
    df::exists_(&registry.id, RecipeKey { input_type_id })
}

public fun borrow_recipe(registry: &RecipeRegistry, input_type_id: u64): &Recipe {
    let key = RecipeKey { input_type_id };
    assert!(df::exists_(&registry.id, key), ERecipeNotFound);
    df::borrow<RecipeKey, Recipe>(&registry.id, key)
}

public fun name(recipe: &Recipe): String { recipe.name }
public fun input_type_id(recipe: &Recipe): u64 { recipe.input_type_id }
public fun input_quantity(recipe: &Recipe): u32 { recipe.input_quantity }
public fun output_type_ids(recipe: &Recipe): &vector<u64> { &recipe.output_type_ids }
public fun output_quantities(recipe: &Recipe): &vector<u32> { &recipe.output_quantities }
public fun processing_time_ms(recipe: &Recipe): u64 { recipe.processing_time_ms }

// === Internal ===

fun validate_recipe_args(
    input_type_id: u64,
    input_quantity: u32,
    output_type_ids: &vector<u64>,
    output_quantities: &vector<u32>,
    processing_time_ms: u64,
) {
    assert!(input_type_id != 0, ERecipeInvalid);
    assert!(input_quantity > 0, ERecipeInvalid);
    assert!(processing_time_ms > 0, ERecipeInvalid);
    let n = vector::length(output_type_ids);
    assert!(n > 0, ERecipeOutputsEmpty);
    assert!(n == vector::length(output_quantities), ERecipeOutputsEmpty);
    let mut i = 0;
    while (i < n) {
        assert!(*vector::borrow(output_type_ids, i) != 0, ERecipeInvalid);
        assert!(*vector::borrow(output_quantities, i) > 0, ERecipeInvalid);
        // Cannot reuse the input type_id as an output (avoids trivial loops)
        assert!(*vector::borrow(output_type_ids, i) != input_type_id, ERecipeInputTypeMismatch);
        i = i + 1;
    };
}
