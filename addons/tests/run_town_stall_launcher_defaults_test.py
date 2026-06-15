import os

import run_town_stall_test as runner


ENV_KEYS = [
    "TOWN_STALL_RENDER_DISTANCE",
    "TOWN_STALL_MANUAL_HANDOFF",
    "TOWN_STALL_TERRAIN_ARTIFACT_STORE_SOURCE_BUFFERS",
    "TOWN_STALL_AUTO_TELEPORT",
    "TOWN_STALL_MESH_LOD_THRESHOLD",
]


def _expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> int:
    previous = {key: os.environ.get(key) for key in ENV_KEYS}
    try:
        for key in ENV_KEYS:
            os.environ.pop(key, None)
        _expect(runner._default_render_distance() == "10", "town-stall default render distance should be 10")
        _expect(runner._default_terrain_artifact_source_buffers() == "0", "non-manual runs should keep source buffers opt-in")
        _expect(runner._default_mesh_lod_threshold() == "", "launcher should not disable Godot mesh LOD selection by default")

        os.environ["TOWN_STALL_RENDER_DISTANCE"] = "5"
        _expect(runner._default_render_distance() == "5", "explicit render-distance override should win")

        os.environ.pop("TOWN_STALL_RENDER_DISTANCE", None)
        os.environ["TOWN_STALL_MANUAL_HANDOFF"] = "1"
        _expect(runner._default_terrain_artifact_source_buffers() == "1", "manual handoff should default editable terrain source buffers on")
        _expect(runner._default_auto_teleport() == "1", "manual handoff should default to teleport, not locked auto-fly")

        os.environ["TOWN_STALL_AUTO_TELEPORT"] = "0"
        _expect(runner._default_auto_teleport() == "0", "explicit auto-teleport override should win")
        os.environ.pop("TOWN_STALL_AUTO_TELEPORT", None)

        os.environ["TOWN_STALL_MESH_LOD_THRESHOLD"] = "4.0"
        _expect(runner._default_mesh_lod_threshold() == "4.0", "explicit mesh LOD threshold override should win")
        os.environ.pop("TOWN_STALL_MESH_LOD_THRESHOLD", None)

        os.environ["TOWN_STALL_TERRAIN_ARTIFACT_STORE_SOURCE_BUFFERS"] = "0"
        _expect(runner._default_terrain_artifact_source_buffers() == "0", "explicit source-buffer override should win")
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    print("[RUN_TOWN_STALL_LAUNCHER_DEFAULTS_TEST] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
