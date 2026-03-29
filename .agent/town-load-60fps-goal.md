# Town Load 60 FPS Goal

Last updated: 2026-03-29

This tracker is for the broader goal of making town entry feel immediate and keeping the game at a stable 60 FPS-feeling baseline without changing gameplay, visuals, interaction, or sandbox behavior.

## Core Questions

- Can buildings load "instantly" enough that the player does not notice the loading?
- Can we keep enough headroom that town entry stays comfortably above a 20 FPS safety floor while aiming for 60 FPS stability?
- Can we do that with simple algorithm changes first, then only use GDExtension or shader work if profiling proves they are the right tool?

## Current Answer

- Literal instant loading is only realistic if the expensive work is moved out of the visible entry path.
- That means precomputing, caching, and front-loading internal data is fair game.
- It does not mean hiding objects, delaying gameplay props, or changing what the player sees.
- A "20 FPS safety" target should be treated as an internal headroom margin, not as a gameplay mode.
- The real target remains a stable 60 FPS-feeling town entry with no visible degradation.
- The current fixed-seed validation run is already in that safe range: town peak is about `15.0 ms` with `0` frames over `40 ms`, so the existing load-time caching path is doing the right kind of work.

## Rules

- Keep visuals, interaction, colliders, shadows, and authored scenes intact.
- Do not use placeholder proxies or delayed object appearance for gameplay props.
- Prefer the simplest algorithm that actually reduces the peak.
- Use GDExtension only for hot CPU loops that keep behavior identical.
- Use shaders only if profiling proves the remaining bottleneck is truly GPU/render-side.
- Do not trade away sandbox behavior just to make the frame graph look better.

## What We Can Still Safely Change

- Prefab loading and metadata caching.
- Spawn ordering and chunk-local bookkeeping.
- Load-time precomputation for repeated placement data.
- Use cached occupied footprints for both collision checking and placement so the spawn loop does not rebuild the same footprint twice.
- Native helpers for internal hot loops if they preserve the exact same results.
- Render bookkeeping only if it does not change the visible scene.

## Current Direction

- Keep the current load-time caching path as the baseline.
- Only touch the remaining town work if profiling proves there is a measurable win.
- If we go further, prefer a tiny native helper for the last hot CPU loop over another layer of custom caching.

## What We Should Not Change

- Gameplay object visibility.
- Door/window/crate/pistol/table behavior.
- Object colliders that affect play.
- Lighting/shadows as a fake performance fix.
- Roads or vegetation as a workaround for town stall.

## Measurement Rule

- Use the fixed-seed town route as the comparison baseline.
- Only keep changes that improve the town-entry burst without introducing empty-town behavior or gameplay regressions.
- If a change does not move the real entrance peak, drop it.
