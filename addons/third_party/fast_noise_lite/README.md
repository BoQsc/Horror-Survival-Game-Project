# FastNoiseLite

This folder is an isolated third-party exception to the project's CC0 source
policy.

- Source: Godot Engine `4.6.3-stable`, `thirdparty/misc/FastNoiseLite.h`
- Upstream: https://github.com/godotengine/godot
- License: MIT, retained in the header
- Reason: worker-safe native world-map height/biome baking needs the same
  header-only noise implementation that Godot's `FastNoiseLite` wrapper uses,
  without allocating or calling Godot `Resource` objects from GDExtension worker
  threads.

Project-owned code outside this folder remains under the repository's CC0
license.
