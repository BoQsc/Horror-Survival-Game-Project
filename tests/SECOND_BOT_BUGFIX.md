# Second Bot-Discovered Bugfix - Early QuickLoad Fall-Through

**Date:** January 4, 2026  
**Bug:** QuickLoad at game start causes player and entities to fall through terrain  
**Status:** ✅ **FIXED & BOT-VERIFIED**

---

## Bot Test Results

### BEFORE Fix
```
[QUICKLOAD_FALL_TEST] Player found at Y: 110.75
[QUICKLOAD_FALL_TEST] T+0.5s: Y=11.25
[QUICKLOAD_FALL_TEST] T+1.0s: Y=7.81
[QUICKLOAD_FALL_TEST] ❌ TEST FAILED - Player FELL THROUGH TERRAIN
[QUICKLOAD_FALL_TEST] Fell: -103.40 units
```

### AFTER Fix
```
[QUICKLOAD_FALL_TEST] Player found at Y: 111.08
[QUICKLOAD_FALL_TEST] T+2.5s: Y=12.00  (landed on terrain!)
[QUICKLOAD_FALL_TEST] T+3.0s through T+10.0s: Y=12.00  (STABLE!)
[QUICKLOAD_FALL_TEST] ✅ TEST PASSED - Player did NOT fall through terrain
```

---

## Root Cause

**File:** `save_manager_v2.gd` line 451

Player position was restored **immediately** during `load_game()`, before terrain collision meshes were built:

```gdscript
func _load_player_data(data: Dictionary):
    if data.has("position"):
        player.global_position = player_pos  # ❌ SET TOO EARLY!
```

**Timing Issue:**
1. Game starts → Terrain begins generating
2. 2 seconds later → Bot triggers QuickLoad (F8)
3. SaveManager calls `_load_player_data()` → Sets position immediately
4. Player spawns at Y=110 with **no collision mesh below**
5. Player falls 103 units through "invisible" terrain

---

## The Fix

### Changes to `save_manager_v2.gd`

#### 1. Added Tracking Flag (line 38)
```gdscript
var pending_player_position_restore: bool = false  # Fix: defer position until terrain collision ready
```

#### 2. Modified `_load_player_data()` (lines 441-469)
**Before:**
```gdscript
if data.has("position"):
    player.global_position = player_pos  # Set immediately
if data.has("rotation"):
    player.rotation = _array_to_vec3(data.rotation)  # Set immediately
```

**After:**
```gdscript
pending_player_position_restore = (data.has("position") or data.has("rotation"))

# FIX: Don't set position/rotation here - defer until terrain collision ready!
if data.has("position"):
    player_pos = _array_to_vec3(data.position)
    # player.global_position = player_pos  # REMOVED
# Camera pitch and flying state are safe (don't affect physics)
```

#### 3. Added Restoration in `_on_spawn_zones_ready()` (lines 259-266)
```gdscript
# FIX: Restore player position/rotation NOW that terrain collision is ready
if pending_player_position_restore and player and not pending_player_data.is_empty():
    if pending_player_data.has("position"):
        player.global_position = _array_to_vec3(pending_player_data.position)
    if pending_player_data.has("rotation"):
        player.rotation = _array_to_vec3(pending_player_data.rotation)
    pending_player_position_restore = false
```

---

## How It Works

### New Flow
1. **Load Triggered** → `_load_player_data()` called
2. **Store Position** → Saved in `pending_player_data`
3. **Set Flag** → `pending_player_position_restore = true`
4. **Request Terrain** → `chunk_manager.request_spawn_zone(player_pos, 2)`
5. **Wait for Signal** → Terrain builds collision meshes
6. **`spawn_zones_ready` fires** → `_on_spawn_zones_ready()` called
7. **Restore Position** → NOW safe to set `player.global_position`

### Delay Trade-off
- Position restore delayed by **~0.5-2.5 seconds** (terrain collision build time)
- Player falls gently to terrain instead of falling through it
- Acceptable trade-off vs 103-unit fall-through bug

---

## Impact

### What Gets Fixed
- ✅ Player no longer falls through terrain on early QuickLoad
- ✅ Entities (zombies) also benefit (they wait for terrain too)
- ✅ Consistent with existing vehicle deferral pattern

### What Doesn't Change
- Normal QuickLoad (mid-game) → Position restores immediately (terrain already exists)
- Full game loads → Position restores immediately (scene reload handles it)

---

## Bot Testing Methodology

### Test Bot: `quickload_fall_test_bot.gd`
```gdscript
1. Wait 2 seconds (minimal initialization)
2. Press F8 (QuickLoad)
3. Monitor playerY position every 0.5s for 10 seconds
4. If Y < 10.0 → FAIL (fell through)
5. If Y stable for 10s → PASS
```

### Why This Test Works
- **Reproduces exact user scenario:** Early QuickLoad at game start
- **Quantifies the bug:** -103 unit fall measurable
- **Verifies the fix:** Stable Y=12 for 10 seconds confirms landing

---

## Files Modified

- **`save_manager/save_manager_v2.gd`** (3 changes)
  - Line 38: Added `pending_player_position_restore` flag
  - Lines 441-469: Modified `_load_player_data()` to defer position
  - Lines 259-266: Modified `_on_spawn_zones_ready()` to restore position

---

## Lessons Learned

### Bot-Driven Development Wins Again
1. **Instant Reproduction:** Bot reproduced bug in 13 seconds
2. **Quantified Impact:** Measured exact fall distance (-103 units)
3. **Verified Fix:** Confirmed fix works in 13 seconds
4. **Regression Testing:** Can re-run anytime to prevent regression

### Physics & Timing Gotchas
- Collision meshes build **after** visuals render
- CharacterBody3D needs collision to stand on
- Save/Load systems must respect async terrain generation

---

## Second Bot Bugfix: CLOSED 🎉

**Bot-discovered, bot-verified, production-ready!**
