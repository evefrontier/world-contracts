/// Layout component: one per Creation, at a well-known slot. Groups the
/// Creation's module components into sections and holds the Shell id.
///
/// A section is the ids of the module components that belong to it. The modules
/// themselves stay components on the Creation; this is only the index. A module
/// belongs to at most one section, and a Creation always has at least one
/// section. A Creation is working while it has a Shell id and dark while it
/// has none.
module creation::layout;

use core::{
    admin_service,
    component::{Self, Component},
    entity::Entity,
    request::Request,
    requirement::{Self, Requirement}
};
use std::{internal::Permit, string::{Self, String}};
use sui::{event, vec_map::{Self, VecMap}, vec_set::{Self, VecSet}};

// === Errors ===

#[error(code = 0)]
const EWrongVersion: vector<u8> = b"Layout component version does not match the package version";
#[error(code = 1)]
const EComponentMissing: vector<u8> = b"Layout component is not installed on this entity";
#[error(code = 2)]
const ENoSections: vector<u8> = b"A Creation needs at least one section";
#[error(code = 3)]
const ELengthMismatch: vector<u8> = b"Section ids and module lists differ in length";
#[error(code = 4)]
const ESectionExists: vector<u8> = b"Section id is already in use on this Creation";
#[error(code = 5)]
const ESectionMissing: vector<u8> = b"Section is not on this Creation";
#[error(code = 6)]
const EModuleMissing: vector<u8> = b"Module is not installed on this Creation";
#[error(code = 7)]
const EModuleAssigned: vector<u8> = b"Module already belongs to a section";
#[error(code = 8)]
const EModuleNotInSection: vector<u8> = b"Module does not belong to this section";
#[error(code = 9)]
const EShellPresent: vector<u8> = b"Creation already has a Shell";
#[error(code = 10)]
const EShellMissing: vector<u8> = b"Creation has no Shell";
#[error(code = 11)]
const EModulesInstalled: vector<u8> = b"Section still has modules installed on this Creation";
#[error(code = 12)]
const ELastSection: vector<u8> = b"Cannot remove a Creation's last section";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"layout";

// === Structs ===

public struct Layout has store {
    sections: VecMap<u64, Section>,
    /// Present while the Creation is working, absent while it is dark.
    shell_id: Option<ID>,
}

public struct Section has copy, drop, store {
    /// Component ids of the modules in this section, inventories included.
    module_ids: VecSet<u64>,
}

/// Requirement marker satisfied by the edit handlers.
public struct EditLayout() has drop;

// === Events ===

public struct SectionAdded has copy, drop {
    entity_id: ID,
    section_id: u64,
    module_ids: vector<u64>,
}

public struct SectionRemoved has copy, drop {
    entity_id: ID,
    section_id: u64,
}

public struct LayoutUninstalled has copy, drop {
    entity_id: ID,
}

public struct ModuleAdded has copy, drop {
    entity_id: ID,
    section_id: u64,
    module_id: u64,
}

public struct ModuleRemoved has copy, drop {
    entity_id: ID,
    section_id: u64,
    module_id: u64,
}

public struct ModuleSectionMigrated has copy, drop {
    entity_id: ID,
    from_section_id: u64,
    to_section_id: u64,
    module_id: u64,
}

public struct ShellChanged has copy, drop {
    entity_id: ID,
    shell_id: Option<ID>,
}

// === Public Functions ===

/// Install the Layout component with its first sections, dark. Admin-gated.
/// `module_ids[i]` lists the module components of `section_ids[i]`; each must
/// be installed on the Creation and appear only once.
public fun install(
    entity: &mut Entity,
    section_ids: vector<u64>,
    module_ids: vector<vector<u64>>,
    ctx: &mut TxContext,
): Request {
    assert!(!section_ids.is_empty(), ENoSections);
    assert_installed(entity, &module_ids);
    let mut layout = Layout { sections: vec_map::empty(), shell_id: option::none() };
    layout.add_all(entity.id(), section_ids, module_ids);
    entity.install(
        component_id(),
        option::some(string::utf8(NAME)),
        layout,
        VERSION,
        layout_permit(),
        ctx,
    )
}

/// Add sections. Edit handler, admin-gated. Same rules as `install`.
public fun add_sections(
    entity: &mut Entity,
    req: &mut Request,
    section_ids: vector<u64>,
    module_ids: vector<vector<u64>>,
) {
    assert_installed(entity, &module_ids);
    let entity_id = entity.id();
    edit_mut(entity, req).add_all(entity_id, section_ids, module_ids);
}

