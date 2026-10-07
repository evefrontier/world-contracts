# Item type_id reference for the 21 refinery schemas

Source: live query of EVE Frontier WorldAPI (`/v2/types`) at
`https://world-api-utopia.uat.pub.evefrontier.com/v2/types`, 2026-05-15.

All 39 unique items referenced by the 21 schemas in [`refinery_schemas.md`](./refinery_schemas.md):

| type_id | Name | Group | Category | Volume | Portion |
|---|---|---|---|---|---|
| 77728 | Sophrogon | Mineral | Material | 1 | 10000 |
| 77729 | Rough Old Crude Matter | Rift | Asteroid | 1 | 10000 |
| 77800 | Feldspar Crystals | Char Ores | Asteroid | 1 | 10000 |
| 77801 | Nickel-Iron Veins | Mineral | Material | 0.10000000149011612 | 10000 |
| 77803 | Silicon Dust | Mineral | Material | 0.10000000149011612 | 10000 |
| 77804 | Tholin Aggregates | Mineral | Material | 0.10000000149011612 | 10000 |
| 77805 | Platinum-Group Veins | Mineral | Material | 0.009999999776482582 | 10000 |
| 77810 | Platinum-Palladium Matrix | Slag Ores | Asteroid | 1 | 10000 |
| 77811 | Hydrated Sulfide Matrix | Comet Ores | Asteroid | 1 | 10000 |
| 78423 | Water Ice | Mineral | Material | 0.10000000149011612 | 10000 |
| 78426 | Iridosmine Nodules | Ingot Ores | Asteroid | 1 | 10000 |
| 78434 | Rough Young Crude Matter | Rift | Asteroid | 1 | 10000 |
| 78435 | Eupraxite | Mineral | Material | 1 | 10000 |
| 78446 | Methane Ice Shards | Dewdrop Ores | Asteroid | 1 | 10000 |
| 78447 | Primitive Kerogen Matrix | Ember Ores | Asteroid | 1 | 10000 |
| 78448 | Aromatic Carbon Veins | Glint Ores | Asteroid | 1 | 10000 |
| 78449 | Tholin Nodules | Soot Ores | Asteroid | 1 | 10000 |
| 78516 | EU-40 Fuel | Crude Fuel | Commodity | 0.2800000011920929 | 357143 |
| 83839 | Salt | Mineral | Material | 0.10000000149011612 | 10000 |
| 84182 | Reinforced Alloys | Manufacturing Component | Material | 10 | 2000 |
| 84210 | Carbon Weave | Manufacturing Component | Material | 15 | 2000 |
| 84868 | SOF-40 Fuel | Crude Fuel | Commodity | 0.2800000011920929 | 357143 |
| 88234 | Troilite Sulfide Grains | Mineral | Material | 0.10000000149011612 | 10000 |
| 88235 | Feldspar Crystal Shards | Mineral | Material | 0.10000000149011612 | 10000 |
| 88319 | D2 Fuel | Hydrogen Fuel | Commodity | 0.2800000011920929 | 357143 |
| 88335 | D1 Fuel | Hydrogen Fuel | Commodity | 0.2800000011920929 | 357143 |
| 88561 | Thermal Composites | Manufacturing Component | Material | 10 | 2000 |
| 88764 | Salvaged Materials | Salvage | Commodity | 5 | 10000 |
| 88765 | Mummified Clone | Salvage | Commodity | 0.20000000298023224 | 10000 |
| 88781 | Chitinous Organics | Manufacturing Component | Material | 10 | 2000 |
| 88782 | Aromatic Carbon Weave | Manufacturing Component | Material | 0.10000000149011612 | 2000 |
| 88783 | Kerogen Tar | Manufacturing Component | Material | 0.30000001192092896 | 2000 |
| 89258 | Hydrocarbon Residue | Mineral | Material | 1 | 10000 |
| 89259 | Silica Grains | Mineral | Material | 1 | 10000 |
| 89260 | Iron-Rich Nodules | Mineral | Material | 1 | 10000 |
| 92394 | Fine Young Crude Matter | Rift | Asteroid | 1 | 10000 |
| 92414 | Fine Old Crude Matter | Rift | Asteroid | 1 | 10000 |
| 92422 | Brine | Mineral | Material | 0.10000000149011612 | 10000 |
| 99001 | Palladium | Manufacturing Component | Material | 5 | 1 |

## Notes

- The WorldAPI lives at the Utopia (sandbox) URL; type definitions are game-data constants and should be identical across Stillness and Utopia.
- `volume` (m³) and `portion_size` (mint batch) are useful for `recipe::register_recipe` and `inventory::mint_items` constraints.
- Categories `Mineral`, `Char Ores`, `Comet Ores`, etc. map directly to the `category` field shown in the in-game refinery SCHEMA tab.
- Asteroids (raw inputs) have `categoryName=Asteroid`; refined products are `categoryName=Material` or `Commodity`.
