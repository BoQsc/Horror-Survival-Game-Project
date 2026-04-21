# Temporary Building Instant-Load Manifest

This is the working contract for baked buildings on branch `54-world-map-caching-and-data`.
It is temporary by design and should be replaced only after the runtime behavior is proven stable.

## Goal

Baked buildings must appear fully and immediately when their chunk enters render distance.
That load must preserve authored simulation behavior:

- walls still block the player
- stairs and slabs keep their intended collision shape
- doors, windows, and interior objects stay visible
- breakable objects remain breakable
- visible buildings do not depend on interaction to finish loading

## Hard Rules

- Do not hide gameplay objects to gain performance.
- Do not delay visible buildings behind per-object promotion passes.
- Do not cull doors, windows, chairs, or other authored interior props while the chunk is visible.
- Do not replace authored stairs/slabs with a generic box shape unless the authored shape is proven broken and the fallback is explicitly temporary.
- Do not require player interaction to make a visible building finish loading.
- Do not trade simulation correctness for lower node counts.

## Runtime Contract

When a baked chunk is inside render distance:

1. The chunk is added to the scene tree immediately.
2. The baked snapshot is restored in one pass.
3. Mesh, collision, and object state are all present for that chunk.
4. The chunk behaves like authored content, not a proxy or approximation.

When a chunk is outside render distance:

- keep the baked data cached
- keep it out of the live scene tree
- do not mutate the baked state just to save nodes

## Bake Contract

The bake output must contain the full chunk package needed for runtime restore:

- block data
- object data
- transforms and rotation
- authored collision descriptors
- interaction metadata
- any per-chunk visual data needed to rebuild the chunk exactly

The bake format may be optimized internally, but it must still reconstruct the same gameplay result at runtime.

## Temporary Acceptance Checks

Use these as pass/fail checks for any follow-up change:

- buildings are visible on first arrival to the chunk
- no loading-screen workaround is needed to reveal buildings
- stairs and slabs can be walked on normally
- walls cannot be walked through
- doors stay visible without requiring `E`
- windows stay visible when moving away and back
- breakable objects still break under attack
- no Jolt body-cap warning appears during the town smoke

## Temporary Non-Goals

These are not the priority right now:

- proxy-shell batching experiments
- object hiding based on distance
- global visual batch promotion experiments
- any rewrite that changes gameplay semantics just to reduce node counts

## Status

This manifest is the current working agreement for fixing the building pipeline.
If a future change conflicts with it, the change should be rejected unless the manifest is intentionally updated first.
