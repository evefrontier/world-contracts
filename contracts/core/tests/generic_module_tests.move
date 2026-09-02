#[test_only]
module core::generic_module_tests;

use core::{
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    generic_module,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use std::string;
use sui::test_scenario as ts;

const MODULE_ID: u64 = 0x70;
const MODULE_ID_2: u64 = 0x71;
const TYPE_ID: u64 = 42;
const TYPE_ID_2: u64 = 43;

fun module_name(): string::String {
    string::utf8(b"thruster")
}

fun module_data(): vector<u8> {
    vector[1, 2, 3, 9]
}

fun module_data_2(): vector<u8> {
    vector[9, 8, 7]
}

fun install_generic(
    e: &mut Entity,
    acl: &AdminACL,
    module_id: u64,
    type_id: u64,
    name: vector<u8>,
    data: vector<u8>,
    ctx: &mut TxContext,
) {
    let mut req = generic_module::install(
        e,
        module_id,
        type_id,
        option::some(string::utf8(name)),
        data,
        ctx,
    );
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
}

#[test]
fun install_stores_type_id_and_bytes() {
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
        module_data(),
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);

    assert!(e.has_module(MODULE_ID));
    assert!(e.has_module_with_type<generic_module::GenericModule>(MODULE_ID));
    assert!(generic_module::type_id(&e, MODULE_ID) == TYPE_ID);
    assert!(generic_module::data(&e, MODULE_ID) == module_data());
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

#[test]
fun install_two_generic_modules_on_one_entity() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut e, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);
    install_generic(&mut e, &acl, MODULE_ID_2, TYPE_ID_2, b"turret", module_data_2(), ctx);

    assert!(e.has_module(MODULE_ID));
    assert!(e.has_module(MODULE_ID_2));
    assert!(generic_module::type_id(&e, MODULE_ID) == TYPE_ID);
    assert!(generic_module::type_id(&e, MODULE_ID_2) == TYPE_ID_2);
    assert!(generic_module::data(&e, MODULE_ID) == module_data());
    assert!(generic_module::data(&e, MODULE_ID_2) == module_data_2());

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun install_two_generic_modules_same_type_id() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut e, &acl, MODULE_ID, TYPE_ID, b"turret-a", module_data(), ctx);
    install_generic(&mut e, &acl, MODULE_ID_2, TYPE_ID, b"turret-b", module_data_2(), ctx);

    assert!(generic_module::type_id(&e, MODULE_ID) == TYPE_ID);
    assert!(generic_module::type_id(&e, MODULE_ID_2) == TYPE_ID);
    assert!(generic_module::data(&e, MODULE_ID) == module_data());
    assert!(generic_module::data(&e, MODULE_ID_2) == module_data_2());

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EModuleExists)]
fun install_duplicate_module_id_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut e, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);
    install_generic(&mut e, &acl, MODULE_ID, TYPE_ID_2, b"other", module_data_2(), ctx);

    abort
}

#[test]
fun uninstall_removes_module() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut e, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);

    let mut req = generic_module::uninstall(&mut e, MODULE_ID, ctx);
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    assert!(!e.has_module(MODULE_ID));

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = generic_module::EModuleMissing)]
fun uninstall_missing_module_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    let _req = generic_module::uninstall(&mut e, MODULE_ID, scenario.ctx());

    abort
}

#[test]
fun delete_after_uninstall() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut e, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);

    let mut req = generic_module::uninstall(&mut e, MODULE_ID, ctx);
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    let (mut req, ticket) = e.request_delete();
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.delete(req, ticket);

    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test]
fun extract_for_migration_returns_bytes_and_clears_slot() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut e, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);

    let (data, mut req) = generic_module::extract_for_migration(&mut e, MODULE_ID, ctx);
    admin_service::verify_admin(&mut req, &acl, ctx);
    e.complete_request(req);

    assert!(data == module_data());
    assert!(!e.has_module(MODULE_ID));

    install_generic(&mut e, &acl, MODULE_ID, TYPE_ID, b"thruster", data, ctx);
    assert!(generic_module::data(&e, MODULE_ID) == module_data());

    e.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = generic_module::EModuleMissing)]
fun extract_for_migration_missing_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    let (_data, _req) = generic_module::extract_for_migration(
        &mut e,
        MODULE_ID,
        scenario.ctx(),
    );

    abort
}
