#include "prefab_geometry_native.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace godot {

namespace {

struct Vector2iHash {
	size_t operator()(const Vector2i &value) const noexcept {
		const uint64_t x = static_cast<uint64_t>(static_cast<uint32_t>(value.x));
		const uint64_t y = static_cast<uint64_t>(static_cast<uint32_t>(value.y));
		return static_cast<size_t>((x << 32) ^ y);
	}
};

struct Vector3iHash {
	size_t operator()(const Vector3i &value) const noexcept {
		const uint64_t x = static_cast<uint64_t>(static_cast<uint32_t>(value.x));
		const uint64_t y = static_cast<uint64_t>(static_cast<uint32_t>(value.y));
		const uint64_t z = static_cast<uint64_t>(static_cast<uint32_t>(value.z));
		return static_cast<size_t>((x * 73856093u) ^ (y * 19349663u) ^ (z * 83492791u));
	}
};

struct ColumnKey {
	int x = 0;
	int z = 0;

	bool operator==(const ColumnKey &other) const noexcept {
		return x == other.x && z == other.z;
	}
};

struct ColumnKeyHash {
	size_t operator()(const ColumnKey &key) const noexcept {
		const uint64_t x = static_cast<uint64_t>(static_cast<uint32_t>(key.x));
		const uint64_t z = static_cast<uint64_t>(static_cast<uint32_t>(key.z));
		return static_cast<size_t>((x << 32) ^ z);
	}
};

struct ColumnBounds {
	int min_y = 0;
	int max_y = 0;
	bool initialized = false;
};

static int normalize_rotation(int rotation) {
	int normalized = rotation % 4;
	if (normalized < 0) {
		normalized += 4;
	}
	return normalized;
}

static Vector3i rotate_offset_impl(const Vector3i &offset, int rotation) {
	switch (normalize_rotation(rotation)) {
		case 0:
			return offset;
		case 1:
			return Vector3i(-offset.z, offset.y, offset.x);
		case 2:
			return Vector3i(-offset.x, offset.y, -offset.z);
		case 3:
			return Vector3i(offset.z, offset.y, -offset.x);
		default:
			return offset;
	}
}

static Vector3 rotate_vector3_offset_impl(const Vector3 &offset, int rotation) {
	switch (normalize_rotation(rotation)) {
		case 0:
			return offset;
		case 1:
			return Vector3(-offset.z, offset.y, offset.x);
		case 2:
			return Vector3(-offset.x, offset.y, -offset.z);
		case 3:
			return Vector3(offset.z, offset.y, -offset.x);
		default:
			return offset;
	}
}

static Vector3 get_grid_correction_impl(int rotation) {
	switch (normalize_rotation(rotation)) {
		case 1:
			return Vector3(1, 0, 0);
		case 2:
			return Vector3(1, 0, 1);
		case 3:
			return Vector3(0, 0, 1);
		default:
			return Vector3();
	}
}

static bool variant_to_vector3i(const Variant &value, Vector3i &out) {
	if (value.get_type() != Variant::VECTOR3I) {
		return false;
	}
	out = value;
	return true;
}

static Dictionary dictionary_from_cell_set(const std::unordered_set<Vector3i, Vector3iHash> &cells) {
	Dictionary result;
	for (const Vector3i &cell : cells) {
		result[cell] = true;
	}
	return result;
}

static std::unordered_set<Vector3i, Vector3iHash> dictionary_to_cell_set(const Dictionary &dict) {
	std::unordered_set<Vector3i, Vector3iHash> result;
	Array keys = dict.keys();
	result.reserve(keys.size());
	for (int i = 0; i < keys.size(); ++i) {
		Vector3i cell;
		if (!variant_to_vector3i(keys[i], cell)) {
			continue;
		}
		result.insert(cell);
	}
	return result;
}

static String cell_to_string(const Vector3i &cell) {
	return "(" + String::num_int64(cell.x) + ", " + String::num_int64(cell.y) + ", " + String::num_int64(cell.z) + ")";
}

static std::vector<Vector3i> get_stair_neighbors_impl(const Vector3i &cell) {
	std::vector<Vector3i> result;
	result.reserve(14);
	for (int dy = -1; dy <= 1; ++dy) {
		for (int dx = -1; dx <= 1; ++dx) {
			for (int dz = -1; dz <= 1; ++dz) {
				if (dx == 0 && dy == 0 && dz == 0) {
					continue;
				}
				if (std::abs(dx) + std::abs(dz) > 1) {
					continue;
				}
				result.push_back(cell + Vector3i(dx, dy, dz));
			}
		}
	}
	return result;
}

static std::vector<Vector3i> largest_stair_component_impl(const std::vector<Vector3i> &stair_cells) {
	std::unordered_set<Vector3i, Vector3iHash> stair_set;
	stair_set.reserve(stair_cells.size());
	for (const Vector3i &cell : stair_cells) {
		stair_set.insert(cell);
	}

	std::unordered_set<Vector3i, Vector3iHash> visited;
	visited.reserve(stair_cells.size());

	std::vector<Vector3i> best;
	for (const Vector3i &cell : stair_cells) {
		if (visited.find(cell) != visited.end()) {
			continue;
		}

		std::vector<Vector3i> stack;
		std::vector<Vector3i> component;
		stack.push_back(cell);
		visited.insert(cell);

		while (!stack.empty()) {
			Vector3i current = stack.back();
			stack.pop_back();
			component.push_back(current);
			for (const Vector3i &neighbor : get_stair_neighbors_impl(current)) {
				if (stair_set.find(neighbor) == stair_set.end() || visited.find(neighbor) != visited.end()) {
					continue;
				}
				visited.insert(neighbor);
				stack.push_back(neighbor);
			}
		}

		if (component.size() > best.size()) {
			best = std::move(component);
		}
	}

	return best;
}

static void queue_exterior_empty_cell(const Vector2i &cell_2d, int y, const Vector3i &declared_size, const std::unordered_set<Vector3i, Vector3iHash> &solid_set,
		std::unordered_set<Vector2i, Vector2iHash> &exterior, std::vector<Vector2i> &queue) {
	if (cell_2d.x < 0 || cell_2d.x >= declared_size.x) {
		return;
	}
	if (cell_2d.y < 0 || cell_2d.y >= declared_size.z) {
		return;
	}
	if (exterior.find(cell_2d) != exterior.end()) {
		return;
	}
	if (solid_set.find(Vector3i(cell_2d.x, y, cell_2d.y)) != solid_set.end()) {
		return;
	}
	exterior.insert(cell_2d);
	queue.push_back(cell_2d);
}

} // namespace

