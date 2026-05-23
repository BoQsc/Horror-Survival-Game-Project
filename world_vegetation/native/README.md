# Vegetation Native

The production native classes are registered in the existing high-performance
GDExtension under `gdextension/src/` so the game loads one native library:

- `VegetationChunkBuilder`: builds chunk mesh arrays for high-volume grass.
- `VegetationSpatialGridNative`: native chunk-coordinate spatial queries.

This folder is reserved for vegetation-specific native design notes and future
backend glue. Keep runtime orchestration in GDScript; move hot loops here only
after they have a stable data interface.