/// Remove section `section_id` once none of its modules is installed on the
/// Creation any more. Aborts on the last section. Edit handler, admin-gated.
public fun remove_section(entity: &mut Entity, req: &mut Request, section_id: u64) {
    let entity_id = entity.id();
    let module_ids = section(entity, section_id).module_ids.into_keys();
    module_ids.do_ref!(|id| assert!(!entity.has_component(*id), EModulesInstalled));
    let layout = edit_mut(entity, req);
    assert!(layout.sections.length() > 1, ELastSection);
    layout.sections.remove(&section_id);
    event::emit(SectionRemoved { entity_id, section_id });
}

/// Remove the Layout component, e.g. from a Creation a merge absorbed, before
/// it is deleted. Admin-gated.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(entity.has_component_with_type<Layout>(component_id()), EComponentMissing);
    let (c, req) = entity.uninstall<Layout>(component_id(), layout_permit(), ctx);
    assert!(component::version(&c) == VERSION, EWrongVersion);
    let Layout { sections: _, shell_id: _ } = c.unwrap(layout_permit());
    event::emit(LayoutUninstalled { entity_id: entity.id() });
    req
}

/// Add an installed module to `section_id`. The module must not already belong
/// to a section. Edit handler, admin-gated.
public fun add_module(entity: &mut Entity, req: &mut Request, section_id: u64, module_id: u64) {
    assert_installed(entity, &vector[vector[module_id]]);
    let entity_id = entity.id();
    let layout = edit_mut(entity, req);
    assert!(layout.sections.contains(&section_id), ESectionMissing);
    layout.insert_module(section_id, module_id);
    event::emit(ModuleAdded { entity_id, section_id, module_id });
}

/// Remove `module_id` from `section_id`. The module stays installed. Edit
/// handler, admin-gated.
public fun remove_module(entity: &mut Entity, req: &mut Request, section_id: u64, module_id: u64) {
    let entity_id = entity.id();
    let layout = edit_mut(entity, req);
    assert!(layout.sections.contains(&section_id), ESectionMissing);
    let section = &mut layout.sections[&section_id];
    assert!(section.module_ids.contains(&module_id), EModuleNotInSection);
    section.module_ids.remove(&module_id);
    event::emit(ModuleRemoved { entity_id, section_id, module_id });
}

/// Move `module_id` from `from_section_id` to `to_section_id`. The module stays
/// installed. Edit handler, admin-gated.
public fun migrate_module_section(
    entity: &mut Entity,
    req: &mut Request,
    from_section_id: u64,
    to_section_id: u64,
    module_id: u64,
) {
    let entity_id = entity.id();
    let layout = edit_mut(entity, req);
    assert!(layout.sections.contains(&from_section_id), ESectionMissing);
    assert!(layout.sections.contains(&to_section_id), ESectionMissing);
    let from = &mut layout.sections[&from_section_id];
    assert!(from.module_ids.contains(&module_id), EModuleNotInSection);
    from.module_ids.remove(&module_id);
    layout.sections[&to_section_id].module_ids.insert(module_id);
    event::emit(ModuleSectionMigrated { entity_id, from_section_id, to_section_id, module_id });
}

/// Mark the Creation working with `shell_id`. Edit handler, admin-gated.
public fun set_shell(entity: &mut Entity, req: &mut Request, shell_id: ID) {
    let entity_id = entity.id();
    let layout = edit_mut(entity, req);
    assert!(layout.shell_id.is_none(), EShellPresent);
    layout.shell_id = option::some(shell_id);
    event::emit(ShellChanged { entity_id, shell_id: layout.shell_id });
}

/// Mark the Creation dark. Edit handler, admin-gated.
public fun clear_shell(entity: &mut Entity, req: &mut Request) {
    let entity_id = entity.id();
    let layout = edit_mut(entity, req);
    assert!(layout.shell_id.is_some(), EShellMissing);
    layout.shell_id = option::none();
    event::emit(ShellChanged { entity_id, shell_id: option::none() });
}

/// Build the edit requirement targeting the Layout slot.
public fun edit_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), EditLayout())
}

// === View Functions ===

public fun section_ids(entity: &Entity): vector<u64> {
    borrow(entity).sections.keys()
}