PrefabGeometryNative::PrefabGeometryNative() {}

PrefabGeometryNative::~PrefabGeometryNative() {}

void PrefabGeometryNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("rotate_offset", "offset", "rotation"), &PrefabGeometryNative::rotate_offset);
	ClassDB::bind_method(D_METHOD("rotate_vector3_offset", "offset", "rotation"), &PrefabGeometryNative::rotate_vector3_offset);
	ClassDB::bind_method(D_METHOD("get_grid_correction", "rotation"), &PrefabGeometryNative::get_grid_correction);
	ClassDB::bind_method(D_METHOD("build_rotated_bounds_from_offsets", "offsets", "rotation"), &PrefabGeometryNative::build_rotated_bounds_from_offsets);
	ClassDB::bind_method(D_METHOD("build_local_rect_from_offsets", "offsets", "declared_size"), &PrefabGeometryNative::build_local_rect_from_offsets);
	ClassDB::bind_method(D_METHOD("rotate_local_rect_bounds", "rect", "rotation"), &PrefabGeometryNative::rotate_local_rect_bounds);
	ClassDB::bind_method(D_METHOD("parse_local_rect_2d", "raw_rect", "fallback_rect", "declared_size"), &PrefabGeometryNative::parse_local_rect_2d);
	ClassDB::bind_method(D_METHOD("parse_local_volumes", "raw_volumes", "declared_size", "min_y", "max_y"), &PrefabGeometryNative::parse_local_volumes);
}

Vector3i PrefabGeometryNative::rotate_offset(const Vector3i &offset, int rotation) const {
	return rotate_offset_impl(offset, rotation);
}

Vector3 PrefabGeometryNative::rotate_vector3_offset(const Vector3 &offset, int rotation) const {
	return rotate_vector3_offset_impl(offset, rotation);
}

