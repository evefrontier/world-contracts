/// Power grid component installed on an `Entity`: one per Creation. Pools the
/// capacity of its Generators and the fuel of its Fuel components, and grants Firm or
/// Elastic draws to connected modules.
///
/// See `docs/adr/0005-onchain-power-network.md`.
module power::power_grid;
