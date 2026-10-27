#[test_only]
module generic_module::generic_module_tests;

use core::{
    admin_service::{Self, AdminACL},
    entity::{Self, Entity},
    object_registry::ObjectRegistry,
    request::Request,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use generic_module::generic_module;
use power::power_grid;
use std::string;
use sui::{clock, test_scenario as ts};

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

/// Claim an entity, then install its power grid. Two admin checks. Not yet shared.
fun claim_with_grid(registry: &mut ObjectRegistry, acl: &AdminACL, ctx: &mut TxContext): Entity {
    let mut entity = claim(registry, acl, 1, ctx);
    let clock = clock::create_for_testing(ctx);
    let mut req = power_grid::install(&mut entity, &clock, ctx);
    admin_service::verify_admin(&mut req, acl, ctx);
    entity.complete_request(req);
    clock.destroy_for_testing();
    entity
}

fun install_generic(
    entity: &mut Entity,
    acl: &AdminACL,
    module_id: u64,
    type_id: u64,
    name: vector<u8>,
    data: vector<u8>,
    ctx: &mut TxContext,
) {
    let clock = clock::create_for_testing(ctx);
    let mut req = generic_module::install(
        entity,
        module_id,
        type_id,
        option::some(string::utf8(name)),
        data,
        1,
        power_grid::firm(),
        power_grid::power(),
        0,
        0,
        &clock,
        ctx,
    );
    admin_service::verify_admin(&mut req, acl, ctx);
    entity.complete_request(req);
    clock.destroy_for_testing();
}

fun uninstall_generic(entity: &mut Entity, acl: &AdminACL, module_id: u64, ctx: &mut TxContext) {
    let clock = clock::create_for_testing(ctx);
    let mut req = generic_module::uninstall(entity, module_id, &clock, ctx);
    admin_service::verify_admin(&mut req, acl, ctx);
    entity.complete_request(req);
    clock.destroy_for_testing();
}

fun extract_generic(
    entity: &mut Entity,
    module_id: u64,
    ctx: &mut TxContext,
): (vector<u8>, Request) {
    let clock = clock::create_for_testing(ctx);
    let (data, req) = generic_module::extract_for_migration(entity, module_id, &clock, ctx);
    clock.destroy_for_testing();
    (data, req)
}

fun share_with_grid(scenario: &mut ts::Scenario, id: u64): ID {
    share_grid_in_tenant(scenario, id, b"test")
}

fun share_grid_in_tenant(scenario: &mut ts::Scenario, id: u64, tenant: vector<u8>): ID {
    ts::next_tx(scenario, @0xA);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let (mut entity, mut req) = entity::new(&mut registry, id, string::utf8(tenant));
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    let clock = clock::create_for_testing(scenario.ctx());
    let mut req = power_grid::install(&mut entity, &clock, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    entity.complete_request(req);
    clock.destroy_for_testing();
    let entity_id = entity.id();
    entity.share();
    ts::return_shared(registry);
    ts::return_shared(acl);
    entity_id
}

fun migrate_generic(scenario: &mut ts::Scenario, from_id: ID, to_id: ID, module_id: u64) {
    ts::next_tx(scenario, @0xA);
    let mut from = ts::take_shared_by_id<Entity>(scenario, from_id);
    let mut to = ts::take_shared_by_id<Entity>(scenario, to_id);
    let acl = take_acl(scenario);
    let clock = clock::create_for_testing(scenario.ctx());
    let (mut from_req, mut to_req) = generic_module::migrate(
        &mut from,
        &mut to,
        module_id,
        &clock,
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut from_req, &acl, scenario.ctx());
    from.complete_request(from_req);
    admin_service::verify_admin(&mut to_req, &acl, scenario.ctx());
    to.complete_request(to_req);
    clock.destroy_for_testing();
    ts::return_shared(acl);
    ts::return_shared(to);
    ts::return_shared(from);
}

#[test]
fun install_stores_type_id_and_bytes() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut entity = claim_with_grid(&mut registry, &acl, scenario.ctx());
    install_generic(
        &mut entity,
        &acl,
        MODULE_ID,
        TYPE_ID,
        b"thruster",
        module_data(),
        scenario.ctx(),
    );

    assert!(entity.has_component(MODULE_ID));
    assert!(entity.has_component_with_type<generic_module::GenericModule>(MODULE_ID));
    assert!(generic_module::type_id(&entity, MODULE_ID) == TYPE_ID);
    assert!(generic_module::data(&entity, MODULE_ID) == module_data());
    assert!(generic_module::name(&entity, MODULE_ID) == option::some(module_name()));
    assert!(power_grid::power_grid(&entity).is_module_connected(MODULE_ID));

    entity.share();
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
    let entity = claim(&mut registry, &acl, 1, scenario.ctx());

    let _ = generic_module::data(&entity, MODULE_ID);

    abort
}

#[test]
fun install_two_generic_modules_on_one_entity() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut entity = claim_with_grid(&mut registry, &acl, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut entity, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);
    install_generic(&mut entity, &acl, MODULE_ID_2, TYPE_ID_2, b"turret", module_data_2(), ctx);

    assert!(generic_module::type_id(&entity, MODULE_ID) == TYPE_ID);
    assert!(generic_module::type_id(&entity, MODULE_ID_2) == TYPE_ID_2);
    assert!(generic_module::data(&entity, MODULE_ID) == module_data());
    assert!(generic_module::data(&entity, MODULE_ID_2) == module_data_2());
    assert!(power_grid::power_grid(&entity).modules().length() == 2);

    entity.share();
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
    let mut entity = claim_with_grid(&mut registry, &acl, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut entity, &acl, MODULE_ID, TYPE_ID, b"turret-a", module_data(), ctx);
    install_generic(&mut entity, &acl, MODULE_ID_2, TYPE_ID, b"turret-b", module_data_2(), ctx);

    assert!(generic_module::type_id(&entity, MODULE_ID) == TYPE_ID);
    assert!(generic_module::type_id(&entity, MODULE_ID_2) == TYPE_ID);
    assert!(generic_module::data(&entity, MODULE_ID) == module_data());
    assert!(generic_module::data(&entity, MODULE_ID_2) == module_data_2());

    entity.share();
    ts::return_shared(acl);
    ts::return_shared(registry);
    scenario.end();
}

