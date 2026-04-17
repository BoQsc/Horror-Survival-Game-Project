# Town 60 FPS Next Options

Last updated: 2026-04-17

This is a future-facing shortlist for the next performance pass. Keep it aligned with the current checkpoint and use it only after a clean baseline run.

## Current Baseline

- Latest valid town-entry run was about `14.464 ms` average frame time at `2400 MHz`.
- Active physics entities were around `28`, with about `7` frozen.
- The current relevance policy keeps zombies active closer to the player so the town feels alive.

## Best Next Options

- Reduce live zombie runtime cost without skipping movement ticks.
- Split relevance into tiers: active, grounded-visible, and hidden.
- Make entity manager scans ring-aware so outer rings cost less than inner rings.
- Add far-visible visual LOD for zombies, but keep visible behavior honest.
- Reuse the same relevance policy for future projectiles and distant players.

## Guardrails

- No collision-shape tricks as a performance shortcut.
- No walk throttling that makes zombies look stuck or unable to move.
- No freezing visibly relevant zombies deep inside the draw radius.
- No proxying or disabling gameplay objects that players can still meaningfully see or use.

## Suggested Order

1. Measure the cost of live zombie AI and sensing first.
2. Tune tiered relevance only if the town still needs more headroom.
3. Add visual-only LOD for truly distant zombies if the first two passes are not enough.
