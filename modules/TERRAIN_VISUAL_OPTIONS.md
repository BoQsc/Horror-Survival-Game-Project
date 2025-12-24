# Terrain Shader Visual Options

## Visual Toggles (terrain.gdshader)

Two uniform toggles affect visual accuracy vs aesthetics:

```glsl
uniform bool biome_blending_enabled = true;   // Per-pixel biome color blending
uniform bool cliff_rock_enabled = true;       // Rocky texture on steep slopes
```

### For Accurate Material Targeting
**Disable both** to ensure visual appearance exactly matches material indicator:
- `biome_blending_enabled = false`
- `cliff_rock_enabled = false`

When enabled, these create visual overrides that may show different textures than the underlying material ID.

---

## Future Considerations

### Milder Blending Approach
Could implement a subtler blending that:
- Only affects edge pixels (not entire biome areas)
- Uses smaller blend width for minimal visual/indicator mismatch

**Concern:** May not help visually while still interfering with material clarity.

### Custom Blend Texture
Alternative approach:
- Use a dedicated blend/transition texture at biome boundaries
- Separate from material textures, purely decorative
- Would not affect material detection at all

**Status:** Uncertain if worth implementing - needs visual testing.
