import { Transaction } from '@mysten/sui/transactions'
import { signAndExecute } from '../src/client.js'
import { addAdmins, addSponsors } from '../src/packages/core.js'
import { loadScriptContext } from './context.js'

function addresses(name: string): string[] {
  return (process.env[name]?.split(',') ?? [])
    .map((a) => a.trim())
    .filter((a) => a.length > 0)
}

const admins = addresses('ADMIN_ADDRESSES')
const sponsors = addresses('SPONSOR_ADDRESSES')

if (admins.length === 0 && sponsors.length === 0) {
  console.log('no ADMIN_ADDRESSES or SPONSOR_ADDRESSES set; nothing to do.')
  process.exit(0)
}

const { config, client, keypair } = loadScriptContext()

const tx = new Transaction()
if (admins.length > 0) addAdmins(tx, config, admins)
if (sponsors.length > 0) addSponsors(tx, config, sponsors)

const res = await signAndExecute(client, {
  signer: keypair,
  transaction: tx,
})

console.log('digest:', res.digest)
console.log(
  `admins added: ${admins.length}, sponsors added: ${sponsors.length}`,
)
