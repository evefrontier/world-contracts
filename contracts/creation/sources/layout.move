/// Layout component: one per Creation, at a well-known slot. Groups the
/// Creation's module components into sections and holds the Shell.
///
/// A section is the ids of the module components that belong to it. The modules
/// themselves stay components on the Creation; this is only the index. A module
/// belongs to at most one section, and a Creation always has at least one
/// section. Sections live in a `Table` with a module -> section index beside it,
/// so an edit touches only the sections it changes.
///
/// The Shell sits in a Command Module, a module listed in a section. A Creation
/// has a Shell until it is cleared or its Command Module leaves, and is dark
/// without one.
module creation::layout;

use core::{
    admin_service,
    component::{Self, Component},
    entity::Entity,
    request::Request,
    requirement::{Self, Requirement}
};
use std::{internal::Permit, string::{Self, String}};
use sui::{event, table::{Self, Table}, vec_set::{Self, VecSet}};

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
const EShellPresent: vector<u8> = b"Creation has a Shell";
#[error(code = 10)]
const EShellMissing: vector<u8> = b"Creation has no Shell";
#[error(code = 11)]
const EModulesInstalled: vector<u8> = b"Section still has modules installed on this Creation";
#[error(code = 12)]
const ELastSection: vector<u8> = b"Cannot remove a Creation's last section";
#[error(code = 13)]
const EModuleUnassigned: vector<u8> = b"Module does not belong to any section";

// === Constants ===

const VERSION: u64 = 1;
const NAME: vector<u8> = b"layout";

// === Structs ===

public struct Layout has store {
    /// Ids of `sections`, in insertion order, for listing and teardown.
    section_ids: VecSet<u64>,
    sections: Table<u64, Section>,
    /// Section of every listed module.
    module_to_section: Table<u64, u64>,
    /// Present while a Shell is aboard, absent while the Creation is dark.
    shell: Option<Shell>,
}

public struct Section has copy, drop, store {
    /// Component ids of the modules in this section, inventories included.
    module_ids: VecSet<u64>,
}

public struct Shell has copy, drop, store {
    shell_id: ID,
    /// Component id of the module the Shell sits in.
    command_module_id: u64,
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
    let mut layout = Layout {
        section_ids: vec_set::empty(),
        sections: table::new(ctx),
        module_to_section: table::new(ctx),
        shell: option::none(),
    };
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
/// Creation any more, clearing the Shell if its Command Module was there.
/// Aborts on the last section. Edit handler, admin-gated.
public fun remove_section(entity: &mut Entity, req: &mut Request, section_id: u64) {
    let entity_id = entity.id();
    let module_ids = *section(entity, section_id).module_ids.keys();
    module_ids.do_ref!(|id| assert!(!entity.has_component(*id), EModulesInstalled));
    let layout = edit_mut(entity, req);
    assert!(layout.section_ids.length() > 1, ELastSection);
    let module_ids = *layout.sections[section_id].module_ids.keys();
    module_ids.do!(|module_id| layout.unlist(entity_id, module_id));
    layout.section_ids.remove(&section_id);
    layout.sections.remove(section_id);
    event::emit(SectionRemoved { entity_id, section_id });
}

/// Remove the Layout component, e.g. from a Creation a merge absorbed, before
/// it is deleted. Aborts while a Shell is recorded: clear it first. Admin-gated.
public fun uninstall(entity: &mut Entity, ctx: &mut TxContext): Request {
    assert!(borrow(entity).shell.is_none(), EShellPresent);
    let (c, req) = entity.uninstall<Layout>(component_id(), layout_permit(), ctx);
    let Layout {
        section_ids,
        mut sections,
        mut module_to_section,
        shell: _,
    } = c.unwrap(layout_permit());
    section_ids.into_keys().do!(|section_id| {
        let Section { module_ids } = sections.remove(section_id);
        module_ids.into_keys().do!(|module_id| { module_to_section.remove(module_id); });
    });
    sections.destroy_empty();
    module_to_section.destroy_empty();
    event::emit(LayoutUninstalled { entity_id: entity.id() });
    req
}

/// Add an installed module to `section_id`. The module must not already belong
/// to a section. Edit handler, admin-gated.
public fun add_module(entity: &mut Entity, req: &mut Request, section_id: u64, module_id: u64) {
    assert_installed(entity, &vector[vector[module_id]]);
    let entity_id = entity.id();
    let layout = edit_mut(entity, req);
    assert!(layout.sections.contains(section_id), ESectionMissing);
    layout.insert_module(section_id, module_id);
    event::emit(ModuleAdded { entity_id, section_id, module_id });
}

/// Remove `module_id` from `section_id`, clearing the Shell if it sat there.
/// The module stays installed. Edit handler, admin-gated.
public fun remove_module(entity: &mut Entity, req: &mut Request, section_id: u64, module_id: u64) {
    let entity_id = entity.id();
    let layout = edit_mut(entity, req);
    assert!(layout.sections.contains(section_id), ESectionMissing);
    assert!(layout.sections[section_id].module_ids.contains(&module_id), EModuleNotInSection);
    layout.unlist(entity_id, module_id);
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
    assert!(layout.sections.contains(from_section_id), ESectionMissing);
    assert!(layout.sections.contains(to_section_id), ESectionMissing);
    let from = &mut layout.sections[from_section_id];
    assert!(from.module_ids.contains(&module_id), EModuleNotInSection);
    from.module_ids.remove(&module_id);
    layout.sections[to_section_id].module_ids.insert(module_id);
    *&mut layout.module_to_section[module_id] = to_section_id;
    event::emit(ModuleSectionMigrated { entity_id, from_section_id, to_section_id, module_id });
}

/// Seat Shell `shell_id` in `command_module_id`, an installed module listed in
/// a section. Edit handler, admin-gated.
public fun set_shell(entity: &mut Entity, req: &mut Request, shell_id: ID, command_module_id: u64) {
    assert_installed(entity, &vector[vector[command_module_id]]);
    let entity_id = entity.id();
    let layout = edit_mut(entity, req);
    assert!(layout.shell.is_none(), EShellPresent);
    assert!(layout.module_to_section.contains(command_module_id), EModuleUnassigned);
    layout.shell = option::some(Shell { shell_id, command_module_id });
    event::emit(ShellChanged { entity_id, shell_id: option::some(shell_id) });
}

/// Clear the Shell, marking the Creation dark. Edit handler, admin-gated.
public fun clear_shell(entity: &mut Entity, req: &mut Request) {
    assert!(borrow(entity).shell.is_some(), EShellMissing);
    let entity_id = entity.id();
    let layout = edit_mut(entity, req);
    // `edit_mut` has already cleared it if its Command Module left.
    if (layout.shell.is_some()) layout.drop_shell(entity_id);
}

/// Build the edit requirement targeting the Layout slot.
public fun edit_requirement(): Requirement {
    requirement::from_config(option::some(component_id()), EditLayout())
}

// === View Functions ===

public fun section_ids(entity: &Entity): vector<u64> {
    *borrow(entity).section_ids.keys()
}

/// Installed modules of `section_id`; ids still listed after a module left are skipped.
public fun section_modules(entity: &Entity, section_id: u64): vector<u64> {
    let module_ids = *section(entity, section_id).module_ids.keys();
    module_ids.filter!(|id| entity.has_component(*id))
}

/// The section `module_id` belongs to, if any. None once the module has left.
public fun section_of(entity: &Entity, module_id: u64): Option<u64> {
    if (!entity.has_component(module_id)) return option::none();
    let layout = borrow(entity);
    if (!layout.module_to_section.contains(module_id)) return option::none();
    option::some(layout.module_to_section[module_id])
}

public fun shell_id(entity: &Entity): Option<ID> {
    shell(entity).map!(|s| s.shell_id)
}

public fun command_module_id(entity: &Entity): Option<u64> {
    shell(entity).map!(|s| s.command_module_id)
}

public fun has_shell(entity: &Entity): bool {
    shell(entity).is_some()
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
        assert!(!layout.sections.contains(section_id), ESectionExists);
        layout.section_ids.insert(section_id);
        layout.sections.add(section_id, Section { module_ids: vec_set::empty() });
        module_ids[i].do_ref!(|module_id| layout.insert_module(section_id, *module_id));
        event::emit(SectionAdded { entity_id, section_id, module_ids: module_ids[i] });
    });
}

