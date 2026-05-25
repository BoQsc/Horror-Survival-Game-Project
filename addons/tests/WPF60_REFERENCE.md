# WPF60 Reference

`WPF60` means watts per 60 FPS frame. It is the main project metric for comparing power cost while preserving the 60 FPS target.

Formula:

```text
WPF60 = GPU watts * frame_ms / 16.667
```

Use `hold_wpf60` for stationary town baseline comparisons and `moving_wpf60` for moving-entry comparisons.

Interpretation:

- Lower is better.
- At exactly 60 FPS, `WPF60` equals raw GPU watts.
- Above 16.667 ms, it penalizes runs that miss the 60 FPS target.
- Raw watts still matter, but `WPF60` is the primary comparison metric when frame time differs between runs.
- `WPF60/Mprim`, `WPF60/100draw`, and `WPF60/100obj` are diagnostics only. They help identify whether an experiment is improving efficiency per rendered workload or merely hiding/removing workload.

Target:

- Long-term baseline goal: about `16 WPF60` for the whole game.
- Do not improve `WPF60` by lowering render distance below 10, disabling VSync, switching renderer, or enabling vegetation LOD/proxies unless that specific experiment is explicitly requested.

Vegetation efficiency rules:

- Native/GDExtension work is justified when profiling shows CPU-side vegetation generation, spatial queries, road filtering, or MultiMesh buffer packing causes stalls or loading spikes.
- Compute shaders are justified only for measured GPU-side generation/culling problems where synchronization/readback cost is understood. They are not a first-line fix for high steady-state GPU watts.
- For the current no-LOD baseline, prioritize measurement of visible primitives, draw/object counts, material/alpha cost, vegetation batch bounds, and dirty-batch rebuild time before replacing the renderer path.
- Native vegetation generation must preserve road masks plus harvested/chopped/removed persistence before it is considered a valid optimization.
- Road/water mask optimization is valid only if it preserves the same spawn-blocking rules; prefer batched byte-array reads over per-sample image queries when the source data is identical.
