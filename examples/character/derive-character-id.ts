import { bcs } from "@mysten/sui/bcs";
import { deriveObjectID } from "@mysten/sui/utils";

export function deriveCharacterId(
    registryId: string,
    gameCharacterId: number | bigint,
    tenant: string,
    packageId: string
): string {
    const TenantItemDrvKey = bcs.struct("TenantItemDrvKey", {
        id: bcs.u64(),
        tenant: bcs.string(),
    });

    const TenantItemDrvKeyValue = {
        id: BigInt(gameCharacterId),
        tenant: tenant,
    };
    const serializedKey = TenantItemDrvKey.serialize(TenantItemDrvKeyValue).toBytes();
    const TenantItemDrvKeyTypeTag = `${packageId}::game_id::TenantItemDrvKey`;

    // Use the SDK's deriveObjectID function
    // This internally constructs: 0x2::derived_object::DerivedObjectKey<TenantItemDrvKeyTypeTag>
    // and derives the object ID using the same formula as Move
    return deriveObjectID(registryId, TenantItemDrvKeyTypeTag, serializedKey);
}
