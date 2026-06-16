import type { Transaction } from "@mysten/sui/transactions";
import type { WorldConfig } from "../config/types.js";

/**
 * A module's contribution to seeding: the `(deriveId, build)` pair it already
 * ships (the SDK mirrors the Move package). The engine dispatches each spec entry
 * to its seeder by `kind`, so adding a module means registering a seeder — not
 * adding another script.
 */
export interface Seeder<I> {
    kind: string;
    /** Deterministic object id for this input — used for idempotency and cross-references. */
    deriveId(config: WorldConfig, input: I): string;
    /** Append the module's creation call(s) to `tx`. */
    build(tx: Transaction, config: WorldConfig, input: I): void;
}

/** A character to seed. Inputs only — the object id is derived, never stored. */
export interface CharacterSeed {
    kind: "character";
    inGameId: bigint;
    tenant: string;
    tribeId: number;
    owner: string;
}

/**
 * One entry in a seed spec. A tagged, ordered list: the engine processes entries
 * in order (so later entries may depend on earlier ones) and resolves any
 * cross-references by deriving ids from inputs. Grows by union as modules land.
 */
export type SeedEntry = CharacterSeed;
