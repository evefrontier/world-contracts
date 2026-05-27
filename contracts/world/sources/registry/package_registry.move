/// Unified registry to track the upgrade lineage of world packages.
///
/// Due to the nature of the Move module system on Sui, package upgrades
/// create a new package ID. While MVR (Move Registry) allows resolving
/// to the latest package ID, certain off-chain systems—like Indexers—need
/// to track the entire history of package IDs to properly ingest events
/// emitted by older versions of the modules.
///
/// This registry solves that by maintaining an on-chain `vector<address>`
/// containing every package ID the system has ever lived at. Authorized
/// sponsors can append to this array whenever a package upgrade is performed,
/// ensuring that indexers and other services can dynamically query this single
/// source of truth to discover all historical and current package IDs.
module world::package_registry {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::transfer;
    use std::vector;
    use world::access::AdminACL;

    public struct PackageRegistry has key {
        id: UID,
        /// Array of all package IDs in the upgrade lineage
        package_ids: vector<address>
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(PackageRegistry {
            id: object::new(ctx),
            package_ids: vector::empty(),
        });
    }

    /// Appends a new package ID to the registry upon an upgrade.
    /// Only an authorized sponsor/admin can execute this.
    public fun add_package_id(
        registry: &mut PackageRegistry,
        admin_acl: &AdminACL,
        package_id: address,
        ctx: &TxContext
    ) {
        admin_acl.verify_sponsor(ctx);
        registry.package_ids.push_back(package_id);
    }
}
