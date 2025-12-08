import { bcs } from "@mysten/sui/bcs";
import { deriveObjectID } from "@mysten/sui/utils";

export function deriveCharacterId(
    registryId: string,
    gameCharacterId: number | bigint,
    tenant: string,
    packageId: string
): string {
    const GameId = bcs.struct("GameId", {
        id: bcs.u64(),
        tenant: bcs.string(),
    });

    const gameIdValue = {
        id: BigInt(gameCharacterId),
        tenant: tenant,
    };
    const serializedKey = GameId.serialize(gameIdValue).toBytes();
    const gameIdTypeTag = `${packageId}::game_id::GameId`;

    // Use the SDK's deriveObjectID function
    // This internally constructs: 0x2::derived_object::DerivedObjectKey<gameIdTypeTag>
    // and derives the object ID using the same formula as Move
    return deriveObjectID(registryId, gameIdTypeTag, serializedKey);
}
