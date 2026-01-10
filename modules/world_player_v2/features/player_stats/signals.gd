extends Node
## Stats Feature Signals - Health, stamina, death events

signal player_died()
signal health_changed(current: int, max_hp: int)
signal stamina_changed(current: float, max_stamina: float)
