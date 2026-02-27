/**
 * Get turret target priority list (world or extension by type name).
 *
 * The game calls get_target_priority_list when target behaviour changes (e.g. entered range, started/stopped attack).
 * Each candidate has a single behaviour_change; if both ENTERED and STARTED_ATTACK apply, the game sends STARTED_ATTACK.
 *
 * API: get_target_priority_list(turret, character, target_candidate_list, receipt)
 * -> BCS of vector<ReturnTargetPriorityList> (target_item_id + priority_weight per entry).
 *
 * Resolves extension via is_extension_configured then extension_type; calls world or extension get_target_priority_list.
 * Run: pnpm run get-priority-list
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

export type TargetCandidateArg = {
    item_id: bigint;
    type_id: bigint;
    group_id: bigint;
    character_id: number;
    character_tribe: number;
    hp_ratio: bigint;
    shield_ratio: bigint;
    armor_ratio: bigint;
    is_aggressor: boolean;
    priority_weight: bigint;
    behaviour_change: number;
};

export type ReturnTargetPriorityListArg = {
    target_item_id: bigint;
    priority_weight: bigint;
};

// TargetCandidate BCS: (item_id, type_id, group_id, character_id, character_tribe, hp_ratio, shield_ratio, armor_ratio, is_aggressor, priority_weight, behaviour_change u8)
// behaviour_change: 0=UNSPECIFIED, 1=ENTERED, 2=STARTED_ATTACK, 3=STOPPED_ATTACK
export const TargetCandidateBcs = bcs.struct("TargetCandidate", {
    item_id: bcs.u64(),
    type_id: bcs.u64(),
    group_id: bcs.u64(),
    character_id: bcs.u32(),
    character_tribe: bcs.u32(),
    hp_ratio: bcs.u64(),
    shield_ratio: bcs.u64(),
    armor_ratio: bcs.u64(),
    is_aggressor: bcs.bool(),
    priority_weight: bcs.u64(),
    behaviour_change: bcs.u8(),
});

// ReturnTargetPriorityList BCS: (target_item_id: u64, priority_weight: u64)
export const ReturnTargetPriorityListBcs = bcs.struct("ReturnTargetPriorityList", {
    target_item_id: bcs.u64(),
    priority_weight: bcs.u64(),
});

/**
 * Resolve extension type name and package/module from world turret.
 * Mandatory: always call is_extension_configured first; extension_type aborts if no extension is configured.
 */
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
    const moduleName = "turret";
    return { hasExtension: true, typeName, packageId, moduleName };
}

/** Serialize target candidate list for move: get_target_priority_list(turret, character, target_candidate_list, receipt). */
export function serializeCandidateList(candidates: TargetCandidateArg[]) {
    const candidateListBytes = new Uint8Array(
        bcs.vector(TargetCandidateBcs).serialize(candidates).toBytes()
    );
    return { candidateListBytes: Array.from(candidateListBytes) };
}

/** Parse return value bytes as vector<ReturnTargetPriorityList>. */
export function parseReturnPriorityList(returnBytes: Uint8Array): ReturnTargetPriorityListArg[] {
    if (returnBytes.length === 0) return [];
    const inner = new Uint8Array(bcs.vector(bcs.u8()).parse(returnBytes));
    if (inner.length === 0) return [];
    const raw = bcs.vector(ReturnTargetPriorityListBcs).parse(inner);
    return raw.map((r: { target_item_id: bigint | string; priority_weight: bigint | string }) => ({
        target_item_id:
            typeof r.target_item_id === "bigint" ? r.target_item_id : BigInt(r.target_item_id),
        priority_weight:
            typeof r.priority_weight === "bigint" ? r.priority_weight : BigInt(r.priority_weight),
    }));
}

function parseDevInspectReturn(returnValues: unknown): ReturnTargetPriorityListArg[] {
    const arr = returnValues as [Uint8Array | number[], unknown][] | undefined;
    if (!arr?.length) return [];
    const raw = arr[0][0];
    const returnBytes = raw instanceof Uint8Array ? raw : new Uint8Array(raw);
    return parseReturnPriorityList(returnBytes);
}

/**
 * Get turret priority list from world:
 * get_target_priority_list(turret, character, target_candidate_list, receipt) -> vector<ReturnTargetPriorityList>.
 */
export async function getTurretPriorityListFromWorld(
    turretId: string,
    characterId: string,
    candidates: TargetCandidateArg[],
    ctx: ReturnType<typeof initializeContext>
): Promise<ReturnTargetPriorityListArg[]> {
    const { client, keypair } = ctx;
    const config = ctx.config as HydratedWorldConfig;

    const { candidateListBytes } = serializeCandidateList(candidates);

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
            tx.pure(bcs.vector(bcs.u8()).serialize(candidateListBytes).toBytes()),
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

    return parseDevInspectReturn(result.results?.[1]?.returnValues);
}

/**
 * Get priority list: if turret has extension, call extension; otherwise world.
 */
export async function getTurretPriorityList(
    turretId: string,
    characterId: string,
    candidates: TargetCandidateArg[],
    ctx: ReturnType<typeof initializeContext>
): Promise<ReturnTargetPriorityListArg[]> {
    const extensionInfo = await getTurretExtensionInfo(ctx.client, ctx.config.packageId, turretId);

    if (
        extensionInfo.hasExtension &&
        extensionInfo.packageId != null &&
        extensionInfo.moduleName != null
    ) {
        const { client, keypair } = ctx;
        const config = ctx.config as HydratedWorldConfig;
        const { candidateListBytes } = serializeCandidateList(candidates);

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
                tx.pure(bcs.vector(bcs.u8()).serialize(candidateListBytes).toBytes()),
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
        return parseDevInspectReturn(result.results?.[1]?.returnValues);
    }

    return getTurretPriorityListFromWorld(turretId, characterId, candidates, ctx);
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

        const candidates: TargetCandidateArg[] = [
            {
                item_id: 0xabn,
                type_id: 1n,
                group_id: 0n,
                character_id: 2,
                character_tribe: 100,
                hp_ratio: 100n,
                shield_ratio: 100n,
                armor_ratio: 100n,
                is_aggressor: true,
                priority_weight: 10n,
                behaviour_change: 1,
            },
        ];

        const list = await getTurretPriorityList(turretId, characterId, candidates, ctx);
        console.log("ReturnTargetPriorityList length:", list.length);
        list.forEach((entry, i) => {
            console.log(
                `  [${i}] target_item_id=${entry.target_item_id} priority_weight=${entry.priority_weight}`
            );
        });
    } catch (error) {
        handleError(error);
    }
}

main();
