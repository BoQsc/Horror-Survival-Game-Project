---
trigger: always_on
---

# Performance Policy

Use this project rule set whenever working on performance:

- Preserve gameplay first.
- Do not change render distance, collision distance, visibility, or interaction range as a performance shortcut without explicit approval.
- Do not use prewarm as the primary solution. It is only a temporary mitigation if ever needed.
- Do not hide stalls by adding async scheduling unless it also reduces total work.
- Profile first, then change only one thing at a time.
- Use fixed baselines for comparison, preferably the same world seed and the same town entry path.
- Treat any visual or gameplay change as a risk that must be called out before keeping it.

Preferred order of attack:

1. Identify the dominant bucket in the snapshot.
2. Reduce the actual work with an algorithm or data-structure improvement.
3. Move hot CPU loops to GDExtension when the same behavior still costs too much.
4. Use shaders only for render-side work.
5. Keep mitigation tactics last, not first.

Hard rules:

- No random chunk loading.
- No distance-based disabling of collisions or gameplay objects.
- No broad visual downgrades to mask a frame spike.
- No speculative optimization without a baseline comparison.
