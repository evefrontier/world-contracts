#[test_only]
module world::energy_tests;

use std::unit_test::assert_eq;
use sui::{table::{Self, Table}, test_scenario as ts};
use world::{
    access::AdminCap,
    energy::{Self, EnergyConfig, EnergySource},
    test_helpers::{
        Self,
        admin,
        user_a,
        assembly_type_1,
        assembly_type_2,
        assembly_type_3,
        assembly_type_1_energy,
        assembly_type_2_energy,
        assembly_type_3_energy
    }
};

const MAX_PRODUCTION: u64 = 100;

public struct NetworkNode has key {
    id: UID,
    energy: EnergySource,
    connected_assemblies: Table<ID, bool>,
}

fun create_network_node(ts: &mut ts::Scenario, max_production: u64): ID {
    ts::next_tx(ts, admin());
    let uid = object::new(ts.ctx());
    let network_node_id = object::uid_to_inner(&uid);
    let nwn = NetworkNode {
        id: uid,
        energy: energy::create(max_production),
        connected_assemblies: table::new(ts.ctx()),
    };
    transfer::share_object(nwn);
    network_node_id
}

#[test]
fun set_and_get_assembly_energy_configs() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let energy_1 = energy_config.assembly_energy(assembly_type_1());
        let energy_2 = energy_config.assembly_energy(assembly_type_2());
        let energy_3 = energy_config.assembly_energy(assembly_type_3());

        assert_eq!(energy_1, assembly_type_1_energy());
        assert_eq!(energy_2, assembly_type_2_energy());
        assert_eq!(energy_3, assembly_type_3_energy());

        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun set_energy_config_updates_existing() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut energy_config = ts::take_shared<EnergyConfig>(&ts);
        energy_config.set_energy_config(&admin_cap, assembly_type_1(), 75);

        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::next_tx(&mut ts, admin());
    {
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let energy = energy_config.assembly_energy(assembly_type_1());
        assert_eq!(energy, 75);

        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun remove_energy_config() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut energy_config = ts::take_shared<EnergyConfig>(&ts);
        energy_config.remove_energy_config(&admin_cap, assembly_type_2());

        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };
    ts::next_tx(&mut ts, admin());
    {
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        let energy_1 = energy_config.assembly_energy(assembly_type_1());
        let energy_3 = energy_config.assembly_energy(assembly_type_3());
        assert_eq!(energy_1, assembly_type_1_energy());
        assert_eq!(energy_3, assembly_type_3_energy());

        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun create_energy_source() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert_eq!(nwn.energy.max_energy_production(), MAX_PRODUCTION);
        assert_eq!(nwn.energy.current_energy_production(), 0);
        assert_eq!(nwn.energy.total_reserved_energy(), 0);

        ts::return_shared(nwn);
    };

    ts::end(ts);
}

#[test]
fun start_energy_production() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);
        assert_eq!(nwn.energy.current_energy_production(), MAX_PRODUCTION);

        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        assert_eq!(nwn.energy.total_reserved_energy(), assembly_type_1_energy());

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun stop_energy_production() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);
        assert_eq!(nwn.energy.current_energy_production(), MAX_PRODUCTION);
        assert_eq!(nwn.energy.total_reserved_energy(), 0);

        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        assert_eq!(nwn.energy.total_reserved_energy(), assembly_type_1_energy());

        nwn.energy.stop_energy_production(nwn_id);
        assert_eq!(nwn.energy.current_energy_production(), 0);
        assert_eq!(nwn.energy.total_reserved_energy(), 0);

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun multiple_start_stop_cycles() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);
        nwn.energy.stop_energy_production(nwn_id);
        nwn.energy.start_energy_production(nwn_id);
        assert_eq!(nwn.energy.current_energy_production(), MAX_PRODUCTION);

        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        nwn.energy.stop_energy_production(nwn_id);
        assert_eq!(nwn.energy.total_reserved_energy(), 0);
        nwn.energy.start_energy_production(nwn_id);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        assert_eq!(nwn.energy.total_reserved_energy(), assembly_type_1_energy());

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun reserve_energy_updates_total_correctly() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);

        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        assert_eq!(nwn.energy.total_reserved_energy(), assembly_type_1_energy());

        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_2());
        assert_eq!(
            nwn.energy.total_reserved_energy(),
            assembly_type_1_energy() + assembly_type_2_energy(),
        );

        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_3());
        assert_eq!(
            nwn.energy.total_reserved_energy(),
            assembly_type_1_energy() + assembly_type_2_energy() + assembly_type_3_energy(),
        );

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun reserve_energy_at_capacity() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut energy_config = ts::take_shared<EnergyConfig>(&ts);
        // intentionally increase assembly energy requirement and see if it works
        energy_config.set_energy_config(&admin_cap, assembly_type_1(), MAX_PRODUCTION);

        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());

        assert_eq!(nwn.energy.total_reserved_energy(), MAX_PRODUCTION);
        assert_eq!(nwn.energy.available_energy(), 0);

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

