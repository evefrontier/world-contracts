import type { Transaction } from "@mysten/sui/transactions";
import type { WorldConfig } from "./config/types.js";
import { mvrName } from "./config/env.js";
import { objectRegistry } from "./config/shared-objects.js";

const CHARACTER_PACKAGE = "character";

export interface CreateCharacterArgs {
    inGameId: bigint;
    tenant: string;
    tribeId: number;
    owner: string;
}

export function createCharacter(
    tx: Transaction,
    config: WorldConfig,
    args: CreateCharacterArgs
): void {
    const registry = objectRegistry(config);
    tx.moveCall({
        target: `${mvrName(config.env, CHARACTER_PACKAGE)}::character::create`,
        arguments: [
            tx.sharedObjectRef({
                objectId: registry.id,
                initialSharedVersion: registry.initialSharedVersion,
                mutable: true,
            }),
            tx.pure.u64(args.inGameId),
            tx.pure.string(args.tenant),
            tx.pure.u32(args.tribeId),
            tx.pure.address(args.owner),
        ],
    });
}
