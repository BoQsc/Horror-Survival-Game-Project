---
trigger: always_on
---

# Performance Policy

Use this project rule set whenever working on performance:

- Preserve gameplay first.
- Preserve visuals and interaction first. Do not change how objects look or how the player interacts with them unless the user explicitly approves that tradeoff.
- Treat any breakable, openable, pick-upable, or scripted object as gameplay-critical until proven otherwise. Do not turn it into a visual-only proxy, batch record, or disabled collider without checking its scene/script behavior first.
- Do not change render distance, collision distance, visibility, or interaction range as a performance shortcut without explicit approval.
- Do not use prewarm as the primary solution. It is only a temporary mitigation if ever needed.
- Do not hide stalls by adding async scheduling unless it also reduces total work.
- Profile first, then change only one thing at a time.
- Prefer the simplest algorithm that meets the target. Do not add clever complexity unless the profiling result clearly proves it is needed.
- Use fixed baselines for comparison, preferably the same world seed and the same town entry path.
- Treat any visual or gameplay change as a risk that must be called out before keeping it.
- Do not minimize, focus, or otherwise steal attention from other windows during automated tests. Background test runs must be non-intrusive.

Preferred order of attack:

1. Identify the dominant bucket in the snapshot.
2. Reduce the actual work with an algorithm or data-structure improvement.
3. Move hot CPU loops to GDExtension when the same behavior still costs too much.
4. Use shaders only for render-side work.
5. Keep mitigation tactics last, not first.

Hard rules:

- No random chunk loading.
- No distance-based disabling of collisions or gameplay objects.
- No replacing interactable objects with placeholder visuals unless the user explicitly approves that tradeoff.
- No broad visual downgrades to mask a frame spike.
- No batching or proxying that changes the look of gameplay objects like windows, doors, crates, pistols, stones, or plants unless explicitly approved.
- No speculative optimization without a baseline comparison.
