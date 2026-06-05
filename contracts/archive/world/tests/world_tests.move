#[test_only]
module world::world_tests;

use sui::test_scenario;
use world::{test_helpers::governor, world};

/// Tests that the world initialization creates a governor capability
/// Scenario: World is initialized with a governor address
/// Expected: GovernorCap is created and transferred to the governor
#[test]
fun creates_governor_cap() {
    let mut scenario = test_scenario::begin(governor());
    {
        let ctx = test_scenario::ctx(&mut scenario);
        world::init_for_testing(ctx);
    };

    test_scenario::next_tx(&mut scenario, governor());
    {
        let gov_cap = test_scenario::take_from_sender<world::GovernorCap>(&scenario);

        test_scenario::return_to_sender(&scenario, gov_cap);
    };
    test_scenario::end(scenario);
}
