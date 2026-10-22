#[test_only]
module creation::layout_tests;

use core::{
    access_cap::{Self, AccessCap},
    action,
    admin_service::{Self, AdminACL},
    entity::Entity,
    test_helpers::{claim, setup, take_acl, take_registry}
};
use creation::layout::{Self, SectionAdded, SectionRemoved};
use std::string;
use sui::{event, test_scenario as ts};

const ADMIN: address = @0xA;
const OWNER: address = @0xB;

/// Stand-in for a module component. Its package is this test module.
public struct Dummy has store {}

fun install_dummy(e: &mut Entity, acl: &AdminACL, id: u64, ctx: &mut TxContext) {
    let mut req = e.install(id, option::none(), Dummy {}, 1, internal::permit<Dummy>(), ctx);
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
}

/// Enable the admin `layout` action that edit handlers run under.
fun enable_layout_action(e: &mut Entity, acl: &AdminACL, ctx: &mut TxContext) {
    let act = action::new(vector[layout::edit_requirement()]);
    let mut req = e.enable_admin_action(layout::action_name(), act, ctx);
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
}

/// Shared creation with modules 1..=5 installed, section 10 (modules 1, 2) and
/// section 20 (module 3). Modules 4 and 5 are in no section. Returns its id.
fun deploy(scenario: &mut ts::Scenario): ID {
    ts::next_tx(scenario, ADMIN);
    let mut registry = take_registry(scenario);
    let acl = take_acl(scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    5u64.do!(|i| install_dummy(&mut e, &acl, i + 1, scenario.ctx()));

    let mut req = layout::install(
        &mut e,
        vector[10, 20],
        vector[vector[1, 2], vector[3]],
        scenario.ctx(),
    );
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    enable_layout_action(&mut e, &acl, scenario.ctx());

    let id = e.id();
    e.share();
    ts::return_shared(registry);
    ts::return_shared(acl);
    id
}

/// Run one admin edit on the shared creation: interact, `edit`, verify admin, complete.
macro fun admin_edit(
    $scenario: &mut ts::Scenario,
    $sender: address,
    $edit: |&mut Entity, &mut core::request::Request|,
) {
    let scenario = $scenario;
    ts::next_tx(scenario, $sender);
    let mut e = ts::take_shared<Entity>(scenario);
    let acl = take_acl(scenario);
    let mut req = e.interact(layout::action_name(), scenario.ctx());
    $edit(&mut e, &mut req);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    e.complete_request(req);
    ts::return_shared(e);
    ts::return_shared(acl);
}

// === install ===

#[test]
fun install_records_sections_dark_and_unowned() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let e = ts::take_shared<Entity>(&scenario);
        assert!(layout::section_ids(&e) == vector[10, 20]);
        assert!(layout::section_modules(&e, 10) == vector[1, 2]);
        assert!(layout::section_modules(&e, 20) == vector[3]);
        assert!(layout::section_of(&e, 3) == option::some(20));
        assert!(layout::section_of(&e, 4).is_none());
        assert!(layout::shell_id(&e).is_none());
        assert!(!layout::is_working(&e));
        assert!(e.access_cap_id().is_none());
        ts::return_shared(e);
    };

    scenario.end();
}

#[test]
fun install_emits_section_added_per_section() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    let added = event::events_by_type<SectionAdded>();
    assert!(added.length() == 2);
    let (_, section_id, module_ids) = added[1].section_added_fields();
    assert!(section_id == 20 && module_ids == vector[3]);

    scenario.end();
}

#[test, expected_failure(abort_code = layout::ENoSections)]
fun install_without_sections_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    let _req = layout::install(&mut e, vector[], vector[], scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = layout::ELengthMismatch)]
fun install_with_mismatched_lengths_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    let _req = layout::install(&mut e, vector[10, 20], vector[], scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = layout::EModuleMissing)]
fun install_with_uninstalled_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    let _req = layout::install(&mut e, vector[10], vector[vector[7]], scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = layout::EModuleAssigned)]
fun install_with_module_in_two_sections_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());
    install_dummy(&mut e, &acl, 1, scenario.ctx());

    let _req = layout::install(
        &mut e,
        vector[10, 20],
        vector[vector[1], vector[1]],
        scenario.ctx(),
    );

    abort
}

