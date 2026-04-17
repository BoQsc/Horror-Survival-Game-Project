extends Node

## LocalInputLock - Local client modal/input lock state.
## This is intentionally scene-local state for multiplayer UI overlays.

signal changed(is_locked: bool, reasons: Array)

const REASON_GAME_MENU: StringName = &"game_menu"
const REASON_CREATIVE_CATALOG: StringName = &"creative_catalog"

var _reasons: Dictionary = {}

func set_reason(reason: StringName, enabled: bool) -> void:
	if enabled:
		if _reasons.has(reason):
			return
		_reasons[reason] = true
	else:
		if not _reasons.has(reason):
			return
		_reasons.erase(reason)

	changed.emit(is_locked(), get_reasons())

func set_game_menu_open(is_open: bool) -> void:
	set_reason(REASON_GAME_MENU, is_open)

func set_creative_catalog_open(is_open: bool) -> void:
	set_reason(REASON_CREATIVE_CATALOG, is_open)

func has_reason(reason: StringName) -> bool:
	return _reasons.has(reason)

func is_locked() -> bool:
	return not _reasons.is_empty()

func get_reasons() -> Array:
	var reasons: Array = []
	for reason in _reasons.keys():
		reasons.append(String(reason))
	reasons.sort()
	return reasons

func clear() -> void:
	if _reasons.is_empty():
		return

	_reasons.clear()
	changed.emit(false, [])
