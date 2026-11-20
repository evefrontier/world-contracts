# 4. Interaction Proofs

- **Status:** Proposed. Amended 2026-11-20: docking is stored on the entity, not proven
  ([#289](https://github.com/evefrontier/world-contracts/pull/289)).
- **Relates to:** [0002-modular-architecture](0002-modular-architecture.md),
  [0003-onchain-inventory-design](0003-onchain-inventory-design.md)

## Context

Today `entity::interact` adds one `Proximity` requirement to every action, checked by an exact
location-hash match. The plan was a single server-signed location proof for everything.

As we build modularity and the design changes, digital physics has new rules:

| Use case                                                   | Required relationship |
| ---------------------------------------------------------- | --------------------- |
| Item transfer between a ship and a structure, or two ships | Docked                |
| Gate link                                                  | Within distance       |
| Power network                                              | Connected by conduit  |

One proof can't express all of these. And because locations are stored as hashes, the chain can't
work out these relationships itself; only the game server knows them.

For any action between two creations, the chain needs to know whether they are allowed to interact
according to digital physics.

## Decision

1. **One signed message, one payload type per use case.** The server signs the relationship
   (e.g. "gate B is within range of gate A"), not the locations. The use-case data travels as
   `payload`, the BCS of a struct only its own module can decode. Proof bytes are
   `bcs(ProofMessage) || bcs(signature)`.

    ```move
    public struct ProofMessage has drop {
        server: address, // must be an admin on AdminACL
        sender: address, // only this address may submit it
        kind: vector<u8>, // type_name of the payload struct
        deadline_ms: u64, // expiry; the only replay protection
        payload: vector<u8>, // BCS of e.g. GateDistance
    }
    ```

   `kind` binds a signature to one payload type. It includes the package address, so a signature
   can't be reused across kinds or deployments. `core::proof::verify<K>` checks the message and
   signature and returns the payload; it takes a `Permit<K>`, so only `K`'s module can open it.

2. **Each use case is a module that owns its payload, decoder and check.** A gate's
   `GateDistance { source_gate, dest_gate, distance }` would live with gates, with no change to
   core.

3. **Long-lived relationships are stored, not proven.** A gate link needs one `Distance` proof on
   the interaction that creates it; after that proof is checked, the link is stored. A conduit
   connection works the same way for `PowerNetwork`: the proof authorizes the interaction, and only
   the connection is stored for later actions.

4. **Docking is stored on the entity and set by an admin.** Every entity keeps a `VecSet<ID>` of
   the entities it is docked with, under `DockedEntitiesKey`. One entity can be docked with many;

    ```move
    public fun dock(target: &mut Entity, chaser: &mut Entity): (Request, Request)   // admin-gated
    public fun undock(target: &mut Entity, chaser: &mut Entity): (Request, Request) // admin-gated
    public fun assert_docked(destination: &Entity, source: ID)
    public fun docked_entities(entity: &Entity): VecSet<ID>
    ```

## Alternatives Considered

1. **One proximity proof for everything (today).** Doesn't fit docking, distance or power network.
2. **Signed locations; the chain works out relationships.** Needs real coordinates on-chain, which
   would leak positions.
3. **Store every relationship on-chain.** Too costly for short-lived checks such as distance. Used
   for long-lived relationships (point 3) and for docking (point 4).
4. **Docking as a `Requirement` per request.** Handlers push a docking requirement and the PTB
   satisfies each one. It shows the need in `request.requires()`, but adds one call per withdraw
   and deposit to re-check a rule no owner can change.
5. **Signed docking proof per transaction (this ADR's first version).** A `core::docking` module
   verified a server-signed `Docking { ship, target, character }` into the transaction scratchpad,
   with an attested mode for rollout. Superseded by point 4: it needed a signature or an attest
   call in every transfer, and a `ProofConfig` for modes. Stored docking needs no proof at
   transfer time and is simpler to test.

## Consequences

- No `ProofConfig`: proof servers are admins on `AdminACL`.
- `deposit` and `deposit_batch` check every item's `source` with `entity.assert_docked`, and abort
  with `ENotDocked` or `EWrongSource`. Neither takes a `ctx`.
- `withdraw` and `withdraw_batch` don't check docking: the `Item` can only leave the transaction
  through a deposit, which checks its source.
- Moving items between two inventories on the same entity needs no docking.
- The docking need doesn't appear in `request.requires()`, so clients learn it from the deposit
  handlers' docs, or from the abort.
- The docked set is only as fresh as the game server keeps it: it must call `undock` when a ship
  leaves.
