/**
 * Get turret target priority list (world or extension by type name).
 *
 * Resolves extension via world::turret::is_extension_configured + extension_type;
 * then calls world::turret::get_target_priority_list or extension_package::module::get_target_priority_list.
 * Run: pnpm run get-priority-list (or get-default-priority-list / get-priority-list-from-extension).
 */
import "dotenv/config";
import { Transaction } from "@mysten/sui/transactions";
import { bcs } from "@mysten/sui/bcs";
import { HydratedWorldConfig, MODULES } from "../utils/config";
import {
    initializeContext,
    handleError,
    getEnvConfig,
    hydrateWorldConfig,
    requireEnv,
} from "../utils/helper";
import { deriveObjectId } from "../utils/derive-object-id";
import { devInspectMoveCallFirstReturnValueBytes } from "../utils/dev-inspect";
import { GAME_CHARACTER_ID, TURRET_ITEM_ID } from "../utils/constants";
import type { SuiJsonRpcClient } from "@mysten/sui/jsonRpc";

export type TurretExtensionInfo = {
    hasExtension: boolean;
    typeName?: string;
    packageId?: string;
    moduleName?: string;
};

/** Resolve extension type name and package/module from world turret. */
export async function getTurretExtensionInfo(
    client: SuiJsonRpcClient,
    worldPackageId: string,
    turretId: string
): Promise<TurretExtensionInfo> {
    const configuredBytes = await devInspectMoveCallFirstReturnValueBytes(client, {
        target: `${worldPackageId}::${MODULES.TURRET}::is_extension_configured`,
        arguments: (tx) => [tx.object(turretId)],
    });
    if (!configuredBytes || configuredBytes.length === 0 || configuredBytes[0] !== 1) {
        return { hasExtension: false };
    }

    const typeNameBytes = await devInspectMoveCallFirstReturnValueBytes(client, {
        target: `${worldPackageId}::${MODULES.TURRET}::extension_type`,
        arguments: (tx) => [tx.object(turretId)],
    });
    if (!typeNameBytes || typeNameBytes.length === 0) {
        return { hasExtension: false };
    }
    const nameBytes = bcs.vector(bcs.u8()).parse(typeNameBytes);
    const typeName = new TextDecoder().decode(new Uint8Array(nameBytes));
    const firstColonColon = typeName.indexOf("::");
    const addressPart = firstColonColon === -1 ? typeName : typeName.slice(0, firstColonColon);
    const packageId = addressPart.startsWith("0x") ? addressPart : `0x${addressPart}`;
    const parts = typeName.split("::");
    const moduleName = parts.length >= 2 ? parts[1] : "turret";
    return { hasExtension: true, typeName, packageId, moduleName };
}

export const TurretTargetBcs = bcs.struct("TurretTarget", {
    target_id: bcs.Address,
    target_type_id: bcs.u64(),
    target_character_id: bcs.Address,
    target_character_tribe: bcs.u32(),
    hp_ratio: bcs.u64(),
    shield_ratio: bcs.u64(),
    armor_ratio: bcs.u64(),
    is_agressor: bcs.bool(),
    weight: bcs.u64(),
});

export type TurretTargetArg = {
    target_id: string;
    target_type_id: bigint;
    target_character_id: string;
    target_character_tribe: number;
    hp_ratio: bigint;
    shield_ratio: bigint;
    armor_ratio: bigint;
    is_agressor: boolean;
    weight: bigint;
};

/** Serialize priority list and new target to BCS bytes for move calls. */
export function serializePriorityListArgs(
    priorityList: TurretTargetArg[],
    newTarget: TurretTargetArg
) {
    return {
        priorityListBytes: bcs.vector(TurretTargetBcs).serialize(priorityList).toBytes(),
        newTargetBytes: TurretTargetBcs.serialize(newTarget).toBytes(),
    };
}

/** Parse devInspect return value (second move call) and return priority list length. */
export function parsePriorityListReturnLength(returnValues: unknown): number {
    const arr = returnValues as [Uint8Array | number[], unknown][] | undefined;
    if (!arr?.length) return 0;
    const raw = arr[0][0];
    const returnBytes = raw instanceof Uint8Array ? raw : new Uint8Array(raw);
    const outerBytes = new Uint8Array(returnBytes);
    const innerBytes =
        outerBytes.length === 0
            ? new Uint8Array(0)
            : new Uint8Array(bcs.vector(bcs.u8()).parse(outerBytes));
    const list = innerBytes.length === 0 ? [] : bcs.vector(TurretTargetBcs).parse(innerBytes);
    return list.length;
}

/**
 * Get turret priority list from world contracts only:
 * world::turret::verify_online(turret) -> receipt, then
 * world::turret::get_target_priority_list(turret, character, priority_list, new_target, receipt) -> vector<u8>.
 * Uses devInspect (read-only simulation).
 */
