# 4. Interaction Proofs

- **Status:** Proposed
- **Relates to:** [0002-modular-architecture](0002-modular-architecture.md),
  [0003-onchain-inventory-design](0003-onchain-inventory-design.md)

## Context

Today `entity::interact` adds one `Proximity` requirement to every action, checked by an exact
location-hash match. The plan was a single server-signed location proof for everything.

As we build modularity and the design changes, digital physics has new rules:

| Use case                                                   | Required relationship |
| ---------------------------------------------------------- | --------------------- |
| Item transfer between a ship and a structure, or two ships | Docked                |
| Item transfer between two structures                       | Proximity             |
| Gate link                                                  | Within distance       |
| Power network                                              | Connected by conduit  |

One proof can't express all of these. And because locations are stored as hashes, the chain can't
work out these relationships itself; only the game server knows them.

For any action between two creations, the chain needs to know whether they are allowed to interact
according to digital physics.

## Decision

1. **One proof per relationship.** v1 defines `Docking`, `Proximity` and `Distance` proofs. The
   server signs the relationship itself (e.g. "ship B is docked at A"), not the locations. These
   replace the location-hash `Proximity` that `entity::interact` injects today.

    The server signs this payload, and the contract checks the signature and the fields:

    ```move
    public struct DockingProof has drop {
        creation_id: ID, // ship
        target: ID, // structure or ship
        sender: address, // only this address may submit it
        deadline_ms: u64, // expiry
        nonce: u64, // single-use, blocks replay
    }
    ```

2. **The handler adds the requirement through its `Frame`.** `withdraw` and `deposit` push an
   `Interaction` requirement, as `game_item_to_chain` already does with `sponsor_requirement`. An
   owner can't build an action that skips it, and the handler never changes between modes.

3. **A transfer is one request per entity, sharing one `Relation`.** Moving an item from X to Y
   takes a request on X and a request on Y in the same transaction. In Signed mode, the proof is
   verified once into a `Relation`, and each request's `Interaction` requirement is satisfied
   against it. That aborts unless the request's entity is one of its two sides, so both requests are
   tied to the same pair. The same handlers serve every pair (ship and structure, ship and ship,
   structure and structure); which proof produced the `Relation` doesn't matter.

    ```move
    public struct Relation has drop { a: ID, b: ID }

    public fun verify_docking(
        cfg: &ProofConfig,
        proof: vector<u8>,
        sig: vector<u8>,
        ctx: &TxContext,
    ): Relation
    public fun verify_interaction(req: &mut Request, rel: &Relation)
    ```

4. **Long-lived relationships are stored, not proven.** A gate link needs one `Distance` proof on
   the interaction that creates it; after that proof is checked, the link is stored. A conduit
   connection works the same way for `PowerNetwork`: the proof authorizes the interaction, and only
   the connection is stored for later actions.

5. **Rollout: switched per proof type.** Each proof type's `ProofConfig` is in one of two modes:
    - **Attested:** `verify_interaction_attested(req, cfg, acl, ctx)` satisfies the requirement when
      the sender is an admin, or the gas sponsor is allowlisted. No `Relation` is needed: the
      sponsor backend checks the whole transaction, both entities included, before paying gas. Used
      until proofs are published through external APIs.
    - **Signed:** only `verify_interaction` with a `Relation` from a valid server-signed proof
      satisfies it.

    Only the calls in the transaction change when a type switches over; handlers and actions don't.

## Alternatives Considered

1. **One proximity proof for everything (today).** Doesn't fit docking, distance or power network.
2. **Signed locations; the chain works out relationships.** Needs real coordinates on-chain, which
   would leak positions.
3. **Store every relationship on-chain.** Too costly, and docking goes stale. Used only for
   long-lived relationships (point 4).

## Consequences

- New shared objects: a per-type `ProofConfig` (mode, signing key, used nonces).
- One signature check per transfer in Signed mode, however many requests use the `Relation`.
- `withdraw` and `deposit` push an `Interaction` requirement; their signatures don't change.
- In Attested mode, a player can submit when an allowlisted sponsor pays the gas. An admin can
  submit as the sender with no sponsor.
