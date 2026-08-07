# @evefrontier/world-sdk

A thin, builder-style TypeScript SDK for the EVE Frontier `world-contracts`

## Install

```sh
npm install @evefrontier/world-sdk @mysten/sui
```

`@mysten/sui` (v2) is a peer dependency.

## Usage

```ts
import { Transaction } from "@mysten/sui/transactions";
import { createWorldClient, createCharacter, getWorldConfig } from "@evefrontier/world-sdk";

const config = getWorldConfig("live");
const client = createWorldClient({ config });

const tx = new Transaction();
createCharacter(tx, config, {
    inGameId: 42n,
    tenant: "my-tenant",
    tribeId: 1,
    owner: "0x...",
});

// sign + execute `tx` with your keypair / wallet
```

### Local / CI

On `local`, load config from a generated `world.json` manifest:

```ts
import { loadWorldConfig, deriveObjectId } from "@evefrontier/world-sdk";

const config = loadWorldConfig("deployments/localnet/world.json");
const id = deriveObjectId(config, { id: 7n, tenant: "my-tenant" });
```

### Freight delivery (v1)

v1 transit `Item`s have no `parent_id`. Cross-entity hauls use an additive
`freight` receipt that binds one withdrawn `Item` to a source, destination,
tenant, and carrier. Typical action composition:

- **pickup:** proximity (injected) → caller → inventory withdraw → freight pickup
- **dropoff:** proximity (injected) → caller → freight dropoff → inventory deposit

```ts
import {
  callerRequirement,
  completeRequest,
  dropoff,
  dropoffRequirement,
  enableAction,
  interact,
  pickup,
  pickupRequirement,
  verifyCaller,
  verifyProximity,
  withdraw,
  withdrawRequirement,
  deposit,
  depositRequirement,
} from "@evefrontier/world-sdk";

// Owner configures once (separate txs per entity):
enableAction(tx, config, source, "freight_pickup", [
  callerRequirement(tx, config),
  withdrawRequirement(tx, config, "SU-01", {
    ephemeral: false,
    typeId: 88834n,
  }),
  pickupRequirement(tx, config, destId),
], sourceOwnerCap);

enableAction(tx, config, dest, "freight_dropoff", [
  callerRequirement(tx, config),
  dropoffRequirement(tx, config),
  depositRequirement(tx, config, "SU-01", {
    ephemeral: false,
    typeId: 88834n,
  }),
], destOwnerCap);

// Carrier tx 1 — pickup:
const pickReq = interact(tx, config, source, "freight_pickup");
verifyProximity(tx, config, pickReq);
verifyCaller(tx, config, pickReq, carrierCap);
const item = withdraw(tx, config, source, pickReq, { typeId: 88834n, quantity: 10n });
const receipt = pickup(tx, config, source, pickReq, item);
completeRequest(tx, config, source, pickReq);
// transfer item + receipt to the carrier (or keep them in the PTB)

// Carrier tx 2 — dropoff:
const dropReq = interact(tx, config, dest, "freight_dropoff");
verifyProximity(tx, config, dropReq);
verifyCaller(tx, config, dropReq, carrierCap);
dropoff(tx, config, dest, dropReq, item, receipt);
deposit(tx, config, dest, dropReq, item);
completeRequest(tx, config, dest, dropReq);
```

Entity proximity today is hash equality only (`location_service` marks signed
proof verification as TODO). The receipt authorizes the haul; it is not a
cryptographic anti-teleport locality proof.

## Versioning

Manual semver. Each release states which contract release it supports — a
breaking Move ABI change is a breaking SDK release.

## License

MIT
