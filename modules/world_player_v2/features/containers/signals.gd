extends Node
## Signals for container inventory system

## Emitted when a container is opened by the player
signal container_opened(container: Node)

## Emitted when the container UI is closed
signal container_closed()