Vector3 PrefabGeometryNative::get_grid_correction(int rotation) const {
	return get_grid_correction_impl(rotation);
}

Dictionary PrefabGeometryNative::build_rotated_bounds_from_offsets(const Array &offsets, int rotation) const {
	Dictionary result;
	if (offsets.is_empty()) {
		result["min"] = Vector3i();
		result["max"] = Vector3i();
		result["footprint"] = Vector2i(1, 1);
		return result;
	}

	int min_x = std::numeric_limits<int>::max();
	int min_y = std::numeric_limits<int>::max();
	int min_z = std::numeric_limits<int>::max();
	int max_x = std::numeric_limits<int>::min();
	int max_y = std::numeric_limits<int>::min();
	int max_z = std::numeric_limits<int>::min();
	bool has_any = false;

	for (int i = 0; i < offsets.size(); ++i) {
		Vector3i offset;
		if (!variant_to_vector3i(offsets[i], offset)) {
			continue;
		}
		const Vector3i rotated = rotate_offset_impl(offset, rotation);
		min_x = std::min(min_x, rotated.x);
		min_y = std::min(min_y, rotated.y);
		min_z = std::min(min_z, rotated.z);
		max_x = std::max(max_x, rotated.x);
		max_y = std::max(max_y, rotated.y);
		max_z = std::max(max_z, rotated.z);
		has_any = true;
	}

	if (!has_any) {
		result["min"] = Vector3i();
		result["max"] = Vector3i();
		result["footprint"] = Vector2i(1, 1);
		return result;
	}

	result["min"] = Vector3i(min_x, min_y, min_z);
	result["max"] = Vector3i(max_x, max_y, max_z);
	result["footprint"] = Vector2i(max_x - min_x + 1, max_z - min_z + 1);
	return result;
}

Dictionary PrefabGeometryNative::build_local_rect_from_offsets(const Array &offsets, const Vector3i &declared_size) const {
	Dictionary result;
	if (offsets.is_empty()) {
		const int fallback_w = std::max(1, declared_size.x);
		const int fallback_d = std::max(1, declared_size.z);
		result["min"] = Vector2i();
		result["max"] = Vector2i(fallback_w - 1, fallback_d - 1);
		result["footprint"] = Vector2i(fallback_w, fallback_d);
		return result;
	}

	int min_x = std::numeric_limits<int>::max();
	int max_x = std::numeric_limits<int>::min();
	int min_z = std::numeric_limits<int>::max();
	int max_z = std::numeric_limits<int>::min();
	bool has_any = false;

	for (int i = 0; i < offsets.size(); ++i) {
		Vector3i offset;
		if (!variant_to_vector3i(offsets[i], offset)) {
			continue;
		}
		min_x = std::min(min_x, offset.x);
		max_x = std::max(max_x, offset.x);
		min_z = std::min(min_z, offset.z);
		max_z = std::max(max_z, offset.z);
		has_any = true;
	}

	if (!has_any) {
		const int fallback_w = std::max(1, declared_size.x);
		const int fallback_d = std::max(1, declared_size.z);
		result["min"] = Vector2i();
		result["max"] = Vector2i(fallback_w - 1, fallback_d - 1);
		result["footprint"] = Vector2i(fallback_w, fallback_d);
		return result;
	}

	result["min"] = Vector2i(min_x, min_z);
	result["max"] = Vector2i(max_x, max_z);
	result["footprint"] = Vector2i(max_x - min_x + 1, max_z - min_z + 1);
	return result;
}

Dictionary PrefabGeometryNative::rotate_local_rect_bounds(const Dictionary &rect, int rotation) const {
	const Vector2i min_corner = rect.get("min", Vector2i());
	const Vector2i max_corner = rect.get("max", Vector2i());
	const Vector3i corners[4] = {
		Vector3i(min_corner.x, 0, min_corner.y),
		Vector3i(max_corner.x, 0, min_corner.y),
		Vector3i(min_corner.x, 0, max_corner.y),
		Vector3i(max_corner.x, 0, max_corner.y)
	};

	int rotated_min_x = std::numeric_limits<int>::max();
	int rotated_max_x = std::numeric_limits<int>::min();
	int rotated_min_z = std::numeric_limits<int>::max();
	int rotated_max_z = std::numeric_limits<int>::min();

	for (const Vector3i &corner : corners) {
		const Vector3i rotated = rotate_offset_impl(corner, rotation);
		rotated_min_x = std::min(rotated_min_x, rotated.x);
		rotated_max_x = std::max(rotated_max_x, rotated.x);
		rotated_min_z = std::min(rotated_min_z, rotated.z);
		rotated_max_z = std::max(rotated_max_z, rotated.z);
	}

	Dictionary result;
	result["min"] = Vector2i(rotated_min_x, rotated_min_z);
	result["max"] = Vector2i(rotated_max_x, rotated_max_z);
	result["footprint"] = Vector2i(rotated_max_x - rotated_min_x + 1, rotated_max_z - rotated_min_z + 1);
	return result;
}

