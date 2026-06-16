import { bcs } from "@mysten/sui/bcs";
import { deriveObjectID } from "@mysten/sui/utils";
import type { WorldConfig } from "./config/types.js";
import { objectRegistry } from "./config/shared-objects.js";

const CORE_PACKAGE = "core";

const EntityKey = bcs.struct("EntityKey", {
    id: bcs.u64(),
    tenant: bcs.string(),
});

export interface EntityKeyInput {
    id: bigint;
    tenant: string;
}

/**
 * Deterministic object ID for an entity, mirroring core
 * `object_registry::derive_id` (a `derived_object` over `EntityKey{id, tenant}`).
 * Offline: needs the core package id, which only local/CI carry in
 * `packageOverrides`.
 */
export function deriveObjectId(config: WorldConfig, key: EntityKeyInput): string {
    const coreId = config.packageOverrides?.[CORE_PACKAGE];
    if (!coreId) {
        throw new Error(
            `cannot derive object id for env "${config.env}" offline: no core package id (only local/CI supply packageOverrides)`
        );
    }
    const registryId = objectRegistry(config).id;
    const bytes = EntityKey.serialize({ id: key.id, tenant: key.tenant }).toBytes();
    return deriveObjectID(registryId, `${coreId}::entity_key::EntityKey`, bytes);
}
