@tool
extends EditorPlugin

func _enter_tree():
	add_autoload_singleton("RendererFallback", "res://addons/renderer_fallback/renderer_fallback.gd")
	print("[RendererFallback Plugin] Installed")

func _exit_tree():
	remove_autoload_singleton("RendererFallback")
	print("[RendererFallback Plugin] Uninstalled")