Dictionary PrefabGeometryNative::parse_local_rect_2d(const Variant &raw_rect, const Dictionary &fallback_rect, const Vector3i &declared_size) const {
	if (raw_rect.get_type() != Variant::DICTIONARY) {
		return fallback_rect;
	}

	Dictionary rect_in = raw_rect;
	Array min_arr = rect_in.get("min", Array());
	Array max_arr = rect_in.get("max", Array());
	if (min_arr.size() < 2 || max_arr.size() < 2) {
		return fallback_rect;
	}

	const Vector2i raw_min{int(min_arr[0]), int(min_arr[1])};
	const Vector2i raw_max{int(max_arr[0]), int(max_arr[1])};
	const int max_x_idx = std::max(0, declared_size.x - 1);
	const int max_z_idx = std::max(0, declared_size.z - 1);
	const int x0 = std::clamp(std::min(raw_min.x, raw_max.x), 0, max_x_idx);
	const int z0 = std::clamp(std::min(raw_min.y, raw_max.y), 0, max_z_idx);
	const int x1 = std::clamp(std::max(raw_min.x, raw_max.x), 0, max_x_idx);
	const int z1 = std::clamp(std::max(raw_min.y, raw_max.y), 0, max_z_idx);

	Dictionary result;
	result["min"] = Vector2i(x0, z0);
	result["max"] = Vector2i(x1, z1);
	result["footprint"] = Vector2i(x1 - x0 + 1, z1 - z0 + 1);
	return result;
}

Array PrefabGeometryNative::parse_local_volumes(const Array &raw_volumes, const Vector3i &declared_size, int min_y, int max_y) const {
	Array result;
	if (declared_size.x <= 0 || declared_size.y <= 0 || declared_size.z <= 0) {
		return result;
	}

	for (int i = 0; i < raw_volumes.size(); ++i) {
		if (raw_volumes[i].get_type() != Variant::DICTIONARY) {
			continue;
		}
		Dictionary volume = raw_volumes[i];
		Array min_arr = volume.get("min", Array());
		Array max_arr = volume.get("max", Array());
		if (min_arr.size() < 3 || max_arr.size() < 3) {
			continue;
		}

		const Vector3i raw_min{int(min_arr[0]), int(min_arr[1]), int(min_arr[2])};
		const Vector3i raw_max{int(max_arr[0]), int(max_arr[1]), int(max_arr[2])};
		const int x0 = std::clamp(std::min(raw_min.x, raw_max.x), 0, declared_size.x - 1);
		const int y0 = std::clamp(std::min(raw_min.y, raw_max.y), min_y, max_y);
		const int z0 = std::clamp(std::min(raw_min.z, raw_max.z), 0, declared_size.z - 1);
		const int x1 = std::clamp(std::max(raw_min.x, raw_max.x), 0, declared_size.x - 1);
		const int y1 = std::clamp(std::max(raw_min.y, raw_max.y), min_y, max_y);
		const int z1 = std::clamp(std::max(raw_min.z, raw_max.z), 0, declared_size.z - 1);
		if (x1 < x0 || y1 < y0 || z1 < z0) {
			continue;
		}

		Dictionary volume_out;
		volume_out["min"] = Vector3i(x0, y0, z0);
		volume_out["max"] = Vector3i(x1, y1, z1);
		result.append(volume_out);
	}

	return result;
}