/// Installed modules of `section_id`; ids still listed after a module left are skipped.
public fun section_modules(entity: &Entity, section_id: u64): vector<u64> {
    section(entity, section_id).module_ids.into_keys().filter!(|id| entity.has_component(*id))
}

/// The section `module_id` belongs to, if any. None once the module has left.
public fun section_of(entity: &Entity, module_id: u64): Option<u64> {
    if (!entity.has_component(module_id)) return option::none();
    borrow(entity).find_module(module_id)
}

public fun shell_id(entity: &Entity): Option<ID> {
    borrow(entity).shell_id
}

public fun is_working(entity: &Entity): bool {
    borrow(entity).shell_id.is_some()
}

public fun component_id(): u64 {
    component::id_from_name(NAME)
}

/// Name of the admin action the edit handlers run under.
public fun action_name(): String {
    string::utf8(NAME)
}

public fun section_added_fields(e: &SectionAdded): (ID, u64, vector<u64>) {
    (e.entity_id, e.section_id, e.module_ids)
}

// === Private Functions ===

fun add_all(
    layout: &mut Layout,
    entity_id: ID,
    section_ids: vector<u64>,
    module_ids: vector<vector<u64>>,
) {
    let count = section_ids.length();
    assert!(module_ids.length() == count, ELengthMismatch);
    count.do!(|i| {
        let section_id = section_ids[i];
        assert!(!layout.sections.contains(&section_id), ESectionExists);
        let section = Section { module_ids: vec_set::empty() };
        layout.sections.insert(section_id, section);
        module_ids[i].do_ref!(|module_id| layout.insert_module(section_id, *module_id));
        event::emit(SectionAdded { entity_id, section_id, module_ids: module_ids[i] });
    });
}

fun insert_module(layout: &mut Layout, section_id: u64, module_id: u64) {
    assert!(layout.find_module(module_id).is_none(), EModuleAssigned);
    layout.sections[&section_id].module_ids.insert(module_id);
}

fun find_module(layout: &Layout, module_id: u64): Option<u64> {
    let mut found = option::none();
    layout.sections.length().do!(|i| {
        let (section_id, section) = layout.sections.get_entry_by_idx(i);
        if (section.module_ids.contains(&module_id)) found = option::some(*section_id);
    });
    found
}

/// Abort unless every listed module is a component installed on the Creation.
fun assert_installed(entity: &Entity, module_ids: &vector<vector<u64>>) {
    module_ids.do_ref!(|ids| ids.do_ref!(|id| {
        assert!(*id != component_id() && entity.has_component(*id), EModuleMissing);
    }));
}

/// Borrow the Layout state for an edit: pop the edit requirement and push
/// the admin requirement in its place. Prunes modules no longer installed first.
fun edit_mut(entity: &mut Entity, req: &mut Request): &mut Layout {
    let entity_id = entity.id();
    let stale = stale_modules(entity);
    let c: &mut Component<Layout> = entity.component_mut(req, layout_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    let (_requirement, mut frame) = req.take_next(edit_permit());
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
    let layout = c.inner_mut();
    layout.prune(entity_id, &stale);
    layout
}

/// Listed module ids no longer installed on the Creation, e.g. migrated away.
fun stale_modules(entity: &Entity): vector<u64> {
    let mut stale = vector[];
    let layout = borrow(entity);
    layout.sections.length().do!(|i| {
        let (_, section) = layout.sections.get_entry_by_idx(i);
        section
            .module_ids
            .keys()
            .do_ref!(|id| if (!entity.has_component(*id)) stale.push_back(*id));
    });
    stale
}

fun prune(layout: &mut Layout, entity_id: ID, stale: &vector<u64>) {
    stale.do_ref!(|module_id| {
        let section_id = layout.find_module(*module_id).destroy_some();
        layout.sections[&section_id].module_ids.remove(module_id);
        event::emit(ModuleRemoved { entity_id, section_id, module_id: *module_id });
    });
}

fun borrow(entity: &Entity): &Layout {
    assert!(entity.has_component_with_type<Layout>(component_id()), EComponentMissing);
    let c: &Component<Layout> = entity.component_ref(component_id(), layout_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    c.inner()
}

fun section(entity: &Entity, section_id: u64): Section {
    let layout = borrow(entity);
    assert!(layout.sections.contains(&section_id), ESectionMissing);
    layout.sections[&section_id]
}

fun layout_permit(): Permit<Layout> {
    internal::permit<Layout>()
}

fun edit_permit(): Permit<EditLayout> {
    internal::permit<EditLayout>()
}
