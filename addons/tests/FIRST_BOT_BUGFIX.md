# First Bot-Discovered Bugfix - QuickLoad Item Failure

**Date:** January 4, 2026  
**Bug:** Items (pickaxe, tools, weapons) stopped working after QuickLoad (F8)  
**Status:** ✅ **FIXED**

## Overview

This documents the **first bugfix discovered and verified entirely through automated bot testing**. The bug prevented all player items from functioning after using QuickLoad, despite appearing correctly in the UI. The bug was identified, diagnosed, and verified fixed using an automated player bot that simulated the exact reproduction steps.

---

## The Problem

### User Report
> "After pressing F8 (QuickLoad), my pickaxe stops working. I can see it in my hotbar, but clicking does nothing."

### Impact
- **All items affected:** Pickaxe, axe, shovel, buckets, weapons, props
- **Save/Load broken:** QuickLoad (F8) rendered the player unable to interact with the world
- **Manual testing difficult:** Reproduction required specific timing and state

---

## Automated Testing Approach

### Bot Development Evolution

#### Phase 1: Simple Movement Bot
```gdscript
// tests/simple_movement_bot.gd
- Simulates WASD movement
- Verifies basic player control
- Runtime: 20 seconds
```

#### Phase 2: Mining Bot
```gdscript
// tests/mining_bot.gd
- Adds camera control (pitch rotation)
- Simulates left-click for mining
- Tests item usage pipeline
```

#### Phase 3: QuickLoad Test Bot (Final)
```gdscript
// tests/mining_bot.gd (extended)
Test Sequence:
1. Move forward (3s)
2. Look down (1s)
3. Mine BEFORE save (2s) - verify pickaxe works
4. QuickSave F5 (2s)
5. Move to change state (2s)
6. QuickLoad F8 (4s) - THE CRITICAL TEST
7. Mine AFTER load (2s) - does pickaxe still work?
8. Report results
```

### Test Runner
```python
// tests/run_movement_test.py
- Launches Godot with test scene
- Captures stdout/stderr
- Filters for debug markers: [BOT], [HOTBAR_DEBUG], [ROUTER_DEBUG], [COMBAT_DEBUG]
- 30-second timeout for full test cycle
```

---

## Diagnostic Methodology

### Systematic Debug Logging Chain

We added debug logging at each layer to trace item flow:

#### Layer 1: Hotbar
```gdscript
[HOTBAR_DEBUG] load_save_data() called
[HOTBAR_DEBUG] Slot 0: Stone Pickaxe x1 ✅
[HOTBAR_DEBUG] Selected slot set to: 0 ✅
[HOTBAR_DEBUG] Item BEFORE select_slot: Stone Pickaxe ✅
[HOTBAR_DEBUG] Item AFTER select_slot: Stone Pickaxe ✅
```
**Result:** Hotbar state is correct ✅

#### Layer 2: ItemUseRouter
```gdscript
[ROUTER_DEBUG] route_primary_action called ✅
[ROUTER_DEBUG] Item received: Stone Pickaxe ✅
[ROUTER_DEBUG] Current mode: COMBAT ✅
[ROUTER_DEBUG] Routing to CombatSystem... ✅
[ROUTER_DEBUG] CombatSystem found, calling handle_primary ✅
```
**Result:** Routing is correct ✅

#### Layer 3: CombatSystem (FAILURE POINT)
```gdscript
// BEFORE QuickLoad (works):
[COMBAT_DEBUG] Item data: { "category": 1, "damage": 2, ... }
[COMBAT_DEBUG] Item category: 1
[COMBAT_DEBUG] Routing to do_tool_attack (tool) ✅

// AFTER QuickLoad (broken):
[COMBAT_DEBUG] Item data: { "category": 1.0, "damage": 2.0, ... }
[COMBAT_DEBUG] Item category: 1
[COMBAT_DEBUG] Unknown category - no action ❌
```

---

## Root Cause Discovery

### The Smoking Gun

**Key Observation:** After QuickLoad, all item data fields changed from integers to floats:
- `"category": 1` → `"category": 1.0`
- `"damage": 2` → `"damage": 2.0`

### Why This Breaks

GDScript's JSON parser (`JSON.parse()`) converts all numbers to floats by default. This breaks `match` statements which require **exact type matching**:

```gdscript
var category = item.get("category", 0)  // Returns 1.0 (float) after JSON load

match category:
    1:  // int literal - expects TYPE int
        do_tool_attack(item)  // NEVER EXECUTES because 1.0 != 1
    _:
        pass  // Falls through to default case ❌
```