Dictionary PrefabGeometryNative::build_local_cell_set_from_volumes(const Array &volumes) const {
	std::unordered_set<Vector3i, Vector3iHash> result;
	for (int i = 0; i < volumes.size(); ++i) {
		if (volumes[i].get_type() != Variant::DICTIONARY) {
			continue;
		}
		Dictionary volume = volumes[i];
		Vector3i min_cell = volume.get("min", Vector3i());
		Vector3i max_cell = volume.get("max", Vector3i());
		for (int y = min_cell.y; y <= max_cell.y; ++y) {
			for (int z = min_cell.z; z <= max_cell.z; ++z) {
				for (int x = min_cell.x; x <= max_cell.x; ++x) {
					result.insert(Vector3i(x, y, z));
				}
			}
		}
	}
	return dictionary_from_cell_set(result);
}

Dictionary PrefabGeometryNative::inflate_local_cell_set(const Dictionary &cell_set, int padding) const {
	if (padding <= 0 || cell_set.is_empty()) {
		return cell_set.duplicate();
	}

	const std::unordered_set<Vector3i, Vector3iHash> cells = dictionary_to_cell_set(cell_set);
	std::unordered_set<Vector3i, Vector3iHash> result;
	for (const Vector3i &cell : cells) {
		for (int dz = -padding; dz <= padding; ++dz) {
			for (int dy = -padding; dy <= padding; ++dy) {
				for (int dx = -padding; dx <= padding; ++dx) {
					result.insert(cell + Vector3i(dx, dy, dz));
				}
			}
		}
	}
	return dictionary_from_cell_set(result);
}

Array PrefabGeometryNative::build_rotated_carve_segments(const Array &local_cells, int rotation) const {
	std::unordered_map<ColumnKey, std::vector<int>, ColumnKeyHash> levels_by_column;
	levels_by_column.reserve(local_cells.size());

	for (int i = 0; i < local_cells.size(); ++i) {
		Vector3i cell;
		if (!variant_to_vector3i(local_cells[i], cell)) {
			continue;
		}
		const Vector3i rotated = rotate_offset_impl(cell, rotation);
		ColumnKey key{rotated.x, rotated.z};
		levels_by_column[key].push_back(rotated.y);
	}

	std::vector<ColumnKey> columns;
	columns.reserve(levels_by_column.size());
	for (const auto &entry : levels_by_column) {
		columns.push_back(entry.first);
	}
	std::sort(columns.begin(), columns.end(), [](const ColumnKey &a, const ColumnKey &b) {
		if (a.x != b.x) {
			return a.x < b.x;
		}
		return a.z < b.z;
	});

	Array result;
	for (const ColumnKey &key : columns) {
		std::vector<int> levels = levels_by_column[key];
		if (levels.empty()) {
			continue;
		}
		std::sort(levels.begin(), levels.end());
		int start_y = levels.front();
		int prev_y = start_y;
		for (size_t idx = 1; idx < levels.size(); ++idx) {
			const int current_y = levels[idx];
			if (current_y <= prev_y + 1) {
				prev_y = current_y;
				continue;
			}
			Dictionary segment;
			segment["x"] = key.x;
			segment["z"] = key.z;
			segment["min_y"] = start_y;
			segment["max_y"] = prev_y;
			result.append(segment);
			start_y = current_y;
			prev_y = current_y;
		}
		Dictionary segment;
		segment["x"] = key.x;
		segment["z"] = key.z;
		segment["min_y"] = start_y;
		segment["max_y"] = prev_y;
		result.append(segment);
	}

	return result;
}

Array PrefabGeometryNative::build_rotated_segments_from_volumes(const Array &volumes, int rotation) const {
	Dictionary cell_set = build_local_cell_set_from_volumes(volumes);
	return build_rotated_carve_segments(cell_set.keys(), rotation);
}

