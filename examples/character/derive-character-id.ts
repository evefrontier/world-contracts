import { bcs } from "@mysten/sui/bcs";
import { deriveObjectID } from "@mysten/sui/utils";

export function deriveCharacterId(
    registryId: string,
    gameCharacterId: number | bigint,
    tenant: string,
    packageId: string
): string {
    const DerivationKey = bcs.struct("DerivationKey", {
        id: bcs.u64(),
        tenant: bcs.string(),
    });

    const DerivationKeyValue = {
        id: BigInt(gameCharacterId),
        tenant: tenant,
    };
    const serializedKey = DerivationKey.serialize(DerivationKeyValue).toBytes();
    const DerivationKeyTypeTag = `${packageId}::game_id::DerivationKey`;

    // Use the SDK's deriveObjectID function
    // This internally constructs: 0x2::derived_object::DerivedObjectKey<DerivationKeyTypeTag>
    // and derives the object ID using the same formula as Move
    return deriveObjectID(registryId, DerivationKeyTypeTag, serializedKey);
}
