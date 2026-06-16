import { createCharacter } from "../packages/character.js";
import { deriveObjectId } from "../packages/core.js";
import type { CharacterSeed, Seeder } from "./types.js";

export const characterSeeder: Seeder<CharacterSeed> = {
    kind: "character",
    deriveId: (config, input) => deriveObjectId(config, { id: input.inGameId, tenant: input.tenant }),
    build: (tx, config, input) =>
        createCharacter(tx, config, {
            inGameId: input.inGameId,
            tenant: input.tenant,
            tribeId: input.tribeId,
            owner: input.owner,
        }),
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type SeederRegistry = Record<string, Seeder<any>>;

/** The seeders shipped with the SDK. Extend by spreading in your own. */
export const defaultSeeders: SeederRegistry = {
    [characterSeeder.kind]: characterSeeder,
};