Array PrefabGeometryNative::get_enclosed_below_grade_empty_cells(const Dictionary &solid_cells, const Vector3i &declared_size, int min_y, int grade_y) const {
	Array result;
	if (declared_size.x <= 0 || declared_size.z <= 0) {
		return result;
	}

	const std::unordered_set<Vector3i, Vector3iHash> solid_set = dictionary_to_cell_set(solid_cells);
	for (int y = min_y; y <= grade_y; ++y) {
		std::unordered_set<Vector2i, Vector2iHash> exterior;
		std::vector<Vector2i> queue;

		for (int x = 0; x < declared_size.x; ++x) {
			queue_exterior_empty_cell(Vector2i(x, 0), y, declared_size, solid_set, exterior, queue);
			queue_exterior_empty_cell(Vector2i(x, declared_size.z - 1), y, declared_size, solid_set, exterior, queue);
		}
		for (int z = 0; z < declared_size.z; ++z) {
			queue_exterior_empty_cell(Vector2i(0, z), y, declared_size, solid_set, exterior, queue);
			queue_exterior_empty_cell(Vector2i(declared_size.x - 1, z), y, declared_size, solid_set, exterior, queue);
		}

		for (size_t cursor = 0; cursor < queue.size(); ++cursor) {
			const Vector2i current = queue[cursor];
			for (const Vector2i &step : {Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)}) {
				queue_exterior_empty_cell(current + step, y, declared_size, solid_set, exterior, queue);
			}
		}

		for (int z = 0; z < declared_size.z; ++z) {
			for (int x = 0; x < declared_size.x; ++x) {
				const Vector3i cell(x, y, z);
				if (solid_set.find(cell) != solid_set.end()) {
					continue;
				}
				if (exterior.find(Vector2i(x, z)) != exterior.end()) {
					continue;
				}
				result.append(cell);
			}
		}
	}

	return result;
}

Dictionary PrefabGeometryNative::build_required_below_grade_excavation_cells(const Array &enclosed_cells, const Array &stair_cells, int min_y, int grade_y) const {
	std::unordered_set<Vector3i, Vector3iHash> result_cells;
	result_cells.reserve(enclosed_cells.size() + stair_cells.size());

	for (int i = 0; i < enclosed_cells.size(); ++i) {
		Vector3i cell;
		if (!variant_to_vector3i(enclosed_cells[i], cell)) {
			continue;
		}
		result_cells.insert(cell);
	}

	std::vector<Vector3i> below_grade_stairs;
	below_grade_stairs.reserve(stair_cells.size());
	for (int i = 0; i < stair_cells.size(); ++i) {
		Vector3i cell;
		if (!variant_to_vector3i(stair_cells[i], cell)) {
			continue;
		}
		if (cell.y <= 0 || cell.y > grade_y) {
			continue;
		}
		below_grade_stairs.push_back(cell);
	}

	for (const Vector3i &cell : largest_stair_component_impl(below_grade_stairs)) {
		result_cells.insert(cell);
	}

	std::unordered_map<ColumnKey, ColumnBounds, ColumnKeyHash> bounds_by_column;
	for (const Vector3i &cell : result_cells) {
		ColumnKey key{cell.x, cell.z};
		ColumnBounds &bounds = bounds_by_column[key];
		if (!bounds.initialized) {
			bounds.min_y = cell.y;
			bounds.max_y = cell.y;
			bounds.initialized = true;
			continue;
		}
		bounds.min_y = std::min(bounds.min_y, cell.y);
		bounds.max_y = std::max(bounds.max_y, cell.y);
	}

	for (const auto &entry : bounds_by_column) {
		const ColumnKey &key = entry.first;
		const ColumnBounds &bounds = entry.second;
		const int from_y = std::max(min_y, bounds.min_y - 1);
		for (int y = from_y; y <= bounds.max_y; ++y) {
			result_cells.insert(Vector3i(key.x, y, key.z));
		}
	}

	return dictionary_from_cell_set(result_cells);
}

Array PrefabGeometryNative::find_surface_breach_excavation_cells(const Dictionary &excavated_cells, const Dictionary &surface_rect, int grade_y) const {
	Array result;
	const Vector2i rect_min = surface_rect.get("min", Vector2i());
	const Vector2i rect_max = surface_rect.get("max", Vector2i());

	Array keys = excavated_cells.keys();
	for (int i = 0; i < keys.size(); ++i) {
		Vector3i cell;
		if (!variant_to_vector3i(keys[i], cell)) {
			continue;
		}
		if (cell.y != grade_y) {
			continue;
		}
		if (cell.x >= rect_min.x && cell.x <= rect_max.x && cell.z >= rect_min.y && cell.z <= rect_max.y) {
			continue;
		}
		if (result.size() >= 6) {
			break;
		}
		result.append(cell_to_string(cell));
	}

	return result;
}

} // namespace godot