#[test, expected_failure(abort_code = entity::EComponentExists)]
fun install_duplicate_component_id_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut entity = claim_with_grid(&mut registry, &acl, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut entity, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);
    install_generic(&mut entity, &acl, MODULE_ID, TYPE_ID_2, b"other", module_data_2(), ctx);

    abort
}

/// Install on a bare entity with no grid aborts: only Creations connect.
#[test, expected_failure(abort_code = power_grid::EComponentMissing)]
fun install_without_grid_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut entity = claim(&mut registry, &acl, 1, scenario.ctx());
    install_generic(
        &mut entity,
        &acl,
        MODULE_ID,
        TYPE_ID,
        b"thruster",
        module_data(),
        scenario.ctx(),
    );

    abort
}

#[test]
fun uninstall_removes_module_and_disconnects() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut entity = claim_with_grid(&mut registry, &acl, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut entity, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);
    uninstall_generic(&mut entity, &acl, MODULE_ID, ctx);

    assert!(!entity.has_component(MODULE_ID));
    assert!(!power_grid::power_grid(&entity).is_module_connected(MODULE_ID));

    entity.share();
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
    let mut entity = claim(&mut registry, &acl, 1, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    let _req = generic_module::uninstall(&mut entity, MODULE_ID, &clock, scenario.ctx());

    abort
}

