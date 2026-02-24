# World Editor

2D world map editor for generating, painting, and saving 2048×2048 world definitions.

## Files
- `world_editor.tscn` / `world_editor.gd` — Editor UI scene
- `world_map_generator.gd` — Terrain/biome/road PNG generation

## Performance Note

Current generation uses **GDScript + FastNoiseLite** which is functional but slow for 2048×2048 (4M pixels).

### Future Optimization Options

1. **GPU Compute Shader** (recommended — fastest)
   - Write a GLSL compute shader that generates the heightmap/biome/road images directly on the GPU
   - Can reuse the existing `gen_density.glsl` noise functions almost verbatim
   - Output to a storage texture, read back to CPU with `RenderingDevice.texture_get_data()`
   - Expected: **sub-second** generation for 2048×2048

2. **GDExtension (C++)**
   - Port the generation loop to C++ via the existing GDExtension setup (`gdextension/`)
   - FastNoiseLite is already C++ under the hood — the bottleneck is the GDScript loop + road math
   - Moving the loop to C++ would give ~50-100x speedup
   - Expected: **1-3 seconds** for 2048×2048

3. **Hybrid: Low-Res Preview + Full-Res on Save**
   - Generate at 512×512 for interactive editing (16x fewer pixels)
   - Upscale to 2048×2048 only when saving/exporting
   - Quick interim solution, no native code needed

## Height Constraint (IMPORTANT)

Terrain heights **must fit within a single Y=0 chunk** (0–32 voxels). The height formula is:

```
height = terrain_height + noise[0..1] × terrain_height
       = terrain_height × (1 + noise)
max_height = 2 × terrain_height
```

**Rule: `terrain_height` must be ≤ 15.0** (so max height = 30, safely within chunk bounds of 32).

| `terrain_height` | Height Range | Fits in chunk? |
|---|---|---|
| 10.0 (default) | [10, 20] | ✅ |
| 15.0 (max safe) | [15, 30] | ✅ |
| 20.0 (old default) | [20, 40] | ❌ See-through holes! |

This constraint is:
- **Enforced** in `world_map_generator.gd` (clamps to 15.0 with a warning)
- **Safety-netted** in `gen_density.glsl` (shader clamps decoded height to [1, 28])
- The procedural system (`chunk_manager.gd`) uses `terrain_height=10.0` by default and works correctly

## Parameter Alignment

Generator defaults **must match** `chunk_manager.gd` procedural defaults for comparable terrain quality:

| Parameter | `chunk_manager.gd` | `world_map_generator.gd` |
|---|---|---|
| `terrain_height` | 10.0 | 10.0 |
| `noise_frequency` | 0.1 | 0.1 |
| `road_spacing` | 100.0 | 100.0 |
| `road_width` | 8.0 | 8.0 |

> [!NOTE]
> The noise functions differ (GPU custom hash vs CPU FastNoiseLite `TYPE_VALUE`), so terrain patterns won't be identical — but height range and feature scale will match.

## Terrain Presets

The world editor offers terrain style presets that auto-fill `terrain_height` and `noise_freq`:

| Preset | `terrain_height` | `noise_freq` | Character |
|---|---|---|---|
| **Flat** | 3.0 | 0.02 | Nearly flat, ideal for city-building |
| **Plains** | 5.0 | 0.05 | Gentle rolling, mostly above water |
| **Hills** (default) | 10.0 | 0.1 | Matches procedural defaults |
| **Mountains** | 14.0 | 0.15 | Dramatic peaks, deep valleys |

Users can still override individual values after selecting a preset.

## Future: GPU-Identical Generation

> [!IMPORTANT]
> To achieve **pixel-perfect matching** with procedural terrain, run the **same GPU shader** to generate the heightmap instead of CPU noise.

Current pipeline has a mismatch:
```
CPU (FastNoiseLite TYPE_VALUE) → PNG → GPU (shader reads PNG)
```

Ideal pipeline:
```
GPU (gen_density.glsl) → PNG → GPU (shader reads PNG)
```

**Implementation plan:**
1. Write a compute shader that samples `get_density()` at Y=surface for a 2048×2048 XZ grid
2. Dispatch on `RenderingDevice`, read back with `texture_get_data()`
3. Save as heightmap PNG (same format as current)
4. Same approach for biome + road data
5. Result: identical terrain because it's literally the same noise code

This also solves the performance issue (sub-second generation vs current ~10s GDScript loop).
