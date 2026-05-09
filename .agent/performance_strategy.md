# Performance Strategy

We are changing from implementation guesses to an observability-first performance workflow.

## Goal

Reach smooth 60 FPS with headroom for future gameplay, including sustained driving and 100+ active entities, without reducing simulation, terrain, buildings, vegetation, collision, visual quality, lighting, water, shadows, or gameplay scope.

## Hard Rules

- Do not fake performance by reducing entities, terrain, buildings, vegetation, simulation, collisions, or gameplay.
- All simulation remains active.
- Terrain collision remains full per chunk.
- Player falling through terrain, failing to teleport, or getting stuck waiting for terrain is a serious regression.
- No visual regressions unless explicitly approved.
- Only run one game instance at a time.
- Town tests run one after another, never in parallel.
- Use `TOWN_STALL_RENDER_DISTANCE=10` for town stall testing.

## Workflow

1. Add or improve performance instrumentation first.
2. Run a baseline that produces a concrete report.
3. Identify the largest measured bottleneck.
4. Add aggressive candidate optimizations behind toggles or narrow code paths where possible.
5. Run the same test matrix again.
6. Keep only changes that prove a benefit without visual, collision, simulation, or loading regressions.
7. Remove temporary debug after the investigation unless it is useful permanent telemetry.
8. Commit instrumentation separately from performance changes.
9. Commit performance changes only when the report proves they improve the target metric or remove a demonstrated stall.

## Black Box Recorder Metrics

Capture phase timings and counters for:

- Terrain task queue wait time.
- Density compute dispatch.
- Marching Cubes dispatch.
- GPU submit and sync wait.
- GPU buffer readback.
- Native mesh decode/build.
- ArrayMesh creation/upload.
- Collision shape build and install.
- Main-thread chunk scene apply.
- Loading screen elapsed seconds.
- Frame time percentiles and worst spikes.
- Pending terrain nodes/chunks.
- Vegetation batch sync, collect, pack, and upload.
- Building batch sync, collect, pack, and upload.
- Visible chunk, mesh, MultiMesh, triangle, entity, building, and vegetation counts.

## Experiment Style

Use an ablation matrix: same test, same settings, one meaningful toggle changed per row. Candidate areas include:

- Avoiding GPU readback stalls.
- Reducing forced `RenderingDevice.sync()` waits.
- Keeping terrain data binary/native longer.
- Reusing GPU and CPU buffers.
- Active-cell classification and compaction before mesh generation.
- Tighter chunk or cluster render batches instead of oversized global batches.
- Native/GDExtension packing and decoding where GDScript loops are hot.
- Better work scheduling for mesh upload, collision readiness, vegetation, and building batches.

## Acceptance

A performance change is accepted only if it:

- Improves measured FPS, stall time, loading time, or frame-time percentiles.
- Preserves full terrain collision readiness.
- Preserves visual output.
- Preserves simulation and gameplay behavior.
- Is tested against the same baseline scenario.

If the result is slower, ambiguous, or only feels better, revert or keep it only as a disabled experiment.
