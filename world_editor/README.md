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
