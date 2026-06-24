#[test_only]
module core::admin_service_tests;

use core::{admin_service, request, test_helpers::take_acl};
use sui::test_scenario as ts;

const ADMIN: address = @0xA;
const OTHER: address = @0xB;

fun admin_request(): request::Request {
    request::new_for_testing(option::none(), vector[admin_service::admin_requirement()])
}

fun sponsor_request(): request::Request {
    request::new_for_testing(option::none(), vector[admin_service::sponsor_requirement()])
}

// === Init ===

#[test]
fun init_seeds_deployer_as_admin() {
    let mut scenario = ts::begin(ADMIN);
    admin_service::init_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, ADMIN);
    let acl = take_acl(&scenario);
    assert!(acl.is_admin(ADMIN));
    assert!(!acl.is_admin(OTHER));
    assert!(!acl.is_sponsor(ADMIN));

    ts::return_shared(acl);
    scenario.end();
}

// === verify_admin ===

#[test]
fun verify_admin_passes_for_admin() {
    let mut scenario = ts::begin(ADMIN);
    admin_service::init_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, ADMIN);
    let acl = take_acl(&scenario);
    let mut req = admin_request();
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());

    req.destroy();
    ts::return_shared(acl);
    scenario.end();
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun verify_admin_aborts_for_non_admin() {
    let mut scenario = ts::begin(ADMIN);
    admin_service::init_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, OTHER);
    let acl = take_acl(&scenario);
    let mut req = admin_request();
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());

    abort
}

// === verify_sponsor ===

#[test]
fun verify_sponsor_passes_for_sponsor() {
    let mut scenario = ts::begin(ADMIN);
    admin_service::init_for_testing(scenario.ctx());

    // Admin adds OTHER as a sponsor.
    ts::next_tx(&mut scenario, ADMIN);
    let mut acl = take_acl(&scenario);
    admin_service::add_sponsors(&mut acl, vector[OTHER], scenario.ctx());

    // OTHER (the sponsor; unsponsored tx, so sender fallback) satisfies the sponsor requirement.
    ts::next_tx(&mut scenario, OTHER);
    let mut sreq = sponsor_request();
    admin_service::verify_sponsor(&mut sreq, &acl, scenario.ctx());

    sreq.destroy();
    ts::return_shared(acl);
    scenario.end();
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedSponsor)]
fun verify_sponsor_aborts_for_non_sponsor() {
    let mut scenario = ts::begin(ADMIN);
    admin_service::init_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, OTHER);
    let acl = take_acl(&scenario);
    let mut req = sponsor_request();
    admin_service::verify_sponsor(&mut req, &acl, scenario.ctx());

    abort
}

// === Mutators are self-gated ===

#[test]
fun add_admins_batch_then_verify() {
    let mut scenario = ts::begin(ADMIN);
    admin_service::init_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, ADMIN);
    let mut acl = take_acl(&scenario);
    admin_service::add_admins(&mut acl, vector[OTHER, @0xC], scenario.ctx());

    assert!(acl.is_admin(OTHER));
    assert!(acl.is_admin(@0xC));

    ts::return_shared(acl);
    scenario.end();
}

#[test]
fun add_admins_is_idempotent() {
    let mut scenario = ts::begin(ADMIN);
    admin_service::init_for_testing(scenario.ctx());

    // Re-add the deployer (already admin #0) plus a new address; must not abort.
    ts::next_tx(&mut scenario, ADMIN);
    let mut acl = take_acl(&scenario);
    admin_service::add_admins(&mut acl, vector[ADMIN, OTHER], scenario.ctx());
    admin_service::add_admins(&mut acl, vector[OTHER], scenario.ctx());

    assert!(acl.is_admin(ADMIN));
    assert!(acl.is_admin(OTHER));

    ts::return_shared(acl);
    scenario.end();
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun add_admins_aborts_for_non_admin() {
    let mut scenario = ts::begin(ADMIN);
    admin_service::init_for_testing(scenario.ctx());

    ts::next_tx(&mut scenario, OTHER);
    let mut acl = take_acl(&scenario);
    admin_service::add_admins(&mut acl, vector[OTHER], scenario.ctx());

    abort
}