/// Delete needs an entity with no components, so the grid goes too.
#[test]
fun delete_after_uninstall() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, @0xA);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut entity = claim_with_grid(&mut registry, &acl, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut entity, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);
    uninstall_generic(&mut entity, &acl, MODULE_ID, ctx);

    let mut req = power_grid::uninstall(&mut entity, ctx);
    admin_service::verify_admin(&mut req, &acl, ctx);
    entity.complete_request(req);

    let (mut req, ticket) = entity.request_delete();
    admin_service::verify_admin(&mut req, &acl, ctx);
    entity.delete(req, ticket);

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
    let mut entity = claim_with_grid(&mut registry, &acl, scenario.ctx());
    let ctx = scenario.ctx();

    install_generic(&mut entity, &acl, MODULE_ID, TYPE_ID, b"thruster", module_data(), ctx);

    let (data, mut req) = extract_generic(&mut entity, MODULE_ID, ctx);
    admin_service::verify_admin(&mut req, &acl, ctx);
    entity.complete_request(req);

    assert!(data == module_data());
    assert!(!entity.has_component(MODULE_ID));
    assert!(!power_grid::power_grid(&entity).is_module_connected(MODULE_ID));

    install_generic(&mut entity, &acl, MODULE_ID, TYPE_ID, b"thruster", data, ctx);
    assert!(generic_module::data(&entity, MODULE_ID) == module_data());

    entity.share();
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
    let mut entity = claim(&mut registry, &acl, 1, scenario.ctx());

    let (_data, _req) = extract_generic(&mut entity, MODULE_ID, scenario.ctx());

    abort
}

// === Migrate ===

#[test]
fun migrate_moves_module_with_its_data_and_power() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let from_id = share_with_grid(&mut scenario, 1);
    let to_id = share_with_grid(&mut scenario, 2);
    ts::next_tx(&mut scenario, @0xA);
    {
        let mut from = ts::take_shared_by_id<Entity>(&scenario, from_id);
        let acl = take_acl(&scenario);
        install_generic(
            &mut from,
            &acl,
            MODULE_ID,
            TYPE_ID,
            b"thruster",
            module_data(),
            scenario.ctx(),
        );
        ts::return_shared(acl);
        ts::return_shared(from);
    };

    migrate_generic(&mut scenario, from_id, to_id, MODULE_ID);

    ts::next_tx(&mut scenario, @0xA);
    let from = ts::take_shared_by_id<Entity>(&scenario, from_id);
    let to = ts::take_shared_by_id<Entity>(&scenario, to_id);
    assert!(!from.has_component(MODULE_ID));
    assert!(generic_module::type_id(&to, MODULE_ID) == TYPE_ID);
    assert!(generic_module::data(&to, MODULE_ID) == module_data());
    assert!(generic_module::name(&to, MODULE_ID) == option::some(module_name()));
    assert!(power_grid::power_grid(&to).module_state(MODULE_ID).power_req() == 1);
    assert!(!power_grid::power_grid(&from).is_module_connected(MODULE_ID));
    ts::return_shared(from);
    ts::return_shared(to);
    scenario.end();
}

#[test, expected_failure(abort_code = generic_module::EWrongTenant)]
fun migrate_across_tenants_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let from_id = share_with_grid(&mut scenario, 1);
    let to_id = share_grid_in_tenant(&mut scenario, 2, b"OTHER");
    ts::next_tx(&mut scenario, @0xA);
    {
        let mut from = ts::take_shared_by_id<Entity>(&scenario, from_id);
        let acl = take_acl(&scenario);
        install_generic(
            &mut from,
            &acl,
            MODULE_ID,
            TYPE_ID,
            b"thruster",
            module_data(),
            scenario.ctx(),
        );
        ts::return_shared(acl);
        ts::return_shared(from);
    };

    migrate_generic(&mut scenario, from_id, to_id, MODULE_ID);

    abort
}

#[test, expected_failure(abort_code = generic_module::EModuleMissing)]
fun migrate_missing_module_aborts() {
    let mut scenario = ts::begin(@0xA);
    setup(&mut scenario);
    let from_id = share_with_grid(&mut scenario, 1);
    let to_id = share_with_grid(&mut scenario, 2);

    migrate_generic(&mut scenario, from_id, to_id, MODULE_ID);

    abort
}
