import { bcs } from "@mysten/sui/bcs";
import { deriveObjectID } from "@mysten/sui/utils";

export function deriveObjectId(
    registryId: string,
    itemId: number | bigint,
    packageId: string
): string {
    const tenant = process.env.TENANT || "";
    const TenantItemId = bcs.struct("TenantItemId", {
        id: bcs.u64(),
        tenant: bcs.string(),
    });

    const TenantItemIdValue = {
        id: BigInt(itemId),
        tenant: tenant,
    };
    const serializedKey = TenantItemId.serialize(TenantItemIdValue).toBytes();
    const TenantItemIdTypeTag = `${packageId}::in_game_id::TenantItemId`;

    // Use the SDK's deriveObjectID function
    // This internally constructs: 0x2::derived_object::DerivedObjectKey<TenantItemIdTypeTag>
    // and derives the object ID using the same formula as Move
    return deriveObjectID(registryId, TenantItemIdTypeTag, serializedKey);
}
