/**
 * Remove the [published.<env>] table from a package's Published.toml so a fresh
 * `deploy` can record a new lineage. No-op if the file or entry is absent.
 *
 * Usage: tsx ts-scripts/clear-published.ts <Published.toml> <env>
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { parse as parseToml, stringify as stringifyToml } from '@iarna/toml'

const [file, env] = process.argv.slice(2)
if (!file || !env) {
  console.error('Usage: clear-published.ts <Published.toml> <env>')
  process.exit(1)
}
if (!existsSync(file)) process.exit(0)

const toml = parseToml(readFileSync(file, 'utf8')) as {
  published?: Record<string, unknown>
}
if (!toml.published?.[env]) process.exit(0)

delete toml.published[env]
if (Object.keys(toml.published).length === 0) delete toml.published
writeFileSync(file, stringifyToml(toml))
console.log(`Cleared [published.${env}] from ${file}`)
