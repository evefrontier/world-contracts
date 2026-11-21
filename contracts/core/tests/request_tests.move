#[test_only]
module core::request_tests;

use core::{
    admin_service,
    entity,
    request,
    test_helpers::{admin, setup, take_acl, take_registry, tenant}
};
use std::type_name;
use sui::test_scenario as ts;

const OTHER: address = @0xB;

/// Witness for a test module's own operation.
public struct Register() has drop;
/// A second module type, to show requests are bound to their issuer.
public struct Other() has drop;

fun admin_request(): request::Request {
    request::new_for(internal::permit<Register>(), vector[admin_service::admin_requirement()])
}

// === new_for / complete_for ===

#[test]
fun new_for_is_tagged_and_not_entity_scoped() {
    let req = admin_request();
    assert!(req.issuer() == option::some(type_name::with_original_ids<Register>()));
    assert!(req.entity_id().is_none());
    req.destroy();
}

#[test]
fun complete_for_after_requirements_met() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    ts::next_tx(&mut scenario, admin());
    let acl = take_acl(&scenario);

    let mut req = admin_request();
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    req.complete_for(internal::permit<Register>());

    ts::return_shared(acl);
    scenario.end();
}

#[test]
fun new_for_resolves_requirements_in_declaration_order() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    ts::next_tx(&mut scenario, admin());
    let mut acl = take_acl(&scenario);
    acl.add_sponsors(vector[admin()], scenario.ctx());

    let mut req = request::new_for(
        internal::permit<Register>(),
        vector[admin_service::admin_requirement(), admin_service::sponsor_requirement()],
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());
    req.complete_for(internal::permit<Register>());

    ts::return_shared(acl);
    scenario.end();
}

#[test, expected_failure(abort_code = request::ERequestNotComplete)]
fun complete_for_with_pending_requirement_aborts() {
    admin_request().complete_for(internal::permit<Register>());
    abort
}

#[test, expected_failure(abort_code = request::EWrongIssuer)]
fun complete_for_by_other_type_aborts() {
    // An empty request from another module can't stand in for this one.
    request::new_for(internal::permit<Other>(), vector[]).complete_for(
        internal::permit<Register>(),
    );
    abort
}

#[test, expected_failure(abort_code = request::EWrongIssuer)]
fun complete_for_on_entity_request_aborts() {
    request::new_for_testing(option::none(), vector[]).complete_for(internal::permit<Register>());
    abort
}

#[test, expected_failure(abort_code = request::EWrongIssuer)]
fun entity_rejects_tagged_request() {
    let mut scenario = ts::begin(admin());
    setup(&mut scenario);
    ts::next_tx(&mut scenario, OTHER);
    let mut registry = take_registry(&scenario);

    // A locked entity can't be unlocked with an empty request a module issued.
    let (mut e, _req) = entity::new(&mut registry, 1, tenant());
    e.complete_request(request::new_for(internal::permit<Other>(), vector[]));
    abort
}