#[test, expected_failure(abort_code = layout::ESectionExists)]
fun install_with_duplicate_section_id_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut e = claim(&mut registry, &acl, 1, scenario.ctx());

    let _req = layout::install(
        &mut e,
        vector[10, 10],
        vector[vector[], vector[]],
        scenario.ctx(),
    );

    abort
}

// === add_sections ===

#[test]
fun add_sections_appends() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| {
        layout::add_sections(e, req, vector[30], vector[vector[4, 5]]);
    });

    ts::next_tx(&mut scenario, ADMIN);
    {
        let e = ts::take_shared<Entity>(&scenario);
        assert!(layout::section_ids(&e) == vector[10, 20, 30]);
        assert!(layout::section_modules(&e, 30) == vector[4, 5]);
        ts::return_shared(e);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun add_sections_by_non_admin_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, OWNER, |e, req| {
        layout::add_sections(e, req, vector[30], vector[vector[4]]);
    });

    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun owner_action_with_edit_requirement_still_needs_admin() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let creation_id = deploy(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut e = ts::take_shared_by_id<Entity>(&scenario, creation_id);
        let acl = take_acl(&scenario);
        let mut req = e.mint_access(OWNER, false, scenario.ctx());
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);
        ts::return_shared(e);
        ts::return_shared(acl);
    };

    // The owner exposes their own action carrying the edit requirement.
    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared_by_id<Entity>(&scenario, creation_id);
    let cap = ts::take_from_sender<AccessCap>(&scenario);
    let act = action::new(vector[access_cap::owner_requirement(), layout::edit_requirement()]);
    let mut req = e.enable_action(string::utf8(b"my_edit"), act, scenario.ctx());
    e.verify_owner(&mut req, &cap);
    e.complete_request(req);

    let acl = take_acl(&scenario);
    let mut req = e.interact(string::utf8(b"my_edit"), scenario.ctx());
    e.verify_owner(&mut req, &cap);
    layout::add_sections(&mut e, &mut req, vector[30], vector[vector[4]]);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());

    abort
}

#[test, expected_failure(abort_code = layout::ESectionExists)]
fun add_existing_section_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| {
        layout::add_sections(e, req, vector[10], vector[vector[4]]);
    });

    abort
}

#[test, expected_failure(abort_code = layout::EModuleAssigned)]
fun add_section_with_assigned_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| {
        layout::add_sections(e, req, vector[30], vector[vector[1]]);
    });

    abort
}

// === add / remove ===

#[test]
fun add_and_remove_module() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::add_module(e, req, 20, 4));
    admin_edit!(&mut scenario, ADMIN, |e, req| layout::remove_module(e, req, 10, 1));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let e = ts::take_shared<Entity>(&scenario);
        assert!(layout::section_modules(&e, 20) == vector[3, 4]);
        assert!(layout::section_modules(&e, 10) == vector[2]);
        assert!(layout::section_of(&e, 1).is_none());
        ts::return_shared(e);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = layout::ESectionMissing)]
fun add_to_unknown_section_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::add_module(e, req, 99, 4));

    abort
}

#[test, expected_failure(abort_code = layout::EModuleAssigned)]
fun add_already_added_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::add_module(e, req, 20, 1));

    abort
}

#[test, expected_failure(abort_code = layout::EModuleMissing)]
fun add_uninstalled_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::add_module(e, req, 20, 7));

    abort
}

#[test, expected_failure(abort_code = layout::EModuleNotInSection)]
fun remove_module_from_other_section_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::remove_module(e, req, 20, 1));

    abort
}

// === shell ===