#[test]
fun release_energy_updates_total_correctly() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);

        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_2());
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_3());

        let total = assembly_type_1_energy() + assembly_type_2_energy() + assembly_type_3_energy();
        assert_eq!(nwn.energy.total_reserved_energy(), total);

        nwn.energy.release_energy(nwn_id, &energy_config, assembly_type_1());
        assert_eq!(nwn.energy.total_reserved_energy(), total - assembly_type_1_energy());

        nwn.energy.release_energy(nwn_id, &energy_config, assembly_type_2());
        assert_eq!(nwn.energy.total_reserved_energy(), assembly_type_3_energy());

        nwn.energy.release_energy(nwn_id, &energy_config, assembly_type_3());
        assert_eq!(nwn.energy.total_reserved_energy(), 0);
        assert_eq!(nwn.energy.available_energy(), MAX_PRODUCTION);

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun available_energy_view() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);
        assert_eq!(nwn.energy.available_energy(), MAX_PRODUCTION);

        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        assert_eq!(nwn.energy.available_energy(), MAX_PRODUCTION - assembly_type_1_energy());

        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_2());
        assert_eq!(
            nwn.energy.available_energy(),
            MAX_PRODUCTION - (assembly_type_1_energy() + assembly_type_2_energy()),
        );

        nwn.energy.release_energy(nwn_id, &energy_config, assembly_type_2());
        assert_eq!(nwn.energy.available_energy(), MAX_PRODUCTION - assembly_type_1_energy());

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun current_energy_production_view() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        assert_eq!(nwn.energy.current_energy_production(), 0);

        nwn.energy.start_energy_production(nwn_id);
        assert_eq!(nwn.energy.current_energy_production(), MAX_PRODUCTION);

        nwn.energy.stop_energy_production(nwn_id);
        assert_eq!(nwn.energy.current_energy_production(), 0);

        ts::return_shared(nwn);
    };

    ts::end(ts);
}

#[test]
fun reserve_after_stop_clears_reservations() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);

        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_2());

        nwn.energy.stop_energy_production(nwn_id);
        assert_eq!(nwn.energy.total_reserved_energy(), 0);

        nwn.energy.start_energy_production(nwn_id);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        assert_eq!(nwn.energy.total_reserved_energy(), assembly_type_1_energy());

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
fun multiple_network_nodes_independently() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn1_id = create_network_node(&mut ts, 100);
    let nwn2_id = create_network_node(&mut ts, 200);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn1 = ts::take_shared_by_id<NetworkNode>(&ts, nwn1_id);
        let mut nwn2 = ts::take_shared_by_id<NetworkNode>(&ts, nwn2_id);
        nwn1.energy.start_energy_production(nwn1_id);
        nwn2.energy.start_energy_production(nwn2_id);

        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn1.energy.reserve_energy(nwn1_id, &energy_config, assembly_type_1());
        nwn2.energy.reserve_energy(nwn2_id, &energy_config, assembly_type_1());
        nwn2.energy.reserve_energy(nwn2_id, &energy_config, assembly_type_2());

        assert_eq!(nwn1.energy.total_reserved_energy(), assembly_type_1_energy());
        assert_eq!(
            nwn2.energy.total_reserved_energy(),
            assembly_type_1_energy() + assembly_type_2_energy(),
        );

        ts::return_shared(nwn1);
        ts::return_shared(nwn2);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = energy::ETypeIdEmpty)]
fun reserve_energy_with_empty_type_id() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, 0);

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = energy::ETypeIdEmpty)]
fun set_energy_config_with_empty_type_id() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut energy_config = ts::take_shared<EnergyConfig>(&ts);
        energy_config.set_energy_config(&admin_cap, 0, 50);

        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = energy::EInvalidEnergyAmount)]
fun set_energy_config_with_zero_energy_required() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut energy_config = ts::take_shared<EnergyConfig>(&ts);
        energy_config.set_energy_config(&admin_cap, assembly_type_1(), 0);

        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = energy::ETypeIdEmpty)]
fun remove_energy_config_with_empty_type_id() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut energy_config = ts::take_shared<EnergyConfig>(&ts);
        energy_config.remove_energy_config(&admin_cap, 0);

        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = energy::EInvalidMaxEnergyProduction)]
fun create_with_zero_max_production() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let uid = object::new(ts.ctx());
        let nwn = NetworkNode {
            id: uid,
            energy: energy::create(0),
            connected_assemblies: table::new(ts.ctx()),
        };
        ts::return_shared(nwn);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = energy::ETypeIdEmpty)]
fun release_energy_with_empty_type_id() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        nwn.energy.release_energy(nwn_id, &energy_config, 0);

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = energy::EIncorrectAssemblyType)]
fun remove_energy_config_nonexistent() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut energy_config = ts::take_shared<EnergyConfig>(&ts);
        energy_config.remove_energy_config(&admin_cap, 9999);

        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    abort
}

#[test]
#[expected_failure(abort_code = energy::ENotProducingEnergy)]
fun reserving_without_starting_production() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    test_helpers::configure_assembly_energy(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        let energy_config = ts::take_shared<EnergyConfig>(&ts);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = energy::ENotProducingEnergy)]
fun stop_energy_production_when_not_producing() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.stop_energy_production(nwn_id);
        assert_eq!(nwn.energy.current_energy_production(), 0);
        assert_eq!(nwn.energy.total_reserved_energy(), 0);

        ts::return_shared(nwn);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = energy::EInsufficientAvailableEnergy)]
fun reserving_more_than_available_energy() {
    let mut ts = ts::begin(user_a());
    test_helpers::setup_world(&mut ts);
    let nwn_id = create_network_node(&mut ts, MAX_PRODUCTION);

    ts::next_tx(&mut ts, admin());
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&ts);
        let mut energy_config = ts::take_shared<EnergyConfig>(&ts);
        energy_config.set_energy_config(&admin_cap, assembly_type_1(), 80);
        energy_config.set_energy_config(&admin_cap, assembly_type_2(), 30);

        let mut nwn = ts::take_shared_by_id<NetworkNode>(&ts, nwn_id);
        nwn.energy.start_energy_production(nwn_id);
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_1());
        nwn.energy.reserve_energy(nwn_id, &energy_config, assembly_type_2());

        ts::return_shared(nwn);
        ts::return_shared(energy_config);
        ts::return_to_sender(&ts, admin_cap);
    };

    ts::end(ts);
}
