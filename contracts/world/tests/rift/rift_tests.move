#[test_only]
module world::rift_tests;

use std::{string::utf8, unit_test::assert_eq};
use sui::test_scenario as ts;
use world::{
    access::{Self, AdminACL},
    location::{Self, LocationRegistry},
    object_registry::ObjectRegistry,
    rift::{Self, Rift},
    test_helpers::{Self, governor, admin, tenant}
};

const LOCATION_HASH: vector<u8> =
    x"7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b7a8f3b2e9c4d1a6f5e8b2d9c3f7a1e5b";
const INVALID_HASH: vector<u8> = x"deadbeef";
const RIFT_ITEM_ID: u64 = 9001;

fun setup(ts: &mut ts::Scenario) {
    test_helpers::setup_world(ts);
}

fun spawn_and_share_rift(ts: &mut ts::Scenario, item_id: u64): ID {
    ts::next_tx(ts, admin());
    let rift_id = {
        let mut registry = ts::take_shared<ObjectRegistry>(ts);
        let admin_acl = ts::take_shared<AdminACL>(ts);
        let rift = rift::spawn(
            &mut registry,
            &admin_acl,
            item_id,
            tenant(),
            LOCATION_HASH,
            ts.ctx(),
        );
        let rift_id = object::id(&rift);
        rift::share_rift(rift, &admin_acl, ts.ctx());
        ts::return_shared(admin_acl);
        ts::return_shared(registry);
        rift_id
    };
    rift_id
}

#[test]
fun test_spawn_and_share_rift() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let rift_id = spawn_and_share_rift(&mut ts, RIFT_ITEM_ID);

    ts::next_tx(&mut ts, admin());
    {
        let registry = ts::take_shared<ObjectRegistry>(&ts);
        assert!(registry.object_exists(test_helpers::in_game_id(RIFT_ITEM_ID)), 0);
        ts::return_shared(registry);
    };

    ts::next_tx(&mut ts, admin());
    {
        let rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        assert_eq!(rift::id(&rift), rift_id);
        assert_eq!(rift::location_hash(&rift), LOCATION_HASH);
        ts::return_shared(rift);
    };

    ts::end(ts);
}

#[test]
fun test_broadcast_location() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let rift_id = spawn_and_share_rift(&mut ts, RIFT_ITEM_ID);

    let solarsystem: u64 = 42;
    let x = utf8(b"100");
    let y = utf8(b"200");
    let z = utf8(b"300");

    ts::next_tx(&mut ts, admin());
    {
        let rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        let mut location_registry = ts::take_shared<LocationRegistry>(&ts);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        rift::broadcast_location(
            &rift,
            &mut location_registry,
            &admin_acl,
            solarsystem,
            x,
            y,
            z,
            ts.ctx(),
        );
        ts::return_shared(admin_acl);
        ts::return_shared(location_registry);
        ts::return_shared(rift);
    };

    ts::next_tx(&mut ts, admin());
    {
        let location_registry = ts::take_shared<LocationRegistry>(&ts);
        let coords = location::get_location(&location_registry, rift_id);
        assert!(option::is_some(&coords), 0);
        let coords_ref = option::borrow(&coords);
        assert_eq!(location::solarsystem(coords_ref), solarsystem);
        assert_eq!(location::x(coords_ref), x);
        assert_eq!(location::y(coords_ref), y);
        assert_eq!(location::z(coords_ref), z);
        ts::return_shared(location_registry);
    };

    ts::end(ts);
}

#[test]
fun test_despawn_rift() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let rift_id = spawn_and_share_rift(&mut ts, RIFT_ITEM_ID);

    ts::next_tx(&mut ts, admin());
    {
        let rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
        let admin_acl = ts::take_shared<AdminACL>(&ts);
        rift::despawn(rift, &admin_acl, ts.ctx());
        ts::return_shared(admin_acl);
    };

    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = rift::ERiftAlreadyExists)]
fun test_spawn_duplicate_item_id() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    spawn_and_share_rift(&mut ts, RIFT_ITEM_ID);

    ts::next_tx(&mut ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&ts);
    let admin_acl = ts::take_shared<AdminACL>(&ts);
    let rift = rift::spawn(
        &mut registry,
        &admin_acl,
        RIFT_ITEM_ID,
        tenant(),
        LOCATION_HASH,
        ts.ctx(),
    );
    rift::share_rift(rift, &admin_acl, ts.ctx());

    ts::return_shared(admin_acl);
    ts::return_shared(registry);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = location::EInvalidHashLength)]
fun test_spawn_invalid_hash_length() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    ts::next_tx(&mut ts, admin());
    let mut registry = ts::take_shared<ObjectRegistry>(&ts);
    let admin_acl = ts::take_shared<AdminACL>(&ts);
    let rift = rift::spawn(
        &mut registry,
        &admin_acl,
        RIFT_ITEM_ID,
        tenant(),
        INVALID_HASH,
        ts.ctx(),
    );
    rift::share_rift(rift, &admin_acl, ts.ctx());

    ts::return_shared(admin_acl);
    ts::return_shared(registry);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = access::EUnauthorizedSponsor)]
fun test_spawn_unauthorized_sponsor() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    ts::next_tx(&mut ts, @0xF);
    let mut registry = ts::take_shared<ObjectRegistry>(&ts);
    let admin_acl = ts::take_shared<AdminACL>(&ts);
    let rift = rift::spawn(
        &mut registry,
        &admin_acl,
        RIFT_ITEM_ID,
        tenant(),
        LOCATION_HASH,
        ts.ctx(),
    );
    rift::share_rift(rift, &admin_acl, ts.ctx());

    ts::return_shared(admin_acl);
    ts::return_shared(registry);
    ts::end(ts);
}

#[test]
#[expected_failure(abort_code = access::EUnauthorizedSponsor)]
fun test_broadcast_location_unauthorized_sponsor() {
    let mut ts = ts::begin(governor());
    setup(&mut ts);

    let rift_id = spawn_and_share_rift(&mut ts, RIFT_ITEM_ID);

    ts::next_tx(&mut ts, @0xF);
    let rift = ts::take_shared_by_id<Rift>(&ts, rift_id);
    let mut location_registry = ts::take_shared<LocationRegistry>(&ts);
    let admin_acl = ts::take_shared<AdminACL>(&ts);
    rift::broadcast_location(
        &rift,
        &mut location_registry,
        &admin_acl,
        42,
        utf8(b"100"),
        utf8(b"200"),
        utf8(b"300"),
        ts.ctx(),
    );

    ts::return_shared(admin_acl);
    ts::return_shared(location_registry);
    ts::return_shared(rift);
    ts::end(ts);
}
