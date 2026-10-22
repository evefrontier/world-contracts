import type {
  Transaction,
  TransactionArgument,
  TransactionResult,
} from '@mysten/sui/transactions'
import { mvrName } from '../config/env.js'
import type { WorldConfig } from '../config/types.js'
import {
  completeRequest,
  enableAdminAction,
  interact,
  verifyAdmin,
} from './core.js'

const CREATION_PACKAGE = 'creation'

/** Admin action every Layout edit runs under. */
export const LAYOUT_ACTION = 'layout'

function layoutCall(
  config: WorldConfig,
  functionName: string,
): `${string}::${string}::${string}` {
  return `${mvrName(config.env, CREATION_PACKAGE)}::layout::${functionName}`
}

export interface LayoutSection {
  sectionId: bigint
  moduleIds: bigint[]
}

function sectionArguments(
  tx: Transaction,
  sections: LayoutSection[],
): TransactionArgument[] {
  return [
    tx.pure.vector(
      'u64',
      sections.map((s) => s.sectionId),
    ),
    tx.pure.vector(
      'vector<u64>',
      sections.map((s) => s.moduleIds),
    ),
  ]
}

export function layoutEditRequirement(
  tx: Transaction,
  config: WorldConfig,
): TransactionResult {
  return tx.moveCall({ target: layoutCall(config, 'edit_requirement') })
}

/**
 * Install the Layout with its first sections, dark, and enable the admin
 * `layout` action its edits run under. Every listed module must already be
 * installed. Admin-gated.
 */
export function installLayout(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  sections: LayoutSection[],
): void {
  const request = tx.moveCall({
    target: layoutCall(config, 'install'),
    arguments: [entity, ...sectionArguments(tx, sections)],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
  enableAdminAction(tx, config, entity, LAYOUT_ACTION, [
    layoutEditRequirement(tx, config),
  ])
}

/** Remove the Layout, e.g. from a creation a merge absorbed. Admin-gated. */
export function uninstallLayout(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): void {
  const request = tx.moveCall({
    target: layoutCall(config, 'uninstall'),
    arguments: [entity],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

/** Run one Layout edit handler under the `layout` action. Admin-gated. */
function edit(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  functionName: string,
  args: TransactionArgument[],
): void {
  const request = interact(tx, config, entity, LAYOUT_ACTION)
  tx.moveCall({
    target: layoutCall(config, functionName),
    arguments: [entity, request, ...args],
  })
  verifyAdmin(tx, config, request)
  completeRequest(tx, config, entity, request)
}

export function addSections(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  sections: LayoutSection[],
): void {
  edit(tx, config, entity, 'add_sections', sectionArguments(tx, sections))
}

/** Remove a section whose modules have all left the creation. */
export function removeSection(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  sectionId: bigint,
): void {
  edit(tx, config, entity, 'remove_section', [tx.pure.u64(sectionId)])
}

export function addModule(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  sectionId: bigint,
  moduleId: bigint,
): void {
  edit(tx, config, entity, 'add_module', [
    tx.pure.u64(sectionId),
    tx.pure.u64(moduleId),
  ])
}

export function removeModule(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  sectionId: bigint,
  moduleId: bigint,
): void {
  edit(tx, config, entity, 'remove_module', [
    tx.pure.u64(sectionId),
    tx.pure.u64(moduleId),
  ])
}

/** Mark the creation working with `shellId`. */
export function setShell(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  shellId: string,
): void {
  edit(tx, config, entity, 'set_shell', [tx.pure.id(shellId)])
}

/** Mark the creation dark. */
export function clearShell(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): void {
  edit(tx, config, entity, 'clear_shell', [])
}

export function sectionIds(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): TransactionResult {
  return tx.moveCall({
    target: layoutCall(config, 'section_ids'),
    arguments: [entity],
  })
}

export function sectionModules(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
  sectionId: bigint,
): TransactionResult {
  return tx.moveCall({
    target: layoutCall(config, 'section_modules'),
    arguments: [entity, tx.pure.u64(sectionId)],
  })
}

export function shellId(
  tx: Transaction,
  config: WorldConfig,
  entity: TransactionArgument,
): TransactionResult {
  return tx.moveCall({
    target: layoutCall(config, 'shell_id'),
    arguments: [entity],
  })
}
