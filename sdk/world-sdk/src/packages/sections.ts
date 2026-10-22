import type { Transaction, TransactionArgument } from '@mysten/sui/transactions'
import type { WorldConfig } from '../config/types.js'
import {
  completeRequest,
  deleteEntity,
  type EntityNewArgs,
  entityNew,
  shareEntity,
  verifyAdmin,
} from './core.js'
import {
  type InstallGenericModuleArgs,
  installGenericModule,
  migrateGenericModule,
  uninstallGenericModule,
} from './generic-module.js'
import {
  type InstallInventoryArgs,
  installInventory,
  migrateInventory,
  uninstallInventory,
} from './inventory.js'
import {
  addSections,
  installLayout,
  removeSection,
  uninstallLayout,
} from './layout.js'
import {
  type InstallFuelArgs,
  type InstallGeneratorArgs,
  installFuelWithLoad,
  installGenerator,
  installPowerGrid,
  migrateFuel,
  migrateGenerator,
  uninstallFuel,
  uninstallGenerator,
  uninstallPowerGrid,
} from './power.js'

/**
 * How modules move between creations. External services use path 1.
 * - Path 1, `reinstall` (default): uninstall each module and install it fresh
 *   on the target from the given install args. Modules arrive offline, a fuel
 *   bay carries its share of fuel, an inventory's items are burned.
 * - Path 2, `migrate` (optional): move each module with its state intact.
 */
export type MovePath = 'reinstall' | 'migrate'

/** A module in a section, with the args `reinstall` installs it with. */
export type SectionModule =
  | ({ kind: 'generic' } & InstallGenericModuleArgs)
  | ({ kind: 'inventory' } & InstallInventoryArgs)
  | ({ kind: 'generator' } & InstallGeneratorArgs)
  | ({ kind: 'fuel' } & InstallFuelArgs)

export interface SectionSpec {
  sectionId: bigint
  /** Section id on the target creation; defaults to `sectionId`. Set it when the ids collide. */
  targetSectionId?: bigint
  modules: SectionModule[]
}

/** Move every module of `section` from `from` to `to`. The Layouts are untouched. */
export function moveSectionModules(
  tx: Transaction,
  config: WorldConfig,
  from: TransactionArgument,
  to: TransactionArgument,
  section: SectionSpec,
  path: MovePath,
): void {
  for (const module of section.modules) {
    if (path === 'migrate') migrateModule(tx, config, from, to, module)
    else reinstallModule(tx, config, from, to, module)
  }
}

function migrateModule(
  tx: Transaction,
  config: WorldConfig,
  from: TransactionArgument,
  to: TransactionArgument,
  module: SectionModule,
): void {
  const id = module.componentId
  switch (module.kind) {
    case 'generic':
      migrateGenericModule(tx, config, from, to, id)
      break
    case 'inventory':
      migrateInventory(tx, config, from, to, id)
      break
    case 'generator':
      migrateGenerator(tx, config, from, to, id)
      break
    case 'fuel':
      migrateFuel(tx, config, from, to, id)
      break
  }
}

function reinstallModule(
  tx: Transaction,
  config: WorldConfig,
  from: TransactionArgument,
  to: TransactionArgument,
  module: SectionModule,
): void {
  const id = module.componentId
  switch (module.kind) {
    case 'generic':
      uninstallGenericModule(tx, config, from, id)
      installGenericModule(tx, config, to, module)
      break
    case 'inventory':
      uninstallInventory(tx, config, from, id)
      installInventory(tx, config, to, module)
      break
    case 'generator':
      uninstallGenerator(tx, config, from, id)
      installGenerator(tx, config, to, module)
      break
    case 'fuel': {
      const load = uninstallFuel(tx, config, from, id)
      installFuelWithLoad(tx, config, to, module, load)
      break
    }
  }
}

function layoutSection(section: SectionSpec) {
  return {
    sectionId: section.targetSectionId ?? section.sectionId,
    moduleIds: section.modules.map((m) => m.componentId),
  }
}

/**
 * Move `section` and its modules from creation `from` to creation `to`, both
 * already holding a Layout and a power grid. `from` must keep at least one
 * section. One PTB, admin-signed.
 */
export function migrateSection(
  tx: Transaction,
  config: WorldConfig,
  from: TransactionArgument,
  to: TransactionArgument,
  section: SectionSpec,
  path: MovePath,
): void {
  moveSectionModules(tx, config, from, to, section, path)
  removeSection(tx, config, from, section.sectionId)
  addSections(tx, config, to, [layoutSection(section)])
}

/**
 * Detach `section` from `source` into a new creation under `target`'s key,
 * unowned and dark, with its own power grid. The new creation is shared once
 * its Layout holds the section. Returns it. One PTB, admin-signed.
 */
export function detachSection(
  tx: Transaction,
  config: WorldConfig,
  source: TransactionArgument,
  target: EntityNewArgs,
  section: SectionSpec,
  path: MovePath,
): TransactionArgument {
  const [created, request] = entityNew(tx, config, target)
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, created, request)
  installPowerGrid(tx, config, created)
  moveSectionModules(tx, config, source, created, section, path)
  removeSection(tx, config, source, section.sectionId)
  installLayout(tx, config, created, [layoutSection(section)])
  shareEntity(tx, config, created)
  return created
}

/**
 * Merge creation `absorbed` into `survivor`: move every section and module of
 * `absorbed`, then remove its Layout and grid and delete it. `absorbed` must
 * hold nothing else. One PTB, admin-signed.
 */
export function mergeCreation(
  tx: Transaction,
  config: WorldConfig,
  survivor: TransactionArgument,
  absorbed: TransactionArgument,
  sections: SectionSpec[],
  path: MovePath,
): void {
  for (const section of sections) {
    moveSectionModules(tx, config, absorbed, survivor, section, path)
  }
  addSections(tx, config, survivor, sections.map(layoutSection))
  uninstallLayout(tx, config, absorbed)
  uninstallPowerGrid(tx, config, absorbed)
  deleteEntity(tx, config, absorbed)
}
