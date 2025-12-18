# PRIORITY: Terrain Loading Configuration

## Issue Encountered (December 2024)

We spent significant time trying to implement proper time gaps between chunk loading to prevent FPS stuttering during terrain generation. The current system has these pain points:

### Problems Identified
1. **Burst loading** - Chunks load in bursts instead of gradually, causing FPS drops
2. **Complex pipeline** - GPU thread, CPU workers, and main thread all interact in non-obvious ways
3. **Delay placement** - The `exploration_delay_ms` delay is inside nested conditions and doesn't reliably apply to each chunk
4. **Queue buildup** - Main thread queues chunks faster than GPU thread processes them

### Current Workarounds
- `process_pending_nodes()` now processes exactly 1 chunk per frame
- Various frame budget limits applied

### Future Priority
**Before adding new features, implement proper terrain loading configuration:**

1. **Expose loading parameters in inspector:**
   - Chunks per second (not per frame)
   - Minimum delay between chunks (guaranteed)
   - Queue size limits

2. **Decouple the pipeline:**
   - Clear separation between queuing, generation, and finalization
   - Each stage should respect independent throttling

3. **Real-time feedback:**
   - Debug overlay showing queue sizes, pending nodes, current delay
   - Easy way to tune while game is running

4. **Consider:**
   - Priority-based loading (closest chunks first)
   - Spiral/ring loading pattern instead of grid iteration
