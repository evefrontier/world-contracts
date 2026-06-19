// Copy committed deployment manifests into the package so getWorldConfig can
// read them at runtime. world.json (one per published env) is the source of
// truth; the SDK just bundles a copy. localnet is ephemeral and excluded.
import { cpSync, existsSync, mkdirSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const deployments = join(here, '../../../deployments')
const out = join(here, '../dist/presets')

mkdirSync(out, { recursive: true })

for (const env of readdirSync(deployments)) {
  if (env === 'localnet') continue
  const src = join(deployments, env, 'world.json')
  if (!existsSync(src)) continue
  cpSync(src, join(out, `${env}.json`))
  console.log(`Bundled preset: ${env}.json`)
}
