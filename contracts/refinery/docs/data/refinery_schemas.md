# Refinery Schemas — Observed in-game (Stillness, Refinery 1)

Source: in-game UI screenshots from player `artokun`, 2026-05-15.
Total reported by UI: **21** schemas. Catalogued below: **21 / 21 ✓**.

Categories observed: `Mineral`, `Glint Ores`, `Hydrogen Fuel`, `Char Ores`,
`Dewdrop Ores`, `Salvage`, `Slag Ores`, `Ember Ores`, `Rift`, `Soot Ores`,
`Comet Ores`, `Ingot Ores`.

## Schemas

| # | Name | Category | Input | Run | Outputs |
|---|---|---|---|---|---|
|  1 | Silica Grains             | Mineral       | Silica Grains × 20             |  9s | Silicon Dust × 150 + Feldspar Crystal Shards × 50 |
|  2 | Aromatic Carbon Veins     | Glint Ores    | Aromatic Carbon Veins × 100    | 15s | Chitinous Organics × 1 + Aromatic Carbon Weave × 4 + Kerogen Tar × 8 |
|  3 | D2 Fuel                   | Hydrogen Fuel | D2 Fuel × 200                  |  3s | Salt × 1 |
|  4 | Eupraxite                 | Mineral       | Eupraxite × 10                 | 25s | EU-40 Fuel × 600 |
|  5 | Feldspar Crystals         | Char Ores     | Feldspar Crystals × 40         |  3s | Hydrocarbon Residue × 10 + Silica Grains × 30 |
|  6 | Iron-Rich Nodules         | Mineral       | Iron-Rich Nodules × 10         |  9s | Platinum-Group Veins × 20 + Nickel-Iron Veins × 198 |
|  7 | Methane Ice Shards        | Dewdrop Ores  | Methane Ice Shards × 100       | 15s | Chitinous Organics × 1 + Tholin Aggregates × 126 + Water Ice × 349 |
|  8 | Mummified Clone           | Salvage       | Mummified Clone × 5            |  3s | Aromatic Carbon Weave × 1 + Kerogen Tar × 1 + Water Ice × 50 |
|  9 | Platinum-Palladium Matrix | Slag Ores     | Platinum-Palladium Matrix × 40 |  3s | Silica Grains × 16 + Iron-Rich Nodules × 30 + Palladium × 8 |
| 10 | Primitive Kerogen Matrix  | Ember Ores    | Primitive Kerogen Matrix × 100 | 15s | Chitinous Organics × 1 + Kerogen Tar × 16 |
| 11 | Rough Old Crude Matter    | Rift          | Rough Old Crude Matter × 30    | 20s | Salt × 16 + Sophrogon × 28 |
| 12 | Rough Young Crude Matter  | Rift          | Rough Young Crude Matter × 30  | 20s | Salt × 1 + Eupraxite × 28 |
| 13 | Salvaged Materials        | Salvage       | Salvaged Materials × 10        |  4s | Carbon Weave × 1 + Thermal Composites × 2 + Reinforced Alloys × 6 |
| 14 | Sophrogon                 | Mineral       | Sophrogon × 10                 | 25s | SOF-40 Fuel × 600 |
| 15 | Tholin Nodules            | Soot Ores     | Tholin Nodules × 100           | 15s | Chitinous Organics × 1 + Aromatic Carbon Weave × 8 |
| 16 | Water Ice                 | Mineral       | Water Ice × 275                |  8s | D1 Fuel × 75 |
| 17 | Fine Old Crude Matter     | Rift          | Fine Old Crude Matter × 30     | 20s | Sophrogon × 6 + Brine × 26 |
| 18 | Fine Young Crude Matter   | Rift          | Fine Young Crude Matter × 30   | 20s | Eupraxite × 6 + Brine × 26 |
| 19 | Hydrated Sulfide Matrix   | Comet Ores    | Hydrated Sulfide Matrix × 40   |  3s | Hydrocarbon Residue × 20 + Water Ice × 300 |
| 20 | Hydrocarbon Residue       | Mineral       | Hydrocarbon Residue × 20       |  9s | Troilite Sulfide Grains × 20 + Tholin Aggregates × 180 |
| 21 | Iridosmine Nodules        | Ingot Ores    | Iridosmine Nodules × 40        |  5s | Iron-Rich Nodules × 40 |

## Cross-references / refining graph

Multi-stage refining paths (an output of one recipe is an input of another):

- **Iron-Rich Nodules** — input #6, output of #9, #21
- **Silica Grains** — input #1, output of #5, #9
- **Sophrogon** — input #14, output of #11, #17
- **Water Ice** — input #16, output of #7, #8, #19
- **Eupraxite** — input #4, output of #12, #18
- **Hydrocarbon Residue** — input #20, output of #5, #19
- **Tholin Aggregates** — output of #7, #20 (no input recipe → terminal product)
- **Aromatic Carbon Weave** — output of #2, #8, #15 (terminal)

Common multi-source outputs: **Chitinous Organics** (#2, #7, #10, #15),
**Kerogen Tar** (#2, #8, #10), **Salt** (#3, #11, #12), **Brine** (#17, #18).

## Implications for the proposed `world::recipe` registry

- The "input ≠ output **within a single recipe**" constraint enforced by
  `validate_recipe_args` holds for **all 21 observed schemas**.
- Multiple recipes can share output types — the registry already supports
  this (keyed by `input_type_id` only, no output uniqueness check).
- Multi-stage refining paths exist (e.g. Iridosmine Nodules → Iron-Rich
  Nodules → Platinum-Group Veins + Nickel-Iron Veins). The single-active-job
  per refinery v1 constraint still works — players queue stages manually,
  or future work adds chained recipes.
- Run-time tiers observed: **3s, 4s, 5s, 8s, 9s, 15s, 20s, 25s**. All fit
  in `u64` ms (the field type in this PR).
- Output quantities range from 1 (rare components) to 600 (fuel batches).
  Both fit in `u32`.

## Open questions

- **type_ids for these item names.** The dapp-kit sandbox doc lists a few:
  Feldspar Crystals (77800), Hydrated Sulfide Matrix (77811), Carbon Weave
  (84210), Printed Circuits (84180), Reinforced Alloys (84182), Thermal
  Composites (88561), Building Foam (89089). The full mapping (~50+ unique
  items across these 21 schemas) needs the WorldAPI / GraphQL.
- **Categories** (`Mineral`, `Glint Ores`, etc.) — intrinsic to the input
  item type, or orthogonal tags? If intrinsic, no schema field needed; if
  orthogonal, `Recipe.category: String` should be added.
- **Does the existence of a schema depend on the refinery's `type_id`?**
  Refinery 1 here is type_id 88063 and shows all 21 schemas. Different
  refinery hardware may expose different subsets — needs another refinery's
  schema list to confirm. If so, the registry needs a per-refinery-type
  whitelist (or recipe.refinery_type_ids: vector<u64>).
- **"Required items available" tag** (visible on #20 in the player's
  screenshot) — server-side UI affordance computed from the refinery's
  current input inventory. The on-chain `recipe` doesn't need to encode
  this; clients compute it themselves from inventory state.
