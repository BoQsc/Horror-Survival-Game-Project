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

Target:

- Long-term baseline goal: about `16 WPF60` for the whole game.
- Do not improve `WPF60` by lowering render distance below 10, disabling VSync, switching renderer, or enabling vegetation LOD/proxies unless that specific experiment is explicitly requested.