fun insert_module(layout: &mut Layout, section_id: u64, module_id: u64) {
    assert!(!layout.module_to_section.contains(module_id), EModuleAssigned);
    layout.module_to_section.add(module_id, section_id);
    layout.sections[section_id].module_ids.insert(module_id);
}

/// Drop listed `module_id` from its section, and the Shell with it if this is
/// its Command Module.
fun unlist(layout: &mut Layout, entity_id: ID, module_id: u64) {
    let section_id = layout.module_to_section.remove(module_id);
    layout.sections[section_id].module_ids.remove(&module_id);
    event::emit(ModuleRemoved { entity_id, section_id, module_id });
    if (layout.shell.is_some_and!(|s| s.command_module_id == module_id)) {
        layout.drop_shell(entity_id);
    }
}

fun drop_shell(layout: &mut Layout, entity_id: ID) {
    layout.shell = option::none();
    event::emit(ShellChanged { entity_id, shell_id: option::none() });
}

/// Abort unless every listed module is a component installed on the Creation.
fun assert_installed(entity: &Entity, module_ids: &vector<vector<u64>>) {
    module_ids.do_ref!(|ids| ids.do_ref!(|id| {
        assert!(*id != component_id() && entity.has_component(*id), EModuleMissing);
    }));
}

/// Borrow the Layout state for an edit: pop the edit requirement and push
/// the admin requirement in its place. Prunes the Shell's Command Module first
/// if it is no longer installed.
fun edit_mut(entity: &mut Entity, req: &mut Request): &mut Layout {
    let entity_id = entity.id();
    let departed = departed_command_module(entity);
    let c: &mut Component<Layout> = entity.component_mut(req, layout_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    let (_requirement, mut frame) = req.take_next(edit_permit());
    frame.require(admin_service::admin_requirement());
    req.enqueue(frame);
    let layout = c.inner_mut();
    departed.do!(|module_id| layout.unlist(entity_id, module_id));
    layout
}

/// The Shell's Command Module, if it is no longer installed on the Creation.
fun departed_command_module(entity: &Entity): Option<u64> {
    borrow(entity).shell.map!(|s| s.command_module_id).filter!(|id| !entity.has_component(*id))
}

/// The Shell, unless its Command Module has left the Creation.
fun shell(entity: &Entity): Option<Shell> {
    borrow(entity).shell.filter!(|s| entity.has_component(s.command_module_id))
}

fun borrow(entity: &Entity): &Layout {
    assert!(entity.has_component_with_type<Layout>(component_id()), EComponentMissing);
    let c: &Component<Layout> = entity.component_ref(component_id(), layout_permit());
    assert!(component::version(c) == VERSION, EWrongVersion);
    c.inner()
}

fun section(entity: &Entity, section_id: u64): &Section {
    let layout = borrow(entity);
    assert!(layout.sections.contains(section_id), ESectionMissing);
    &layout.sections[section_id]
}

fun layout_permit(): Permit<Layout> {
    internal::permit<Layout>()
}

fun edit_permit(): Permit<EditLayout> {
    internal::permit<EditLayout>()
}
