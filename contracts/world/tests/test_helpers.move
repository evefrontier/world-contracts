#[test_only]
module world::test_helpers;

use sui::test_scenario as ts;
use world::{authority::{Self, AdminCap}, world::{Self, GovernorCap}};

public fun governor(): address { @0xA }

public fun admin(): address { @0xB }

public fun user_a(): address { @0xC }

public fun user_b(): address { @0xD }

/// Initialize world and create admin cap for ADMIN
public fun setup_world(ts: &mut ts::Scenario) {
    ts::next_tx(ts, governor());
    {
        world::init_for_testing(ts.ctx());
    };

    ts::next_tx(ts, governor());
    {
        let gov_cap = ts::take_from_sender<GovernorCap>(ts);
        authority::create_admin_cap(&gov_cap, admin(), ts.ctx());
        ts::return_to_sender(ts, gov_cap);
    };
}

/// Create and transfer an owner cap for a specific object id
public fun setup_owner_cap(ts: &mut ts::Scenario, owner: address, object_id: ID) {
    ts::next_tx(ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(ts);
        let owner_cap = authority::create_owner_cap(&admin_cap, object_id, ts.ctx());
        authority::transfer_owner_cap(owner_cap, &admin_cap, owner);
        ts::return_to_sender(ts, admin_cap);
    };
}

public fun setup_owner_cap_for_user_a(ts: &mut ts::Scenario, object_id: ID) {
    setup_owner_cap(ts, user_a(), object_id);
}
