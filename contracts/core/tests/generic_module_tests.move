#[test_only]
module core::generic_module_tests;

use core::{
    admin_service,
    generic_module,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use std::string;
use sui::test_scenario as ts;

const MODULE_ID: u64 = 0x70;
const TYPE_ID: u64 = 42;

fun module_name(): string::String {
    string::utf8(b"thruster")
}

fun bag_data(): vector<u8> {
    vector[1, 2, 3, 9]
}

#[test]
fun install_stores_type_id_none_behaviour_and_bytes() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    let mut req = generic_module::install(
        &mut e,
        MODULE_ID,
        TYPE_ID,
        option::some(module_name()),
        bag_data(),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    assert!(e.has_module(MODULE_ID));
    assert!(e.has_module_with_type<generic_module::GenericModule>(MODULE_ID));
    assert!(generic_module::type_id(&e, MODULE_ID) == TYPE_ID);
    assert!(generic_module::behaviour_type_id(&e, MODULE_ID).is_none());
    assert!(generic_module::data(&e, MODULE_ID) == bag_data());
    assert!(generic_module::name(&e, MODULE_ID) == option::some(module_name()));

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = generic_module::EModuleMissing)]
fun data_missing_module_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let e = claim(&mut registry, &acl, 1, scenario.ctx());

    let _ = generic_module::data(&e, MODULE_ID);

    abort
}
