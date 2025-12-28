extends Node
## Interaction Feature Signals - E-key interaction events

signal interaction_available(target: Node, prompt: String)
signal interaction_unavailable()
signal interaction_performed(target: Node, action: String)
