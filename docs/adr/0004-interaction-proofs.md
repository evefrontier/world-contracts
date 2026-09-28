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
| Gate link                                                  | Within distance       |
| Power network                                              | Connected by conduit  |

One proof can't express all of these. And because locations are stored as hashes, the chain can't
work out these relationships itself; only the game server knows them.

For any action between two creations, the chain needs to know whether they are allowed to interact
according to digital physics.

## Decision

1. **One signed Message, one payload type per use case.** The server signs the relationship
   (e.g. "ship B is docked at A"), not the locations. The
   use-case data travels as `payload`, the BCS of a struct only its own module can decode. Proof
   bytes are `bcs(Message) || bcs(signature)`.

    ```move
    public struct Message has drop {
        server: address, // must be an authorized server
        sender: address, // only this address may submit it
        kind: vector<u8>, // type_name of the payload struct
        deadline_ms: u64, // expiry; the only replay protection
        payload: vector<u8>, // BCS of e.g. Docking or GateDistance
    }
    ```

   `kind` binds a signature to one payload type. It includes the package address, so a signature
   can't be reused across kinds or deployments. `core::proof::verify<K>` checks the message and
   signature and returns the payload; it takes a `Permit<K>`, so only `K`'s module can open it.

2. **Each use case is a module that owns its payload, decoder and check.** Docking is world
   physics, so it lives in `core::docking`. A gate's `GateDistance { source_gate, dest_gate,
   distance }` would live with gates, with no change to core.

    ```move
    public struct Docking has copy, drop { ship: ID, target: ID, character: ID } // no store: one tx

    public fun verify(bytes: vector<u8>, clock: &Clock, ctx: &mut TxContext) // into the scratchpad
    public fun attest(acl: &AdminACL, ctx: &mut TxContext)                   // rollout, point 5
    public fun assert_docked(entity: ID, source: Option<ID>, ctx: &TxContext)
    ```

   The proof is verified once and kept in the transaction
   [scratchpad](https://move-book.com/programmability/scratchpad/) under a key only
   `core::docking` can read or write.

3. **Long-lived relationships are stored, not proven.** A gate link needs one `Distance` proof on
   the interaction that creates it; after that proof is checked, the link is stored. A conduit
   connection works the same way for `PowerNetwork`: the proof authorizes the interaction, and only
   the connection is stored for later actions.

4. **Rollout: switched per proof type.** Each proof type's `ProofConfig` is in one of two modes:
    - **Attested:** `docking::attest(acl, ctx)` stores an attested docking when the sender is an
      admin, or the gas sponsor is allowlisted. `assert_docked` then passes for any entity. No
      proof is needed: the sponsor backend checks the whole transaction, both entities included,
      before paying gas. Used until proofs are published through external APIs.
    - **Signed:** only `docking::verify` with a server-signed proof stores a docking.

## Alternatives Considered

1. **One proximity proof for everything (today).** Doesn't fit docking, distance or power network.
2. **Signed locations; the chain works out relationships.** Needs real coordinates on-chain, which
   would leak positions.
3. **Store every relationship on-chain.** Too costly, and docking goes stale. Used only for
   long-lived relationships (point 4).
4. **Docking as a `Requirement` per request.** Handlers push a docking requirement and the PTB
   satisfies each one against the cached docking. It shows the need in `request.requires()`, but
   adds one call per withdraw and deposit to re-check a rule no owner can change.

## Consequences

- New shared object: `ProofConfig` (authorized servers, mode per kind).
- One signature check per transfer in Signed mode, however many requests use the `Docking`.
- `withdraw` and `deposit` check docking inline; `deposit` gains a `ctx: &TxContext` argument.
  The docking need doesn't appear in `request.requires()`, so clients learn it from these
  handlers' docs, or from `ENoDocking`.
- In Attested mode, a player can submit when an allowlisted sponsor pays the gas. An admin can
  submit as the sender with no sponsor.
