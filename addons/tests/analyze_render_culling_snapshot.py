#!/usr/bin/env python3
"""Summarize town render scene-scan culling attribution.

Run addons/tests/run_town_render_culling_audit.cmd first to produce a snapshot
with render_diagnostics.final_scene_scan.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
GPU_TELEMETRY_DIR = REPO_ROOT / ".agent" / "gpu-telemetry"


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _int(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        try:
            return int(float(value))
        except ValueError:
            return default
    return default


def _float(value: Any, default: float = 0.0) -> float:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return default
    return default


def _fmt_int(value: Any) -> str:
    return f"{_int(value):,}"


def _fmt_float(value: Any, digits: int = 2, suffix: str = "") -> str:
    return f"{_float(value):.{digits}f}{suffix}"


def _pct(numerator: float, denominator: float) -> float:
    if denominator <= 0.0:
        return 0.0
    return numerator / denominator * 100.0


def _latest_raw() -> Path | None:
    if not GPU_TELEMETRY_DIR.exists():
        return None
    matches = sorted(GPU_TELEMETRY_DIR.glob("town_stall_raw_baseline_*.json"), key=lambda p: p.stat().st_mtime)
    return matches[-1] if matches else None


def _snapshot_path_from_raw(raw: dict[str, Any]) -> Path | None:
    for run in _list(raw.get("runs")):
        snapshot_path = _dict(_dict(run).get("snapshot")).get("snapshot_path")
        if snapshot_path:
            path = Path(str(snapshot_path))
            if path.exists():
                return path
    return None


def _select_inputs(args: argparse.Namespace) -> tuple[Path | None, dict[str, Any], Path | None, dict[str, Any]]:
    raw_path = Path(args.raw).resolve() if args.raw else None
    if raw_path is None and args.latest_raw:
        raw_path = _latest_raw()
    raw: dict[str, Any] = _read_json(raw_path) if raw_path and raw_path.exists() else {}

    snapshot_path = Path(args.snapshot).resolve() if args.snapshot else None
    if snapshot_path is None and raw:
        snapshot_path = _snapshot_path_from_raw(raw)
    snapshot: dict[str, Any] = _read_json(snapshot_path) if snapshot_path and snapshot_path.exists() else {}
    return raw_path, raw, snapshot_path, snapshot


def _scene_scan(snapshot: dict[str, Any]) -> dict[str, Any]:
    diagnostics = _dict(snapshot.get("render_diagnostics"))
    return _dict(diagnostics.get("final_scene_scan"))


def _stationary_window(snapshot: dict[str, Any]) -> dict[str, Any]:
    return _dict(snapshot.get("stationary_hold_window")) or _dict(snapshot.get("town_entry_window"))


def _kind_from_detail(detail: dict[str, Any]) -> str:
    name = str(detail.get("name", "")).lower()
    path = str(detail.get("path", "")).lower()
    category = str(detail.get("category", "other"))
    text = f"{name} {path}"
    if "globaltreerenderbatch" in text or "tree" in text:
        return "vegetation_tree" if category == "vegetation" else "tree"
    if "globalgrassrenderbatch" in text or "grass" in text:
        return "vegetation_grass" if category == "vegetation" else "grass"
    if "globalrockrenderbatch" in text or "rock" in text:
        return "vegetation_rock" if category == "vegetation" else "rock"
    if "terrainbatch" in text:
        return "terrain_batch"
    if "water" in text:
        return "water"
    return category


def _vector_size(value: Any) -> tuple[float, float, float]:
    data = _dict(value)
    return (_float(data.get("x")), _float(data.get("y")), _float(data.get("z")))


def _bounds_area_and_diag(detail: dict[str, Any]) -> tuple[float, float]:
    x, y, z = _vector_size(detail.get("bounds_size"))
    horizontal_area = max(x, 0.0) * max(z, 0.0)
    diagonal = (x * x + y * y + z * z) ** 0.5
    return horizontal_area, diagonal


def _group_details(details: list[Any]) -> dict[str, dict[str, Any]]:
    grouped: dict[str, dict[str, Any]] = {}
    for raw_detail in details:
        detail = _dict(raw_detail)
        kind = _kind_from_detail(detail)
        group = grouped.setdefault(
            kind,
            {
                "count": 0,
                "triangles": 0,
                "vertices": 0,
                "instances": 0,
                "max_triangles": 0,
                "max_bounds_area": 0.0,
                "max_bounds_diagonal": 0.0,
            },
        )
        triangles = _int(detail.get("triangle_count"))
        area, diagonal = _bounds_area_and_diag(detail)
        group["count"] += 1
        group["triangles"] += triangles
        group["vertices"] += _int(detail.get("vertex_count"))
        group["instances"] += _int(detail.get("instance_count"))
        group["max_triangles"] = max(_int(group["max_triangles"]), triangles)
        group["max_bounds_area"] = max(_float(group["max_bounds_area"]), area)
        group["max_bounds_diagonal"] = max(_float(group["max_bounds_diagonal"]), diagonal)
    return grouped


def _top_details(details: list[Any], limit: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for raw_detail in details:
        detail = _dict(raw_detail)
        area, diagonal = _bounds_area_and_diag(detail)
        rows.append(
            {
                "kind": _kind_from_detail(detail),
                "name": str(detail.get("name", "")),
                "class": str(detail.get("class", "")),
                "triangles": _int(detail.get("triangle_count")),
                "vertices": _int(detail.get("vertex_count")),
                "instances": _int(detail.get("instance_count")),
                "base_triangles": _int(detail.get("base_triangle_count")),
                "distance_to_player_m": _float(detail.get("distance_to_player_m"), -1.0),
                "bounds_area": area,
                "bounds_diagonal": diagonal,
                "path": str(detail.get("path", "")),
            }
        )
    rows.sort(key=lambda item: (int(item["triangles"]), int(item["vertices"])), reverse=True)
    return rows[:limit]


def _counts_summary(snapshot: dict[str, Any], scan: dict[str, Any]) -> dict[str, Any]:
    stationary = _stationary_window(snapshot)
    telemetry = _dict(snapshot.get("system_telemetry"))
    vegetation = _dict(telemetry.get("vegetation_manager"))
    terrain = _dict(telemetry.get("terrain_manager"))
    visible_multimesh_triangles = _int(scan.get("visible_multimesh_rendered_triangle_count"))
    frustum_multimesh_triangles = _int(scan.get("frustum_multimesh_rendered_triangle_count"))
    visible_mesh_triangles = _int(scan.get("visible_mesh_triangle_count"))
    frustum_mesh_triangles = _int(scan.get("frustum_mesh_triangle_count"))
    visible_total = visible_mesh_triangles + visible_multimesh_triangles
    frustum_total = frustum_mesh_triangles + frustum_multimesh_triangles
    return {
        "avg_primitives_frame": stationary.get("avg_primitives"),
        "avg_draw_calls_frame": stationary.get("avg_draw_calls"),
        "avg_objects_frame": stationary.get("avg_objects"),
        "visible_total_triangle_proxy": visible_total,
        "frustum_total_triangle_proxy": frustum_total,
        "frustum_vs_visible_pct": _pct(float(frustum_total), float(visible_total)),
        "visible_mesh_triangles": visible_mesh_triangles,
        "frustum_mesh_triangles": frustum_mesh_triangles,
        "visible_multimesh_triangles": visible_multimesh_triangles,
        "frustum_multimesh_triangles": frustum_multimesh_triangles,
        "visible_vegetation_triangles": _int(scan.get("visible_vegetation_multimesh_rendered_triangle_count")) + _int(scan.get("visible_vegetation_mesh_triangle_count")),
        "frustum_vegetation_triangles": _int(scan.get("frustum_vegetation_multimesh_rendered_triangle_count")) + _int(scan.get("frustum_vegetation_mesh_triangle_count")),
        "visible_terrain_triangles": _int(scan.get("visible_terrain_mesh_triangle_count")) + _int(scan.get("visible_terrain_multimesh_rendered_triangle_count")),
        "frustum_terrain_triangles": _int(scan.get("frustum_terrain_mesh_triangle_count")) + _int(scan.get("frustum_terrain_multimesh_rendered_triangle_count")),
        "visible_building_triangles": _int(scan.get("visible_building_mesh_triangle_count")) + _int(scan.get("visible_building_multimesh_rendered_triangle_count")),
        "frustum_building_triangles": _int(scan.get("frustum_building_mesh_triangle_count")) + _int(scan.get("frustum_building_multimesh_rendered_triangle_count")),
        "visible_entity_triangles": _int(scan.get("visible_entity_mesh_triangle_count")) + _int(scan.get("visible_entity_multimesh_rendered_triangle_count")),
        "frustum_entity_triangles": _int(scan.get("frustum_entity_mesh_triangle_count")) + _int(scan.get("frustum_entity_multimesh_rendered_triangle_count")),
        "visible_vegetation_batches": _int(scan.get("visible_vegetation_multimesh_instances")),
        "frustum_vegetation_batches": _int(scan.get("frustum_vegetation_multimesh_instances")),
        "visible_vegetation_instances": _int(scan.get("visible_vegetation_multimesh_instance_count")),
        "frustum_vegetation_instances": _int(scan.get("frustum_vegetation_multimesh_instance_count")),
        "vegetation_ignore_occlusion": vegetation.get("vegetation_global_render_ignore_occlusion_culling"),
        "vegetation_tree_batches": vegetation.get("global_tree_render_batch_count"),
        "vegetation_tree_instances": vegetation.get("global_tree_render_instances"),
        "vegetation_tree_primitives": vegetation.get("global_tree_render_estimated_primitives"),
        "vegetation_tree_alpha_empty": vegetation.get("global_tree_estimated_alpha_empty_primitive_equivalent"),
        "terrain_batch_primitives": terrain.get("terrain_visual_batch_primitive_count"),
        "terrain_visible_primitives": terrain.get("terrain_visual_visible_primitive_count"),
        "terrain_batch_nodes": terrain.get("terrain_visual_batch_node_count"),
        "terrain_rendered_chunks": terrain.get("rendered_terrain_chunk_count"),
    }


def _findings(summary: dict[str, Any], grouped_frustum: dict[str, dict[str, Any]], top_frustum: list[dict[str, Any]], scan_available: bool) -> list[str]:
    if not scan_available:
        return [
            "No final_scene_scan is present. Run addons\\tests\\run_town_render_culling_audit.cmd, then rerun this analyzer with --latest-raw.",
        ]
    findings: list[str] = []
    frustum_total = _int(summary.get("frustum_total_triangle_proxy"))
    visible_total = _int(summary.get("visible_total_triangle_proxy"))
    if frustum_total > 0:
        findings.append(
            f"Scene scan frustum proxy is {_fmt_int(frustum_total)} triangles, {_fmt_float(_pct(frustum_total, visible_total), 1, '%')} of visible-property geometry."
        )
    veg_frustum = _int(summary.get("frustum_vegetation_triangles"))
    if veg_frustum >= 500_000:
        findings.append(f"Vegetation batches inside the camera frustum carry {_fmt_int(veg_frustum)} triangle-proxy work.")
    terrain_frustum = _int(summary.get("frustum_terrain_triangles"))
    if terrain_frustum >= 300_000:
        findings.append(f"Terrain batches/meshes inside the camera frustum carry {_fmt_int(terrain_frustum)} triangle-proxy work.")
    tree_group = grouped_frustum.get("vegetation_tree", {})
    if tree_group:
        findings.append(
            "Tree batch drag is directly visible in frustum details: "
            f"{_fmt_int(tree_group.get('count'))} top captured tree batches, {_fmt_int(tree_group.get('instances'))} instances, {_fmt_int(tree_group.get('triangles'))} triangles in captured top list."
        )
    if top_frustum:
        top = top_frustum[0]
        findings.append(
            f"Largest frustum batch is {top['name']} ({top['kind']}): {_fmt_int(top['triangles'])} triangles, "
            f"instances={_fmt_int(top['instances'])}, bounds_diag={_fmt_float(top['bounds_diagonal'], 1)}m."
        )
    if bool(summary.get("vegetation_ignore_occlusion")):
        findings.append("Vegetation render batches ignore occlusion culling, so frustum-visible hidden/blocked batches can still submit.")
    return findings


def _build_report(raw_path: Path | None, snapshot_path: Path | None, snapshot: dict[str, Any], top_limit: int) -> dict[str, Any]:
    scan = _scene_scan(snapshot)
    summary = _counts_summary(snapshot, scan) if scan else {}
    top_frustum = _top_details(_list(scan.get("top_frustum_geometry")), top_limit) if scan else []
    top_visible = _top_details(_list(scan.get("top_visible_geometry")), top_limit) if scan else []
    grouped_frustum = _group_details(_list(scan.get("top_frustum_geometry"))) if scan else {}
    grouped_visible = _group_details(_list(scan.get("top_visible_geometry"))) if scan else {}
    return {
        "raw_path": str(raw_path) if raw_path else None,
        "snapshot_path": str(snapshot_path) if snapshot_path else None,
        "scene_scan_available": bool(scan),
        "summary": summary,
        "grouped_top_frustum": grouped_frustum,
        "grouped_top_visible": grouped_visible,
        "top_frustum": top_frustum,
        "top_visible": top_visible,
        "findings": _findings(summary, grouped_frustum, top_frustum, bool(scan)),
    }


def _print_report(report: dict[str, Any]) -> None:
    print("Town Render Culling Audit")
    print("=========================")
    print(f"raw:      {report.get('raw_path') or 'n/a'}")
    print(f"snapshot: {report.get('snapshot_path') or 'n/a'}")
    if not report.get("scene_scan_available"):
        print()
        print("No final_scene_scan found.")
        for finding in _list(report.get("findings")):
            print(f"- {finding}")
        return

    summary = _dict(report.get("summary"))
    print()
    print("Scene Scan")
    print("----------")
    print(f"avg_primitives/frame:  {_fmt_int(summary.get('avg_primitives_frame'))}")
    print(f"avg_draw_calls/frame:  {_fmt_float(summary.get('avg_draw_calls_frame'), 1)}")
    print(f"visible triangle proxy:{_fmt_int(summary.get('visible_total_triangle_proxy'))}")
    print(f"frustum triangle proxy:{_fmt_int(summary.get('frustum_total_triangle_proxy'))} ({_fmt_float(summary.get('frustum_vs_visible_pct'), 1, '%')} of visible)")
    print(f"frustum terrain:       {_fmt_int(summary.get('frustum_terrain_triangles'))} / visible {_fmt_int(summary.get('visible_terrain_triangles'))}")
    print(f"frustum vegetation:    {_fmt_int(summary.get('frustum_vegetation_triangles'))} / visible {_fmt_int(summary.get('visible_vegetation_triangles'))}")
    print(f"frustum buildings:     {_fmt_int(summary.get('frustum_building_triangles'))} / visible {_fmt_int(summary.get('visible_building_triangles'))}")
    print(f"frustum entities:      {_fmt_int(summary.get('frustum_entity_triangles'))} / visible {_fmt_int(summary.get('visible_entity_triangles'))}")
    print(f"vegetation batches:    {_fmt_int(summary.get('frustum_vegetation_batches'))} frustum / {_fmt_int(summary.get('visible_vegetation_batches'))} visible")
    print(f"vegetation instances:  {_fmt_int(summary.get('frustum_vegetation_instances'))} frustum / {_fmt_int(summary.get('visible_vegetation_instances'))} visible")
    print(f"vegetation occlusion:  ignore={summary.get('vegetation_ignore_occlusion')}")
    print(f"tree telemetry:        batches={_fmt_int(summary.get('vegetation_tree_batches'))} instances={_fmt_int(summary.get('vegetation_tree_instances'))} primitives={_fmt_int(summary.get('vegetation_tree_primitives'))} alpha_empty={_fmt_int(summary.get('vegetation_tree_alpha_empty'))}")
    print(f"terrain telemetry:     batches={_fmt_int(summary.get('terrain_batch_nodes'))} chunks={_fmt_int(summary.get('terrain_rendered_chunks'))} batch_prims={_fmt_int(summary.get('terrain_batch_primitives'))} visible_prims={_fmt_int(summary.get('terrain_visible_primitives'))}")

    print()
    print("Top Frustum Geometry")
    print("--------------------")
    for row in _list(report.get("top_frustum")):
        item = _dict(row)
        print(
            f"{item.get('kind')} {item.get('name')}: tris={_fmt_int(item.get('triangles'))} "
            f"instances={_fmt_int(item.get('instances'))} base_tris={_fmt_int(item.get('base_triangles'))} "
            f"dist={_fmt_float(item.get('distance_to_player_m'), 1)}m bounds_diag={_fmt_float(item.get('bounds_diagonal'), 1)}m"
        )

    print()
    print("Grouped Top Frustum")
    print("-------------------")
    grouped = _dict(report.get("grouped_top_frustum"))
    for key in sorted(grouped.keys(), key=lambda name: _int(_dict(grouped[name]).get("triangles")), reverse=True):
        group = _dict(grouped[key])
        print(
            f"{key}: count={_fmt_int(group.get('count'))} tris={_fmt_int(group.get('triangles'))} "
            f"instances={_fmt_int(group.get('instances'))} max_batch_tris={_fmt_int(group.get('max_triangles'))} "
            f"max_bounds_diag={_fmt_float(group.get('max_bounds_diagonal'), 1)}m"
        )

    print()
    print("Findings")
    print("--------")
    for index, finding in enumerate(_list(report.get("findings")), start=1):
        print(f"{index}. {finding}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", help="Raw town baseline telemetry JSON.")
    parser.add_argument("--snapshot", help="Full town performance snapshot JSON.")
    parser.add_argument("--latest-raw", action="store_true", help="Use the latest town raw baseline artifact.")
    parser.add_argument("--top", type=int, default=12, help="Number of top visible/frustum geometry rows to print.")
    parser.add_argument("--json", action="store_true", help="Print JSON.")
    args = parser.parse_args()

    raw_path, _raw, snapshot_path, snapshot = _select_inputs(args)
    if not snapshot:
        print("No snapshot found. Pass --snapshot, or --latest-raw after running the culling audit launcher.")
        return 2
    report = _build_report(raw_path, snapshot_path, snapshot, max(args.top, 1))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        _print_report(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
