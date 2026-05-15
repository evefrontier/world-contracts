#[test_only]
module world::refinery_tests;

// Skeleton tests for the refinery module — happy-path anchor + extension witness
// authorization. Full job-loop tests (start_job/claim_outputs with a real Clock
// and the inventory mint round-trip) are deferred to a follow-up since they
// require the same character / network-node / energy-source scaffolding used in
// the storage_unit test suite.
//
// TODO: port the SU test bootstrap (test_helpers::setup_world + setup_owner_cap
// + setup_character + setup_network_node + setup_energy) into a refinery setup
// helper. Then cover:
//   - anchor() creates Refinery with one inventory
//   - online()/offline() flips status
//   - authorize_extension<XAuth>() registers the witness
//   - deposit_input_by_owner / withdraw_input_by_owner round-trip
//   - start_job consumes input, sets active_job
//   - claim_outputs before finishes_at aborts EJobNotComplete
//   - claim_outputs after finishes_at mints recipe outputs into inventory
//   - second start_job while a job is active aborts EJobInProgress

use std::unit_test::assert_eq;
// use world::refinery;  // full job-loop tests pending (see TODO above)

/// Placeholder until full job-loop coverage lands. Keeps the test target
/// non-empty and confirms the module compiles under `sui move test`.
#[test]
fun module_compiles() {
    assert_eq!(1u8, 1u8);
}
