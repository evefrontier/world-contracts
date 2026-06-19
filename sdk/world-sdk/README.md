# @evefrontier/world-sdk

A thin, builder-style TypeScript SDK for the EVE Frontier `world-contracts`

## Install

```sh
npm install @evefrontier/world-sdk @mysten/sui
```

`@mysten/sui` (v2) is a peer dependency.

## Usage

Load config from a generated `world.json` manifest, then build and execute a transaction:

```ts
import { Transaction } from "@mysten/sui/transactions";
import {
    createWorldClient,
    createCharacter,
    loadWorldConfig,
    deriveObjectId,
} from "@evefrontier/world-sdk";

const config = loadWorldConfig("deployments/localnet/world.json");
const client = createWorldClient({ config });

const tx = new Transaction();
createCharacter(tx, config, {
    inGameId: 42n,
    tenant: "my-tenant",
    tribeId: 1,
    owner: "0x...",
});

// sign + execute `tx` with your keypair / wallet

const id = deriveObjectId(config, { id: 42n, tenant: "my-tenant" });
```

## Versioning

Manual semver. Each release states which contract release it supports — a
breaking Move ABI change is a breaking SDK release.

## License

MIT