export async function getTurretPriorityListFromWorld(
    turretId: string,
    characterId: string,
    priorityList: TurretTargetArg[],
    newTarget: TurretTargetArg,
    ctx: ReturnType<typeof initializeContext>
): Promise<number> {
    const { client, keypair } = ctx;
    const config = ctx.config as HydratedWorldConfig;

    const { priorityListBytes, newTargetBytes } = serializePriorityListArgs(
        priorityList,
        newTarget
    );

    const tx = new Transaction();

    const [receipt] = tx.moveCall({
        target: `${config.packageId}::${MODULES.TURRET}::verify_online`,
        arguments: [tx.object(turretId)],
    });

    tx.moveCall({
        target: `${config.packageId}::${MODULES.TURRET}::get_target_priority_list`,
        arguments: [
            tx.object(turretId),
            tx.object(characterId),
            tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(priorityListBytes)).toBytes()),
            tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(newTargetBytes)).toBytes()),
            receipt,
        ],
    });

    const result = await client.devInspectTransactionBlock({
        sender: keypair.getPublicKey().toSuiAddress(),
        transactionBlock: tx,
    });

    if (result.effects?.status?.status !== "success") {
        const err = result.effects?.status?.error ?? result.effects?.status;
        throw new Error(`DevInspect failed: ${JSON.stringify(err)}`);
    }

    return parsePriorityListReturnLength(result.results?.[1]?.returnValues);
}

/**
 * Get priority list by type name: if turret has an extension, call extension get_target_priority_list;
 * otherwise world::turret::get_target_priority_list.
 */
export async function getTurretPriorityList(
    turretId: string,
    characterId: string,
    priorityList: TurretTargetArg[],
    newTarget: TurretTargetArg,
    ctx: ReturnType<typeof initializeContext>
): Promise<number> {
    const extensionInfo = await getTurretExtensionInfo(ctx.client, ctx.config.packageId, turretId);

    if (
        extensionInfo.hasExtension &&
        extensionInfo.packageId != null &&
        extensionInfo.moduleName != null
    ) {
        const { client, keypair } = ctx;
        const config = ctx.config as HydratedWorldConfig;
        const { priorityListBytes, newTargetBytes } = serializePriorityListArgs(
            priorityList,
            newTarget
        );

        const tx = new Transaction();
        const [receipt] = tx.moveCall({
            target: `${config.packageId}::${MODULES.TURRET}::verify_online`,
            arguments: [tx.object(turretId)],
        });
        tx.moveCall({
            target: `${extensionInfo.packageId}::${extensionInfo.moduleName}::get_target_priority_list`,
            arguments: [
                tx.object(turretId),
                tx.object(characterId),
                tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(priorityListBytes)).toBytes()),
                tx.pure(bcs.vector(bcs.u8()).serialize(Array.from(newTargetBytes)).toBytes()),
                receipt,
            ],
        });

        const result = await client.devInspectTransactionBlock({
            sender: keypair.getPublicKey().toSuiAddress(),
            transactionBlock: tx,
        });
        if (result.effects?.status?.status !== "success") {
            const err = result.effects?.status?.error ?? result.effects?.status;
            throw new Error(`DevInspect failed: ${JSON.stringify(err)}`);
        }
        return parsePriorityListReturnLength(result.results?.[1]?.returnValues);
    }

    return getTurretPriorityListFromWorld(turretId, characterId, priorityList, newTarget, ctx);
}

async function main() {
    try {
        const env = getEnvConfig();
        const playerKey = requireEnv("PLAYER_A_PRIVATE_KEY");
        const ctx = initializeContext(env.network, playerKey);
        await hydrateWorldConfig(ctx);

        const turretId = deriveObjectId(
            ctx.config.objectRegistry,
            TURRET_ITEM_ID,
            ctx.config.packageId
        );
        const characterId = deriveObjectId(
            ctx.config.objectRegistry,
            GAME_CHARACTER_ID,
            ctx.config.packageId
        );

        const extensionInfo = await getTurretExtensionInfo(
            ctx.client,
            ctx.config.packageId,
            turretId
        );
        console.log(
            "Turret extension:",
            extensionInfo.hasExtension ? (extensionInfo.typeName ?? "configured") : "none (world)"
        );

        const newTarget: TurretTargetArg = {
            target_id: "0x00000000000000000000000000000000000000000000000000000000000000ab",
            target_type_id: 1n,
            target_character_id: characterId,
            target_character_tribe: 100,
            hp_ratio: 100n,
            shield_ratio: 100n,
            armor_ratio: 100n,
            is_agressor: true,
            weight: 1n,
        };

        const length = await getTurretPriorityList(turretId, characterId, [], newTarget, ctx);
        console.log("priority_list length:", length);
    } catch (error) {
        handleError(error);
    }
}

main();