### Technical Explanation

| Scenario | Item Source | Value Type | Match Result |
|----------|------------|------------|--------------|
| **Before Load** | Direct from item_definitions.gd | `int` (1) | ✅ Matches case `1:` |
| **After Load** | JSON.parse() from save file | `float` (1.0) | ❌ Fails to match case `1:` |

---

## The Fix

**File:** `modules/world_player_v2/features/tool_combat/combat_system.gd`  
**Line:** 131

```gdscript
// BEFORE (broken):
var category = item.get("category", 0)

// AFTER (fixed):
# BUG FIX: JSON deserialization converts all numbers to floats (1.0 vs 1)
# The match statement requires exact type match, so we must cast to int
var category = int(item.get("category", 0))
```

### Why This Works
- `int()` cast converts `1.0` → `1`
- Match statement now receives `int` type
- All cases match correctly again

---

## Verification

### Bot Test Results

**BEFORE Fix:**
```
[BOT]   *click* AFTER load
[COMBAT_DEBUG] Item category: 1
[COMBAT_DEBUG] Unknown category - no action ❌
```

**AFTER Fix:**
```
[BOT]   *click* AFTER load
[COMBAT_DEBUG] Item category: 1
[COMBAT_DEBUG] Routing to do_tool_attack (tool) ✅
```

### Test Command
```bash
python tests\run_movement_test.py
```

---

## Impact & Scope

### Items Fixed
- ✅ **Tools:** Pickaxe, Axe, Shovel
- ✅ **Buckets:** Water Bucket
- ✅ **Props:** Heavy Pistol, etc.
- ✅ **Resources:** All items with category field

### Potential Future Issues
This fix prevents similar bugs in any code using `match` on JSON-deserialized data. Consider:
- Using `int()` cast when matching numeric values from JSON
- Or using `if/elif` with value equality instead of `match`

---

## Lessons Learned

### Advantages of Bot Testing
1. **Reproducible:** Bot runs identical sequence every time
2. **Fast:** 16-second test vs minutes of manual testing
3. **Comprehensive:** Tests exact user workflow
4. **Diagnostic:** Captures logs at every layer
5. **Verifiable:** Proves fix works before user testing

### Bot Testing Methodology
1. **Start Simple:** Basic movement → Camera control → Actions
2. **Layer by Layer:** Add debug logging at each pipeline stage
3. **Trace Data Flow:** Follow item data from source to usage
4. **Capture Everything:** Filter logs by debug markers
5. **Verify Fix:** Re-run bot to confirm resolution

### GDScript Gotchas
- `match` requires **exact type matching** (no implicit conversion)
- `JSON.parse()` always returns floats for numbers
- Use `int()` / `float()` casts when type matters

---

## Files Modified

### Core Fix
- `modules/world_player_v2/features/tool_combat/combat_system.gd` (line 131)

### Debug Logging (can be removed later)
- `modules/world_player_v2/features/data_inventory/hotbar.gd`
- `modules/world_player_v2/features/data_inventory/item_use_router.gd`
- `modules/world_player_v2/features/tool_combat/combat_system.gd`

### Testing Infrastructure
- `tests/mining_bot.gd` - QuickLoad test bot
- `tests/run_movement_test.py` - Test runner with output filtering

---

## Timeline

| Time | Event |
|------|-------|
| 00:00 | User reports pickaxe broken after QuickLoad |
| 00:05 | Created simple movement bot |
| 00:15 | Extended bot with camera control and mining |
| 00:30 | Added QuickLoad test sequence |
| 00:45 | Added hotbar debug logging - state correct ✅ |
| 01:00 | Added router debug logging - routing correct ✅ |
| 01:15 | Added combat debug logging - **found type mismatch!** |
| 01:20 | Applied int() cast fix |
| 01:25 | Bot test confirms fix ✅ |

**Total Time:** ~90 minutes from report to verified fix

---

## Conclusion

This bugfix demonstrates the power of automated testing for game development:

✅ **Faster** than manual reproduction  
✅ **More reliable** than human testing  
✅ **Comprehensive** diagnostic information  
✅ **Verifiable** fix confirmation  

The bot-based testing methodology can be applied to future bugs, especially those involving complex state changes, timing, or multi-step reproduction.

---

**First bot-discovered bug: CLOSED** 🎉