#[test]
fun claim_then_release() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);
    let shell = object::id_from_address(@0x5E11);

    // Claim: mint the owner and set the Shell in one transaction.
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut e = ts::take_shared<Entity>(&scenario);
        let acl = take_acl(&scenario);
        let mut req = e.mint_access(OWNER, false, scenario.ctx());
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);
        let mut req = e.interact(layout::action_name(), scenario.ctx());
        layout::set_shell(&mut e, &mut req, shell);
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        e.complete_request(req);
        ts::return_shared(e);
        ts::return_shared(acl);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let e = ts::take_shared<Entity>(&scenario);
        assert!(layout::shell_id(&e) == option::some(shell));
        assert!(layout::is_working(&e));
        assert!(e.access_cap_id().is_some());
        ts::return_shared(e);
    };

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::clear_shell(e, req));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let e = ts::take_shared<Entity>(&scenario);
        assert!(!layout::is_working(&e));
        assert!(e.access_cap_id().is_some());
        ts::return_shared(e);
    };

    scenario.end();
}

#[test, expected_failure(abort_code = layout::EShellPresent)]
fun set_shell_on_working_creation_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| {
        layout::set_shell(e, req, object::id_from_address(@0x1));
    });
    admin_edit!(&mut scenario, ADMIN, |e, req| {
        layout::set_shell(e, req, object::id_from_address(@0x2));
    });

    abort
}

#[test, expected_failure(abort_code = layout::EShellMissing)]
fun clear_shell_on_dark_creation_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::clear_shell(e, req));

    abort
}

// === remove_section / uninstall ===

fun uninstall_dummy(e: &mut Entity, acl: &AdminACL, id: u64, ctx: &mut TxContext) {
    let (c, mut req) = e.uninstall<Dummy>(id, internal::permit<Dummy>(), ctx);
    let Dummy {} = c.unwrap(internal::permit<Dummy>());
    admin_service::verify_admin(&mut req, acl, ctx);
    e.complete_request(req);
}

/// ADMIN uninstalls modules `ids` from the shared creation.
fun uninstall_dummies(scenario: &mut ts::Scenario, ids: vector<u64>) {
    ts::next_tx(scenario, ADMIN);
    let mut e = ts::take_shared<Entity>(scenario);
    let acl = take_acl(scenario);
    ids.do!(|id| uninstall_dummy(&mut e, &acl, id, scenario.ctx()));
    ts::return_shared(e);
    ts::return_shared(acl);
}

#[test]
fun remove_section_after_its_modules_leave() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);
    uninstall_dummies(&mut scenario, vector[1, 2]);

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::remove_section(e, req, 10));

    let removed = event::events_by_type<SectionRemoved>();
    assert!(removed.length() == 1);
    ts::next_tx(&mut scenario, ADMIN);
    let e = ts::take_shared<Entity>(&scenario);
    assert!(layout::section_ids(&e) == vector[20]);
    ts::return_shared(e);
    scenario.end();
}

#[test, expected_failure(abort_code = layout::EModulesInstalled)]
fun remove_section_with_installed_module_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);
    uninstall_dummies(&mut scenario, vector[1]);

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::remove_section(e, req, 10));

    abort
}

#[test, expected_failure(abort_code = layout::ELastSection)]
fun remove_last_section_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);
    uninstall_dummies(&mut scenario, vector[1, 2, 3]);
    admin_edit!(&mut scenario, ADMIN, |e, req| layout::remove_section(e, req, 10));

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::remove_section(e, req, 20));

    abort
}

#[test, expected_failure(abort_code = layout::ESectionMissing)]
fun remove_unknown_section_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    admin_edit!(&mut scenario, ADMIN, |e, req| layout::remove_section(e, req, 99));

    abort
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun remove_section_by_non_admin_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);
    uninstall_dummies(&mut scenario, vector[1, 2]);

    admin_edit!(&mut scenario, OWNER, |e, req| layout::remove_section(e, req, 10));

    abort
}

