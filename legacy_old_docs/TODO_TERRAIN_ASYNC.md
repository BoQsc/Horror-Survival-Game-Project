# TODO: Async Terrain Modification Completion Signal

## Problem
The terrain modification system (`chunk_manager.gd`) performs GPU-based terrain edits asynchronously but does not provide a reliable signal or callback to know when modifications are **visually complete** (mesh updated and rendered).

## Current Flow
1. `modify_terrain()` is called → task added to GPU thread queue
2. GPU processes modification → updates density buffer
3. Mesh is rebuilt (CPU workers)
4. Node is created/updated via `pending_nodes` queue
5. **No external signal** to indicate completion

## Impact
Operations that need to sequence terrain modifications (like "carve then fill" for prefab placement) cannot reliably synchronize. Polling internal queues (`pending_batches`, `task_queue`, `pending_nodes`) is unreliable because:
- Queues may appear empty before tasks are dispatched
- Timing between GPU and CPU phases is unpredictable
- `chunk_modified` signal exists but timing is inconsistent

## Proposed Solution
Add a method to `chunk_manager.gd`:
```gdscript
signal modification_complete(batch_id: int)

## Call this to request a completion callback
func modify_terrain_with_callback(pos, radius, value, shape, layer, material_id) -> int:
	# Returns a batch_id
	# Emits modification_complete(batch_id) when mesh is updated
```

## Workaround (Current)
For prefab "Carve+Fill" mode, use a fixed time delay (5 seconds) to allow terrain changes to complete. This is not ideal but works for most cases.