/// Detach section 10 into a new creation in one transaction: its modules leave
/// the source, the section is removed there, and the new creation is shared
/// only once its Layout holds the section.
#[test]
fun detach_section_into_new_creation() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let source_id = deploy(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let target_id;
    {
        let mut source = ts::take_shared_by_id<Entity>(&scenario, source_id);
        let mut registry = take_registry(&scenario);
        let acl = take_acl(&scenario);
        uninstall_dummy(&mut source, &acl, 1, scenario.ctx());
        uninstall_dummy(&mut source, &acl, 2, scenario.ctx());
        let mut req = source.interact(layout::action_name(), scenario.ctx());
        layout::remove_section(&mut source, &mut req, 10);
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        source.complete_request(req);

        let mut target = claim(&mut registry, &acl, 2, scenario.ctx());
        install_dummy(&mut target, &acl, 1, scenario.ctx());
        install_dummy(&mut target, &acl, 2, scenario.ctx());
        let mut req = layout::install(
            &mut target,
            vector[10],
            vector[vector[1, 2]],
            scenario.ctx(),
        );
        admin_service::verify_admin(&mut req, &acl, scenario.ctx());
        target.complete_request(req);
        enable_layout_action(&mut target, &acl, scenario.ctx());
        target_id = target.id();
        target.share();

        ts::return_shared(source);
        ts::return_shared(registry);
        ts::return_shared(acl);
    };

    ts::next_tx(&mut scenario, ADMIN);
    let source = ts::take_shared_by_id<Entity>(&scenario, source_id);
    let target = ts::take_shared_by_id<Entity>(&scenario, target_id);
    assert!(layout::section_ids(&source) == vector[20]);
    assert!(layout::section_ids(&target) == vector[10]);
    assert!(layout::section_modules(&target, 10) == vector[1, 2]);
    assert!(!layout::is_working(&target) && target.access_cap_id().is_none());
    ts::return_shared(source);
    ts::return_shared(target);
    scenario.end();
}

/// Merge creation `absorbed` (section 30: modules 6, 7) into the deployed one in
/// one transaction: its modules move over, the survivor gains section 30, and
/// `absorbed` is cleaned up and deleted.
#[test]
fun merge_absorbs_sections_and_deletes_the_other_creation() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let survivor_id = deploy(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    let mut registry = take_registry(&scenario);
    let acl = take_acl(&scenario);
    let mut absorbed = claim(&mut registry, &acl, 2, scenario.ctx());
    install_dummy(&mut absorbed, &acl, 6, scenario.ctx());
    install_dummy(&mut absorbed, &acl, 7, scenario.ctx());
    let mut req = layout::install(&mut absorbed, vector[30], vector[vector[6, 7]], scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    absorbed.complete_request(req);

    let mut survivor = ts::take_shared_by_id<Entity>(&scenario, survivor_id);
    uninstall_dummy(&mut absorbed, &acl, 6, scenario.ctx());
    uninstall_dummy(&mut absorbed, &acl, 7, scenario.ctx());
    install_dummy(&mut survivor, &acl, 6, scenario.ctx());
    install_dummy(&mut survivor, &acl, 7, scenario.ctx());
    let mut req = survivor.interact(layout::action_name(), scenario.ctx());
    layout::add_sections(&mut survivor, &mut req, vector[30], vector[vector[6, 7]]);
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    survivor.complete_request(req);

    let mut req = layout::uninstall(&mut absorbed, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    absorbed.complete_request(req);
    let (mut req, ticket) = absorbed.request_delete();
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());
    absorbed.delete(req, ticket);

    assert!(layout::section_ids(&survivor) == vector[10, 20, 30]);
    assert!(layout::section_modules(&survivor, 30) == vector[6, 7]);
    ts::return_shared(survivor);
    ts::return_shared(registry);
    ts::return_shared(acl);
    scenario.end();
}

#[test, expected_failure(abort_code = admin_service::EUnauthorizedAdmin)]
fun uninstall_by_non_admin_aborts() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    deploy(&mut scenario);

    ts::next_tx(&mut scenario, OWNER);
    let mut e = ts::take_shared<Entity>(&scenario);
    let acl = take_acl(&scenario);
    let mut req = layout::uninstall(&mut e, scenario.ctx());
    admin_service::verify_admin(&mut req, &acl, scenario.ctx());

    abort
}
