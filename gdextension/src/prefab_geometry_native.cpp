#include "prefab_geometry_native.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <limits>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <godot_cpp/variant/aabb.hpp>
#include <godot_cpp/variant/basis.hpp>
#include <godot_cpp/variant/callable.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include "../../addons/third_party/fast_noise_lite/FastNoiseLite.h"

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

struct NearestCandidate {
	double dist_sq = 0.0;
	Dictionary data;
};

struct RayHitCandidate {
	double distance = 0.0;
	double distance_sq_to_ray = 0.0;
	Dictionary data;
	bool valid = false;
};

struct VegetationClusterPayloadChunk {
	PackedFloat32Array buffer;
	int float_count = 0;
};

static constexpr double VEGETATION_DATA_RAY_AIM_PRIORITY_DELTA_SQ = 0.01;

static int normalize_rotation(int rotation) {
	int normalized = rotation % 4;
	if (normalized < 0) {
		normalized += 4;
	}
	return normalized;
}

static uint8_t encode_height_byte_native(double height, double max_height) {
	if (max_height <= 0.0) {
		return 0;
	}
	const double normalized = std::clamp(height / max_height, 0.0, 1.0);
	const int encoded = static_cast<int>(std::round(normalized * 255.0));
	return static_cast<uint8_t>(std::clamp(encoded, 0, 255));
}

static int native_row_worker_count(int row_count) {
	if (row_count <= 1) {
		return 1;
	}
	if (row_count < 512) {
		return 1;
	}
	const unsigned int hardware_workers = std::thread::hardware_concurrency();
	const int detected_workers = hardware_workers > 0 ? static_cast<int>(hardware_workers) : 1;
	return std::clamp(detected_workers, 1, row_count);
}

static bool variant_to_vector2(const Variant &value, Vector2 &out) {
	if (value.get_type() != Variant::VECTOR2) {
		return false;
	}
	out = value;
	return true;
}

static bool variant_to_vector2i(const Variant &value, Vector2i &out) {
	if (value.get_type() != Variant::VECTOR2I) {
		return false;
	}
	out = value;
	return true;
}

static double smoothstep01(double value) {
	const double t = std::clamp(value, 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

static double lerp_double(double from, double to, double weight) {
	return from + (to - from) * weight;
}

static void lookup_minimap_lut_rgb(const int32_t *lut, int lut_size, int material_id, int &r, int &g, int &b) {
	int normalized_id = material_id;
	if (normalized_id < 0) {
		normalized_id = 0;
	}
	const int lut_index = normalized_id * 3;
	if (lut != nullptr && lut_index >= 0 && lut_index + 2 < lut_size) {
		r = std::clamp(static_cast<int>(lut[lut_index]), 0, 255);
		g = std::clamp(static_cast<int>(lut[lut_index + 1]), 0, 255);
		b = std::clamp(static_cast<int>(lut[lut_index + 2]), 0, 255);
		return;
	}
	if (lut != nullptr && lut_size >= 3) {
		r = std::clamp(static_cast<int>(lut[0]), 0, 255);
		g = std::clamp(static_cast<int>(lut[1]), 0, 255);
		b = std::clamp(static_cast<int>(lut[2]), 0, 255);
		return;
	}
	r = 80;
	g = 160;
	b = 60;
}

static uint8_t encode_shaded_rgb_byte(int value, double shade) {
	const int shaded = static_cast<int>(static_cast<double>(value) * shade);
	return static_cast<uint8_t>(std::clamp(shaded, 0, 255));
}

static double clamp_support_height_byte(uint8_t encoded_height, double max_height) {
	return std::clamp(double(encoded_height) / 255.0 * max_height, 1.0, 28.0);
}

static double sample_world_map_support_height(const uint8_t *height_read, int map_size, double wx, double wz, double max_height, int half) {
	const int px = std::clamp(static_cast<int>(std::floor(wx)) + half, 0, map_size - 1);
	const int pz = std::clamp(static_cast<int>(std::floor(wz)) + half, 0, map_size - 1);
	return clamp_support_height_byte(height_read[pz * map_size + px], max_height);
}

static std::vector<double> dedupe_sorted_doubles(std::vector<double> values, double epsilon) {
	std::sort(values.begin(), values.end());
	std::vector<double> result;
	result.reserve(values.size());
	bool has_last = false;
	double last_value = 0.0;
	for (const double value : values) {
		if (!has_last || std::abs(value - last_value) > epsilon) {
			result.push_back(value);
			last_value = value;
			has_last = true;
		}
	}
	return result;
}

static std::vector<double> build_support_axis_positions(double span, double stride, double edge_inset, int max_samples) {
	if (span <= 1.05) {
		return {edge_inset, span * 0.5, span - edge_inset};
	}

	const int desired = std::clamp(static_cast<int>(std::ceil(span / stride)) + 1, 3, max_samples);
	const double min_pos = std::min(edge_inset, span * 0.3);
	const double max_pos = std::max(min_pos, span - min_pos);
	std::vector<double> values;
	values.reserve(desired + 1);
	for (int i = 0; i < desired; ++i) {
		const double t = desired <= 1 ? 0.0 : double(i) / double(desired - 1);
		values.push_back(lerp_double(min_pos, max_pos, t));
	}
	values.push_back(span * 0.5);
	return dedupe_sorted_doubles(std::move(values), 0.04);
}

static std::vector<Vector2> dedupe_support_points(const std::vector<Vector2> &points, double epsilon) {
	const double epsilon_sq = epsilon * epsilon;
	std::vector<Vector2> result;
	result.reserve(points.size());
	for (const Vector2 &point : points) {
		bool duplicate = false;
		for (const Vector2 &existing : result) {
			const double dx = double(point.x - existing.x);
			const double dy = double(point.y - existing.y);
			if (dx * dx + dy * dy <= epsilon_sq) {
				duplicate = true;
				break;
			}
		}
		if (!duplicate) {
			result.push_back(point);
		}
	}
	return result;
}

static std::vector<Vector2> build_support_sample_points(const Vector2i &footprint, const Dictionary &config) {
	const double stride = std::max(0.45, double(config.get("sample_stride", 1.0)));
	const double edge_inset = std::clamp(double(config.get("edge_inset", 0.18)), 0.0, 0.49);
	const int max_samples = std::max(3, int(config.get("max_samples_per_axis", 5)));
	const double span_x = std::max(1.0, double(footprint.x));
	const double span_z = std::max(1.0, double(footprint.y));
	const std::vector<double> xs = build_support_axis_positions(span_x, stride, edge_inset, max_samples);
	const std::vector<double> zs = build_support_axis_positions(span_z, stride, edge_inset, max_samples);

	std::vector<Vector2> points;
	points.reserve(xs.size() * zs.size() + 1);
	for (const double z : zs) {
		for (const double x : xs) {
			points.emplace_back(float(x), float(z));
		}
	}
	points.emplace_back(float(span_x * 0.5), float(span_z * 0.5));
	return dedupe_support_points(points, 0.04);
}

static double stepped_road_height_native(fastnoiselite::FastNoiseLite &road_noise, double wx, double wz) {
	const double height = double(road_noise.GetNoise(float(wx), float(wz))) * 3.0 + 12.0;
	const double base_level = std::floor(height);
	const double frac_value = height - base_level;
	if (frac_value < 0.45) {
		return base_level;
	}
	if (frac_value > 0.55) {
		return base_level + 1.0;
	}
	return base_level + smoothstep01((frac_value - 0.45) / 0.1);
}

static double cross_2d(const Vector2 &a, const Vector2 &b) {
	return double(a.x) * double(b.y) - double(a.y) * double(b.x);
}

static bool point_in_rect_2d(const Vector2 &point, const Vector2 &rect_min, const Vector2 &rect_max) {
	return point.x >= rect_min.x && point.x <= rect_max.x && point.y >= rect_min.y && point.y <= rect_max.y;
}

static double distance_point_to_segment_2d(const Vector2 &point, const Vector2 &a, const Vector2 &b) {
	const Vector2 ab = b - a;
	const double ab_len_sq = double(ab.length_squared());
	if (ab_len_sq <= 0.000001) {
		return std::sqrt(double(point.distance_squared_to(a)));
	}
	const double t = std::clamp(double((point - a).dot(ab)) / ab_len_sq, 0.0, 1.0);
	const Vector2 closest = a + ab * float(t);
	return std::sqrt(double(point.distance_squared_to(closest)));
}

static bool segments_intersect_2d(const Vector2 &a1, const Vector2 &a2, const Vector2 &b1, const Vector2 &b2) {
	const double d1 = cross_2d(a2 - a1, b1 - a1);
	const double d2 = cross_2d(a2 - a1, b2 - a1);
	const double d3 = cross_2d(b2 - b1, a1 - b1);
	const double d4 = cross_2d(b2 - b1, a2 - b1);
	const double eps = 0.0001;
	if (std::abs(d1) < eps && std::abs(d2) < eps && std::abs(d3) < eps && std::abs(d4) < eps) {
		const double a_min_x = std::min(double(a1.x), double(a2.x));
		const double a_max_x = std::max(double(a1.x), double(a2.x));
		const double a_min_y = std::min(double(a1.y), double(a2.y));
		const double a_max_y = std::max(double(a1.y), double(a2.y));
		const double b_min_x = std::min(double(b1.x), double(b2.x));
		const double b_max_x = std::max(double(b1.x), double(b2.x));
		const double b_min_y = std::min(double(b1.y), double(b2.y));
		const double b_max_y = std::max(double(b1.y), double(b2.y));
		return !(a_max_x < b_min_x || b_max_x < a_min_x || a_max_y < b_min_y || b_max_y < a_min_y);
	}
	return (d1 * d2 <= 0.0) && (d3 * d4 <= 0.0);
}

static double distance_segment_to_segment_2d(const Vector2 &a1, const Vector2 &a2, const Vector2 &b1, const Vector2 &b2) {
	if (segments_intersect_2d(a1, a2, b1, b2)) {
		return 0.0;
	}
	return std::min(
			std::min(distance_point_to_segment_2d(a1, b1, b2), distance_point_to_segment_2d(a2, b1, b2)),
			std::min(distance_point_to_segment_2d(b1, a1, a2), distance_point_to_segment_2d(b2, a1, a2)));
}

static double distance_segment_to_rect_2d(const Vector2 &a, const Vector2 &b, const Vector2 &rect_min, const Vector2 &rect_max) {
	if (point_in_rect_2d(a, rect_min, rect_max) || point_in_rect_2d(b, rect_min, rect_max)) {
		return 0.0;
	}
	const Vector2 c1(rect_min.x, rect_min.y);
	const Vector2 c2(rect_max.x, rect_min.y);
	const Vector2 c3(rect_max.x, rect_max.y);
	const Vector2 c4(rect_min.x, rect_max.y);
	double dist = std::numeric_limits<double>::infinity();
	dist = std::min(dist, distance_segment_to_segment_2d(a, b, c1, c2));
	dist = std::min(dist, distance_segment_to_segment_2d(a, b, c2, c3));
	dist = std::min(dist, distance_segment_to_segment_2d(a, b, c3, c4));
	dist = std::min(dist, distance_segment_to_segment_2d(a, b, c4, c1));
	return dist;
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

static Transform3D build_vegetation_transform(const Transform3D &base_transform, const Vector3 &rotation_fix, double rotation_angle, double scale, const Vector3 &local_pos) {
	Transform3D transform = base_transform;
	transform.basis = transform.basis * Basis::from_euler(rotation_fix);
	transform = transform.rotated(Vector3(0.0, 1.0, 0.0), rotation_angle);
	transform = transform.scaled(Vector3(scale, scale, scale));
	transform.origin = local_pos;
	return transform;
}

static void pack_transform_to_buffer(const Transform3D &transform, float *write_ptr) {
	const Vector3 basis_x = transform.basis.get_column(0);
	const Vector3 basis_y = transform.basis.get_column(1);
	const Vector3 basis_z = transform.basis.get_column(2);

	write_ptr[0] = basis_x.x;
	write_ptr[1] = basis_y.x;
	write_ptr[2] = basis_z.x;
	write_ptr[3] = transform.origin.x;
	write_ptr[4] = basis_x.y;
	write_ptr[5] = basis_y.y;
	write_ptr[6] = basis_z.y;
	write_ptr[7] = transform.origin.y;
	write_ptr[8] = basis_x.z;
	write_ptr[9] = basis_y.z;
	write_ptr[10] = basis_z.z;
	write_ptr[11] = transform.origin.z;
}

static bool is_procedural_road_blocked(double global_x, double global_z, double road_spacing, double road_width, double road_clearance) {
	if (road_spacing <= 0.0) {
		return false;
	}

	double local_x = std::fmod(global_x, road_spacing);
	if (local_x < 0.0) {
		local_x += road_spacing;
	}
	double local_z = std::fmod(global_z, road_spacing);
	if (local_z < 0.0) {
		local_z += road_spacing;
	}

	const double dist_x = std::min(local_x, road_spacing - local_x);
	const double dist_z = std::min(local_z, road_spacing - local_z);
	const double road_half_width = road_width * 0.5 + road_clearance;
	return std::min(dist_x, dist_z) <= road_half_width;
}

static bool chunk_overlaps_radius(const Vector2i &coord, const Vector3 &center, double radius, int chunk_stride) {
	const double chunk_center_x = (double(coord.x) + 0.5) * double(chunk_stride);
	const double chunk_center_z = (double(coord.y) + 0.5) * double(chunk_stride);
	const double dx = double(center.x) - chunk_center_x;
	const double dz = double(center.z) - chunk_center_z;
	const double max_dist = radius + (double(chunk_stride) * 0.70710678);
	return dx * dx + dz * dz <= max_dist * max_dist;
}

static Vector3 dictionary_get_vector3(const Dictionary &dict, const String &key, const Vector3 &fallback = Vector3()) {
	const Variant value = dict.get(key, fallback);
	if (value.get_type() == Variant::VECTOR3) {
		return value;
	}
	return fallback;
}

static String vegetation_position_hash(const Vector3 &pos) {
	const int64_t hash_x = static_cast<int64_t>(std::floor(double(pos.x)));
	const int64_t hash_z = static_cast<int64_t>(std::floor(double(pos.z)));
	return String::num_int64(hash_x) + "_" + String::num_int64(hash_z);
}

static double ray_axis_distance_sq_xz(const Vector3 &origin, const Vector3 &ray_dir, const Vector3 &axis_pos, double max_distance) {
	const double dx = double(ray_dir.x);
	const double dz = double(ray_dir.z);
	const double horizontal_len_sq = dx * dx + dz * dz;
	if (horizontal_len_sq <= 0.0000001) {
		const double ox = double(origin.x) - double(axis_pos.x);
		const double oz = double(origin.z) - double(axis_pos.z);
		return ox * ox + oz * oz;
	}
	const double to_axis_x = double(axis_pos.x) - double(origin.x);
	const double to_axis_z = double(axis_pos.z) - double(origin.z);
	const double projected = (to_axis_x * dx + to_axis_z * dz) / horizontal_len_sq;
	const double t = std::clamp(projected, 0.0, max_distance);
	const double closest_x = double(origin.x) + dx * t;
	const double closest_z = double(origin.z) + dz * t;
	const double off_x = closest_x - double(axis_pos.x);
	const double off_z = closest_z - double(axis_pos.z);
	return off_x * off_x + off_z * off_z;
}

static double ray_point_distance_sq(const Vector3 &origin, const Vector3 &ray_dir, const Vector3 &point, double max_distance) {
	const double len_sq = double(ray_dir.length_squared());
	if (len_sq <= 0.0000001) {
		return double(origin.distance_squared_to(point));
	}
	const Vector3 to_point = point - origin;
	const double projected = double(to_point.dot(ray_dir)) / len_sq;
	const double t = std::clamp(projected, 0.0, max_distance);
	const Vector3 closest = origin + ray_dir * t;
	return double(closest.distance_squared_to(point));
}

static double vegetation_aim_distance_sq(const String &kind, const Vector3 &origin, const Vector3 &ray_dir, const Vector3 &base_pos, double height, double max_distance) {
	if (kind == String("tree")) {
		return ray_axis_distance_sq_xz(origin, ray_dir, base_pos, max_distance);
	}
	const Vector3 target_pos = base_pos + Vector3(0.0, std::max(height, 0.0) * 0.5, 0.0);
	return ray_point_distance_sq(origin, ray_dir, target_pos, max_distance);
}

static bool is_better_ray_hit(double candidate_distance, double candidate_distance_sq_to_ray, const RayHitCandidate &current) {
	if (!current.valid) {
		return true;
	}
	const double aim_delta_sq = candidate_distance_sq_to_ray - current.distance_sq_to_ray;
	if (std::abs(aim_delta_sq) > VEGETATION_DATA_RAY_AIM_PRIORITY_DELTA_SQ) {
		return aim_delta_sq < 0.0;
	}
	if (std::abs(candidate_distance - current.distance) > 0.00001) {
		return candidate_distance < current.distance;
	}
	return candidate_distance_sq_to_ray < current.distance_sq_to_ray;
}

static bool intersect_vertical_vegetation_cylinder(const Vector3 &origin, const Vector3 &ray_dir, const Vector3 &base_pos, double radius, double height, double max_distance, double &out_distance, double &out_axis_distance_sq) {
	if (radius <= 0.0 || height <= 0.0 || max_distance <= 0.0) {
		return false;
	}

	double t_min = 0.0;
	double t_max = max_distance;

	const double ox = double(origin.x) - double(base_pos.x);
	const double oz = double(origin.z) - double(base_pos.z);
	const double dx = double(ray_dir.x);
	const double dz = double(ray_dir.z);
	const double a = dx * dx + dz * dz;
	const double c = ox * ox + oz * oz - radius * radius;
	constexpr double EPSILON = 0.0000001;

	if (a <= EPSILON) {
		if (c > 0.0) {
			return false;
		}
	} else {
		const double b = 2.0 * (ox * dx + oz * dz);
		const double discriminant = b * b - 4.0 * a * c;
		if (discriminant < 0.0) {
			return false;
		}
		const double sqrt_discriminant = std::sqrt(std::max(0.0, discriminant));
		double t0 = (-b - sqrt_discriminant) / (2.0 * a);
		double t1 = (-b + sqrt_discriminant) / (2.0 * a);
		if (t0 > t1) {
			std::swap(t0, t1);
		}
		t_min = std::max(t_min, t0);
		t_max = std::min(t_max, t1);
		if (t_min > t_max) {
			return false;
		}
	}

	const double min_y = double(base_pos.y) - radius;
	const double max_y = double(base_pos.y) + height + radius;
	const double dy = double(ray_dir.y);
	if (std::abs(dy) <= EPSILON) {
		if (double(origin.y) < min_y || double(origin.y) > max_y) {
			return false;
		}
	} else {
		double ty0 = (min_y - double(origin.y)) / dy;
		double ty1 = (max_y - double(origin.y)) / dy;
		if (ty0 > ty1) {
			std::swap(ty0, ty1);
		}
		t_min = std::max(t_min, ty0);
		t_max = std::min(t_max, ty1);
		if (t_min > t_max) {
			return false;
		}
	}

	const double hit_distance = std::max(0.0, t_min);
	if (hit_distance > max_distance) {
		return false;
	}

	out_distance = hit_distance;
	out_axis_distance_sq = ray_axis_distance_sq_xz(origin, ray_dir, base_pos, max_distance);
	return true;
}

static bool intersect_ray_aabb_bounds(const Vector3 &origin, const Vector3 &ray_dir, const AABB &bounds, double max_distance, double &out_distance) {
	if (bounds.size.x <= 0.0 || bounds.size.y <= 0.0 || bounds.size.z <= 0.0 || max_distance <= 0.0) {
		return false;
	}

	double t_min = 0.0;
	double t_max = max_distance;
	const Vector3 min_pos = bounds.position;
	const Vector3 max_pos = bounds.position + bounds.size;
	constexpr double EPSILON = 0.0000001;

	for (int axis = 0; axis < 3; ++axis) {
		const double axis_origin = double(origin[axis]);
		const double axis_dir = double(ray_dir[axis]);
		const double axis_min = double(min_pos[axis]);
		const double axis_max = double(max_pos[axis]);
		if (std::abs(axis_dir) <= EPSILON) {
			if (axis_origin < axis_min || axis_origin > axis_max) {
				return false;
			}
			continue;
		}
		double t0 = (axis_min - axis_origin) / axis_dir;
		double t1 = (axis_max - axis_origin) / axis_dir;
		if (t0 > t1) {
			std::swap(t0, t1);
		}
		t_min = std::max(t_min, t0);
		t_max = std::min(t_max, t1);
		if (t_min > t_max) {
			return false;
		}
	}

	out_distance = std::max(0.0, t_min);
	return out_distance <= max_distance;
}

static AABB grow_aabb(const AABB &bounds, double padding) {
	if (padding <= 0.0) {
		return bounds;
	}
	const Vector3 grow_by(static_cast<float>(padding), static_cast<float>(padding), static_cast<float>(padding));
	return AABB(bounds.position - grow_by, bounds.size + grow_by * 2.0f);
}

static bool extract_transform_from_variant(const Variant &value, Transform3D &out) {
	switch (value.get_type()) {
		case Variant::TRANSFORM3D:
			out = value;
			return true;
		case Variant::DICTIONARY: {
			Dictionary dict = value;
			out = dict.get("transform", Transform3D());
			return true;
		}
		default:
			return false;
	}
}

static Dictionary make_empty_vegetation_render_payload() {
	Dictionary payload;
	payload["buffer"] = PackedFloat32Array();
	payload["instance_count"] = 0;
	payload["bounds"] = AABB();
	payload["has_bounds"] = false;
	return payload;
}

static Dictionary build_vegetation_instances_result(
		const Dictionary &config,
		const PackedFloat32Array &height_map,
		bool include_render_payload,
		const Transform3D &render_space_inverse,
		const AABB &mesh_bounds) {
	Dictionary result;
	Array instances;
	Dictionary render_payload = make_empty_vegetation_render_payload();
	result["instances"] = instances;
	result["render_payload"] = render_payload;

	if (height_map.is_empty()) {
		return result;
	}

	const int chunk_stride = int(config.get("chunk_stride", 0));
	const int step = std::max(1, int(config.get("step", 1)));
	if (chunk_stride <= 0) {
		return result;
	}

	const int chunk_origin_x = int(config.get("chunk_origin_x", 0));
	const int chunk_origin_z = int(config.get("chunk_origin_z", 0));
	const Vector3 chunk_world_pos = config.get("chunk_world_pos", Vector3());
	const Transform3D base_transform = config.get("base_transform", Transform3D());
	const Vector3 rotation_fix = config.get("rotation_fix", Vector3());
	const double road_clearance = double(config.get("road_clearance", 0.0));
	const bool procedural_roads_enabled = bool(config.get("procedural_roads_enabled", false));
	const double procedural_road_spacing = double(config.get("procedural_road_spacing", 100.0));
	const double procedural_road_width = double(config.get("procedural_road_width", 8.0));
	const bool world_map_active = bool(config.get("world_map_active", false));
	const PackedFloat32Array road_block_values = config.get("road_block_values", PackedFloat32Array());
	const bool use_road_block_values = bool(config.get("use_road_block_values", false));
	const PackedFloat32Array noise_values = config.get("noise_values", PackedFloat32Array());
	const double noise_threshold = double(config.get("noise_threshold", 0.0));
	const bool use_noise = bool(config.get("use_noise", true));
	const bool use_water_density = bool(config.get("use_water_density", false));
	const PackedFloat32Array water_block_values = config.get("water_block_values", PackedFloat32Array());
	const bool use_water_block_values = bool(config.get("use_water_block_values", false));
	const double water_level = double(config.get("water_level", 13.0));
	const double scale_min = std::min(double(config.get("scale_min", 1.0)), double(config.get("scale_max", 1.0)));
	const double scale_max = std::max(double(config.get("scale_min", 1.0)), double(config.get("scale_max", 1.0)));
	const double scale_multiplier = double(config.get("scale_multiplier", 1.0));
	const double y_offset = double(config.get("y_offset", 0.0));
	const bool record_random_scale_factor = bool(config.get("record_random_scale_factor", true));

	instances.resize(height_map.size());
	PackedFloat32Array render_buffer;
	float *render_write_ptr = nullptr;
	if (include_render_payload) {
		render_buffer.resize(height_map.size() * 12);
		render_write_ptr = render_buffer.ptrw();
	}

	int instance_write_index = 0;
	int sample_index = 0;
	AABB bounds;
	bool has_bounds = false;
	for (int x = 0; x < chunk_stride; x += step) {
		for (int z = 0; z < chunk_stride; z += step) {
			if (sample_index >= height_map.size()) {
				break;
			}

			const int current_sample = sample_index++;
			const float terrain_y = height_map[current_sample];
			if (terrain_y < -100.0f) {
				continue;
			}

			const double global_x = double(chunk_origin_x + x);
			const double global_z = double(chunk_origin_z + z);
			bool road_is_blocked = false;
			if (use_road_block_values) {
				if (current_sample >= road_block_values.size()) {
					continue;
				}
				road_is_blocked = road_block_values[current_sample] >= 0.5f;
			} else if (!world_map_active && procedural_roads_enabled) {
				road_is_blocked = is_procedural_road_blocked(global_x, global_z, procedural_road_spacing, procedural_road_width, road_clearance);
			}
			if (road_is_blocked) {
				continue;
			}

			if (use_noise) {
				if (current_sample >= noise_values.size()) {
					continue;
				}
				const double noise_value = noise_values[current_sample];
				if (noise_value < noise_threshold) {
					continue;
				}
			}

			bool water_is_blocked = false;
			if (use_water_block_values) {
				if (current_sample >= water_block_values.size()) {
					continue;
				}
				water_is_blocked = water_block_values[current_sample] >= 0.5f;
			} else if (use_water_density) {
				water_is_blocked = double(terrain_y) + 1.0 < water_level;
			} else {
				water_is_blocked = double(terrain_y) + 1.0 < water_level;
			}
			if (water_is_blocked) {
				continue;
			}

			const Vector3 hit_pos(global_x, terrain_y, global_z);
			Vector3 local_pos = hit_pos - chunk_world_pos;
			local_pos.y += y_offset;

			Vector3 world_pos = hit_pos;
			world_pos.y += y_offset;

			const double random_scale = UtilityFunctions::randf_range(scale_min, scale_max);
			const double final_scale = scale_multiplier * random_scale;
			const double rotation_angle = UtilityFunctions::randf() * 6.28318530717958647692;
			const Transform3D transform = build_vegetation_transform(base_transform, rotation_fix, rotation_angle, final_scale, local_pos);

			Dictionary record;
			record["world_pos"] = world_pos;
			record["local_pos"] = local_pos;
			record["hit_pos"] = hit_pos;
			record["rotation_angle"] = rotation_angle;
			record["rotation"] = rotation_angle;
			record["random_scale_factor"] = record_random_scale_factor ? random_scale : 0.0;
			record["index"] = instance_write_index;
			record["alive"] = true;
			record["scale"] = final_scale;
			record["placed_by_player"] = false;
			record["transform"] = transform;
			instances[instance_write_index] = record;

			if (include_render_payload && render_write_ptr != nullptr) {
				Transform3D render_transform = transform;
				render_transform.origin = render_space_inverse.xform(world_pos);
				const AABB instance_bounds = render_transform.xform(mesh_bounds);
				if (has_bounds) {
					bounds.merge_with(instance_bounds);
				} else {
					bounds = instance_bounds;
					has_bounds = true;
				}
				pack_transform_to_buffer(render_transform, render_write_ptr + instance_write_index * 12);
			}

			instance_write_index += 1;
		}

		if (sample_index >= height_map.size()) {
			break;
		}
	}

	instances.resize(instance_write_index);
	result["instances"] = instances;

	if (include_render_payload && instance_write_index > 0) {
		render_buffer.resize(instance_write_index * 12);
		render_payload["buffer"] = render_buffer;
		render_payload["instance_count"] = instance_write_index;
		render_payload["bounds"] = bounds;
		render_payload["has_bounds"] = has_bounds;
		result["render_payload"] = render_payload;
	}

	return result;
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
	ClassDB::bind_method(D_METHOD("pick_nearest_candidates", "candidates", "max_count"), &PrefabGeometryNative::pick_nearest_candidates);
	ClassDB::bind_method(D_METHOD("pick_nearest_pending_vegetation_chunk", "pending_chunks", "viewer_pos", "chunk_stride"), &PrefabGeometryNative::pick_nearest_pending_vegetation_chunk);
	ClassDB::bind_method(D_METHOD("pick_nearby_vegetation_candidates", "chunk_data", "list_key", "item_key", "player_pos", "chunk_stride", "collider_distance", "max_count"), &PrefabGeometryNative::pick_nearby_vegetation_candidates);
	ClassDB::bind_method(D_METHOD("find_nearest_vegetation_ray_hit", "chunk_data", "list_key", "kind", "origin", "direction", "max_distance", "radius", "height", "scale_by_entry"), &PrefabGeometryNative::find_nearest_vegetation_ray_hit);
	ClassDB::bind_method(D_METHOD("find_nearest_tree_visual_bounds_ray_hit", "chunk_data", "list_key", "origin", "direction", "max_distance", "mesh_bounds", "base_transform", "rotation_fix", "bounds_padding"), &PrefabGeometryNative::find_nearest_tree_visual_bounds_ray_hit);
	ClassDB::bind_method(D_METHOD("resolve_tree_body_collision", "chunk_tree_data", "body_origin", "body_radius", "body_height", "chunk_stride", "collision_radius", "collision_height"), &PrefabGeometryNative::resolve_tree_body_collision);
	ClassDB::bind_method(D_METHOD("build_world_map_height_biome_bytes", "map_size", "world_size", "world_seed", "noise_frequency", "terrain_height", "max_height", "grass_material_id", "sand_material_id", "snow_material_id", "gravel_material_id"), &PrefabGeometryNative::build_world_map_height_biome_bytes);
	ClassDB::bind_method(D_METHOD("apply_world_map_lakes", "water_data", "road_data", "height_data", "map_size", "world_size", "world_seed", "lake_threshold", "road_width", "road_blend_margin", "road_block_threshold", "terrain_height", "water_level", "max_height", "deep_lakes_enabled"), &PrefabGeometryNative::apply_world_map_lakes);
	ClassDB::bind_method(D_METHOD("rasterize_world_map_segments", "segments", "height_data", "biome_data", "road_data", "map_size", "world_seed", "road_blend_margin", "default_width", "max_height", "road_material_id", "path_mode"), &PrefabGeometryNative::rasterize_world_map_segments);
	ClassDB::bind_method(D_METHOD("footprint_hits_world_map_road_segments", "segments", "bldg_x", "bldg_z", "footprint", "default_width", "road_blend_margin"), &PrefabGeometryNative::footprint_hits_world_map_road_segments);
	ClassDB::bind_method(D_METHOD("footprint_hits_packed_world_map_road_segments", "segment_data", "bldg_x", "bldg_z", "footprint"), &PrefabGeometryNative::footprint_hits_packed_world_map_road_segments);
	ClassDB::bind_method(D_METHOD("resolve_world_map_building_support", "height_data", "map_size", "bldg_x", "bldg_z", "footprint", "max_height", "half", "config"), &PrefabGeometryNative::resolve_world_map_building_support);
	ClassDB::bind_method(D_METHOD("flatten_world_map_building_pad", "height_data", "map_size", "bldg_x", "bldg_z", "footprint", "bldg_y", "max_height", "half", "support_height_range", "protected_columns"), &PrefabGeometryNative::flatten_world_map_building_pad);
	ClassDB::bind_method(D_METHOD("build_world_map_excavation_modifications", "segments", "spawn_origin"), &PrefabGeometryNative::build_world_map_excavation_modifications);
	ClassDB::bind_method(D_METHOD("build_world_map_minimap_rgb_bytes", "height_data", "biome_data", "road_data", "water_data", "building_data", "width", "height", "material_rgb_lut", "road_material_id", "water_r", "water_g", "water_b", "building_r", "building_g", "building_b"), &PrefabGeometryNative::build_world_map_minimap_rgb_bytes);
	ClassDB::bind_method(D_METHOD("build_vegetation_instances", "config", "height_map"), &PrefabGeometryNative::build_vegetation_instances);
	ClassDB::bind_method(D_METHOD("build_vegetation_instances_with_render_payload", "config", "height_map", "render_space_inverse", "mesh_bounds"), &PrefabGeometryNative::build_vegetation_instances_with_render_payload);
	ClassDB::bind_method(D_METHOD("build_noise_samples", "noise_sampler", "chunk_origin_x", "chunk_origin_z", "chunk_stride", "step", "use_noise"), &PrefabGeometryNative::build_noise_samples);
	ClassDB::bind_method(D_METHOD("filter_removed_vegetation_entries", "entries", "removed_lookup"), &PrefabGeometryNative::filter_removed_vegetation_entries);
	ClassDB::bind_method(D_METHOD("build_global_vegetation_render_payload", "instances", "render_space_inverse", "mesh_bounds"), &PrefabGeometryNative::build_global_vegetation_render_payload);
	ClassDB::bind_method(D_METHOD("build_global_vegetation_cluster_render_payload", "payloads", "coord_keys", "bounds_padding"), &PrefabGeometryNative::build_global_vegetation_cluster_render_payload);
	ClassDB::bind_method(D_METHOD("pack_multimesh_buffer_from_instances", "instances"), &PrefabGeometryNative::pack_multimesh_buffer_from_instances);
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

Array PrefabGeometryNative::pick_nearest_candidates(const Array &candidates, int max_count) const {
	Array result;
	if (candidates.is_empty() || max_count <= 0) {
		return result;
	}

	const auto heap_comp = [](const NearestCandidate &a, const NearestCandidate &b) {
		return a.dist_sq < b.dist_sq;
	};

	std::vector<NearestCandidate> heap;
	heap.reserve(std::min<int>(candidates.size(), max_count));

	for (int i = 0; i < candidates.size(); ++i) {
		if (candidates[i].get_type() != Variant::DICTIONARY) {
			continue;
		}

		Dictionary candidate = candidates[i];
		const Variant dist_variant = candidate.get("dist_sq", 0.0);
		const double dist_sq = static_cast<double>(dist_variant);
		NearestCandidate entry;
		entry.dist_sq = dist_sq;
		entry.data = candidate;

		if (static_cast<int>(heap.size()) < max_count) {
			heap.push_back(std::move(entry));
			std::push_heap(heap.begin(), heap.end(), heap_comp);
			continue;
		}

		if (!heap.empty() && dist_sq >= heap.front().dist_sq) {
			continue;
		}

		std::pop_heap(heap.begin(), heap.end(), heap_comp);
		heap.back() = std::move(entry);
		std::push_heap(heap.begin(), heap.end(), heap_comp);
	}

	std::sort(heap.begin(), heap.end(), [](const NearestCandidate &a, const NearestCandidate &b) {
		return a.dist_sq < b.dist_sq;
	});

	result.resize(static_cast<int>(heap.size()));
	for (int i = 0; i < static_cast<int>(heap.size()); ++i) {
		result[i] = heap[i].data;
	}

	return result;
}

int PrefabGeometryNative::pick_nearest_pending_vegetation_chunk(const Array &pending_chunks, const Vector3 &viewer_pos, int chunk_stride) const {
	if (pending_chunks.is_empty()) {
		return -1;
	}
	if (chunk_stride <= 0) {
		return 0;
	}

	int best_index = 0;
	double best_distance_sq = std::numeric_limits<double>::infinity();
	const double stride = double(chunk_stride);
	for (int i = 0; i < pending_chunks.size(); ++i) {
		Vector2i coord;
		if (pending_chunks[i].get_type() == Variant::DICTIONARY) {
			const Dictionary item = pending_chunks[i];
			const Variant coord_variant = item.get("coord", Vector2i());
			if (coord_variant.get_type() == Variant::VECTOR2I) {
				coord = coord_variant;
			}
		}

		const double center_x = (double(coord.x) + 0.5) * stride;
		const double center_z = (double(coord.y) + 0.5) * stride;
		const double dx = double(viewer_pos.x) - center_x;
		const double dz = double(viewer_pos.z) - center_z;
		const double distance_sq = dx * dx + dz * dz;
		if (distance_sq < best_distance_sq) {
			best_distance_sq = distance_sq;
			best_index = i;
		}
	}
	return best_index;
}

Array PrefabGeometryNative::pick_nearby_vegetation_candidates(const Dictionary &chunk_data, const String &list_key, const String &item_key, const Vector3 &player_pos, int chunk_stride, double collider_distance, int max_count) const {
	Array result;
	if (chunk_data.is_empty() || list_key.is_empty() || item_key.is_empty() || chunk_stride <= 0 || collider_distance <= 0.0 || max_count <= 0) {
		return result;
	}

	const int player_chunk_x = int(std::floor(double(player_pos.x) / double(chunk_stride)));
	const int player_chunk_z = int(std::floor(double(player_pos.z) / double(chunk_stride)));
	const double max_dist_sq = collider_distance * collider_distance;

	const auto heap_comp = [](const NearestCandidate &a, const NearestCandidate &b) {
		return a.dist_sq < b.dist_sq;
	};
	std::vector<NearestCandidate> heap;
	heap.reserve(std::min<int>(max_count, 9));

	for (int dx = -1; dx <= 1; ++dx) {
		for (int dz = -1; dz <= 1; ++dz) {
			const Vector2i coord(player_chunk_x + dx, player_chunk_z + dz);
			if (!chunk_data.has(coord)) {
				continue;
			}
			if (!chunk_overlaps_radius(coord, player_pos, collider_distance, chunk_stride)) {
				continue;
			}

			const Variant data_variant = chunk_data.get(coord, Dictionary());
			if (data_variant.get_type() != Variant::DICTIONARY) {
				continue;
			}
			Dictionary data = data_variant;
			const Variant entries_variant = data.get(list_key, Array());
			if (entries_variant.get_type() != Variant::ARRAY) {
				continue;
			}
			Array entries = entries_variant;

			for (int i = 0; i < entries.size(); ++i) {
				if (entries[i].get_type() != Variant::DICTIONARY) {
					continue;
				}
				Dictionary entry = entries[i];
				if (!bool(entry.get("alive", false))) {
					continue;
				}

				const Variant world_pos_variant = entry.get("world_pos", Vector3());
				if (world_pos_variant.get_type() != Variant::VECTOR3) {
					continue;
				}
				const Vector3 world_pos = world_pos_variant;
				const double dist_sq = double(player_pos.distance_squared_to(world_pos));
				if (dist_sq >= max_dist_sq) {
					continue;
				}

				Dictionary candidate;
				candidate["coord"] = coord;
				candidate[item_key] = entry;
				candidate["dist_sq"] = dist_sq;

				NearestCandidate nearest;
				nearest.dist_sq = dist_sq;
				nearest.data = candidate;

				if (static_cast<int>(heap.size()) < max_count) {
					heap.push_back(std::move(nearest));
					std::push_heap(heap.begin(), heap.end(), heap_comp);
					continue;
				}

				if (!heap.empty() && dist_sq >= heap.front().dist_sq) {
					continue;
				}

				std::pop_heap(heap.begin(), heap.end(), heap_comp);
				heap.back() = std::move(nearest);
				std::push_heap(heap.begin(), heap.end(), heap_comp);
			}
		}
	}

	std::sort(heap.begin(), heap.end(), [](const NearestCandidate &a, const NearestCandidate &b) {
		return a.dist_sq < b.dist_sq;
	});

	result.resize(static_cast<int>(heap.size()));
	for (int i = 0; i < static_cast<int>(heap.size()); ++i) {
		result[i] = heap[i].data;
	}
	return result;
}

Dictionary PrefabGeometryNative::find_nearest_vegetation_ray_hit(const Dictionary &chunk_data, const String &list_key, const String &kind, const Vector3 &origin, const Vector3 &direction, double max_distance, double radius, double height, bool scale_by_entry) const {
	Dictionary empty;
	if (chunk_data.is_empty() || list_key.is_empty() || kind.is_empty() || max_distance <= 0.0 || direction.length_squared() <= 0.000001) {
		return empty;
	}

	const Vector3 ray_dir = direction.normalized();
	RayHitCandidate best;

	Array coord_keys = chunk_data.keys();
	for (int coord_index = 0; coord_index < coord_keys.size(); ++coord_index) {
		const Variant coord_variant = coord_keys[coord_index];
		const Variant data_variant = chunk_data.get(coord_variant, Dictionary());
		if (data_variant.get_type() != Variant::DICTIONARY) {
			continue;
		}
		Dictionary data = data_variant;
		const Variant entries_variant = data.get(list_key, Array());
		if (entries_variant.get_type() != Variant::ARRAY) {
			continue;
		}
		Array entries = entries_variant;

		for (int i = 0; i < entries.size(); ++i) {
			if (entries[i].get_type() != Variant::DICTIONARY) {
				continue;
			}
			Dictionary entry = entries[i];
			if (!bool(entry.get("alive", false))) {
				continue;
			}

			const int index = int(entry.get("index", -1));
			if (index < 0) {
				continue;
			}

			double instance_radius = radius;
			double instance_height = height;
			if (scale_by_entry) {
				const double instance_scale = std::max(0.1, double(entry.get("scale", 1.0)));
				instance_radius *= instance_scale;
				instance_height *= instance_scale;
			}

			const Vector3 fallback_world_pos = dictionary_get_vector3(entry, "world_pos");
			const Vector3 base_pos = dictionary_get_vector3(entry, "hit_pos", fallback_world_pos);
			double hit_distance = 0.0;
			double axis_distance_sq = 0.0;
			if (!intersect_vertical_vegetation_cylinder(origin, ray_dir, base_pos, instance_radius, instance_height, max_distance, hit_distance, axis_distance_sq)) {
				continue;
			}

			const double aim_distance_sq = vegetation_aim_distance_sq(kind, origin, ray_dir, base_pos, instance_height, max_distance);
			if (!is_better_ray_hit(hit_distance, aim_distance_sq, best)) {
				continue;
			}

			const Vector3 hit_point = origin + ray_dir * hit_distance;
			Dictionary candidate;
			candidate["kind"] = kind;
			candidate["coord"] = coord_variant;
			candidate["index"] = index;
			candidate["position"] = hit_point;
			candidate["distance"] = hit_distance;
			candidate["distance_sq_to_ray"] = aim_distance_sq;
			best.distance = hit_distance;
			best.distance_sq_to_ray = aim_distance_sq;
			best.data = candidate;
			best.valid = true;
		}
	}

	return best.valid ? best.data : empty;
}

Dictionary PrefabGeometryNative::find_nearest_tree_visual_bounds_ray_hit(const Dictionary &chunk_data, const String &list_key, const Vector3 &origin, const Vector3 &direction, double max_distance, const AABB &mesh_bounds, const Transform3D &base_transform, const Vector3 &rotation_fix, double bounds_padding) const {
	Dictionary empty;
	if (chunk_data.is_empty() || list_key.is_empty() || max_distance <= 0.0 || direction.length_squared() <= 0.000001) {
		return empty;
	}

	const Vector3 ray_dir = direction.normalized();
	RayHitCandidate best;

	Array coord_keys = chunk_data.keys();
	for (int coord_index = 0; coord_index < coord_keys.size(); ++coord_index) {
		const Variant coord_variant = coord_keys[coord_index];
		const Variant data_variant = chunk_data.get(coord_variant, Dictionary());
		if (data_variant.get_type() != Variant::DICTIONARY) {
			continue;
		}
		Dictionary data = data_variant;
		const Variant entries_variant = data.get(list_key, Array());
		if (entries_variant.get_type() != Variant::ARRAY) {
			continue;
		}
		Array entries = entries_variant;

		for (int i = 0; i < entries.size(); ++i) {
			if (entries[i].get_type() != Variant::DICTIONARY) {
				continue;
			}
			Dictionary entry = entries[i];
			if (!bool(entry.get("alive", false))) {
				continue;
			}

			const int index = int(entry.get("index", -1));
			if (index < 0) {
				continue;
			}

			const double instance_scale = std::max(0.1, double(entry.get("scale", 1.0)));
			const double rotation_angle = double(entry.get("rotation_angle", entry.get("rotation", 0.0)));
			const Vector3 fallback_hit_pos = dictionary_get_vector3(entry, "hit_pos");
			const Vector3 base_pos = dictionary_get_vector3(entry, "world_pos", fallback_hit_pos);
			const Vector3 ground_pos = dictionary_get_vector3(entry, "hit_pos", base_pos);
			const Transform3D transform = build_vegetation_transform(base_transform, rotation_fix, rotation_angle, instance_scale, base_pos);
			const AABB visual_bounds = grow_aabb(transform.xform(mesh_bounds), bounds_padding);

			double hit_distance = 0.0;
			if (!intersect_ray_aabb_bounds(origin, ray_dir, visual_bounds, max_distance, hit_distance)) {
				continue;
			}

			const Vector3 hit_point = origin + ray_dir * hit_distance;
			const double distance_sq_to_ray = vegetation_aim_distance_sq(String("tree"), origin, ray_dir, ground_pos, 0.0, max_distance);
			if (!is_better_ray_hit(hit_distance, distance_sq_to_ray, best)) {
				continue;
			}

			Dictionary candidate;
			candidate["kind"] = "tree";
			candidate["coord"] = coord_variant;
			candidate["index"] = index;
			candidate["position"] = hit_point;
			candidate["distance"] = hit_distance;
			candidate["distance_sq_to_ray"] = distance_sq_to_ray;
			best.distance = hit_distance;
			best.distance_sq_to_ray = distance_sq_to_ray;
			best.data = candidate;
			best.valid = true;
		}
	}

	return best.valid ? best.data : empty;
}

Dictionary PrefabGeometryNative::resolve_tree_body_collision(const Dictionary &chunk_tree_data, const Vector3 &body_origin, double body_radius, double body_height, int chunk_stride, double collision_radius, double collision_height) const {
	Dictionary empty;
	if (chunk_tree_data.is_empty() || chunk_stride <= 0 || body_radius <= 0.0 || body_height <= 0.0 || collision_radius <= 0.0 || collision_height <= 0.0) {
		return empty;
	}

	const int min_chunk_x = int(std::floor((double(body_origin.x) - collision_radius - body_radius) / double(chunk_stride)));
	const int max_chunk_x = int(std::floor((double(body_origin.x) + collision_radius + body_radius) / double(chunk_stride)));
	const int min_chunk_z = int(std::floor((double(body_origin.z) - collision_radius - body_radius) / double(chunk_stride)));
	const int max_chunk_z = int(std::floor((double(body_origin.z) + collision_radius + body_radius) / double(chunk_stride)));
	const double body_min_y = double(body_origin.y);
	const double body_max_y = double(body_origin.y) + body_height;
	Vector3 total_push;
	int hit_count = 0;

	for (int chunk_x = min_chunk_x; chunk_x <= max_chunk_x; ++chunk_x) {
		for (int chunk_z = min_chunk_z; chunk_z <= max_chunk_z; ++chunk_z) {
			const Vector2i coord(chunk_x, chunk_z);
			if (!chunk_tree_data.has(coord)) {
				continue;
			}
			const Variant data_variant = chunk_tree_data.get(coord, Dictionary());
			if (data_variant.get_type() != Variant::DICTIONARY) {
				continue;
			}
			Dictionary data = data_variant;
			const Variant trees_variant = data.get("trees", Array());
			if (trees_variant.get_type() != Variant::ARRAY) {
				continue;
			}
			Array trees = trees_variant;

			for (int i = 0; i < trees.size(); ++i) {
				if (trees[i].get_type() != Variant::DICTIONARY) {
					continue;
				}
				Dictionary tree = trees[i];
				if (!bool(tree.get("alive", false))) {
					continue;
				}

				const double tree_scale = std::max(0.1, double(tree.get("scale", 1.0)));
				const Vector3 fallback_world_pos = dictionary_get_vector3(tree, "world_pos");
				const Vector3 tree_base = dictionary_get_vector3(tree, "hit_pos", fallback_world_pos);
				const double tree_min_y = double(tree_base.y);
				const double tree_max_y = double(tree_base.y) + collision_height * tree_scale;
				if (body_max_y < tree_min_y || body_min_y > tree_max_y) {
					continue;
				}

				const double combined_radius = collision_radius * tree_scale + body_radius;
				const double dx = double(body_origin.x - tree_base.x);
				const double dz = double(body_origin.z - tree_base.z);
				const double dist_sq = dx * dx + dz * dz;
				if (dist_sq >= combined_radius * combined_radius) {
					continue;
				}

				const double dist = std::sqrt(std::max(dist_sq, 0.0001));
				const double penetration = combined_radius - dist;
				total_push += Vector3(dx / dist * penetration, 0.0, dz / dist * penetration);
				++hit_count;
			}
		}
	}

	if (hit_count == 0) {
		return empty;
	}

	Dictionary result;
	result["push"] = total_push;
	result["hits"] = hit_count;
	return result;
}

Dictionary PrefabGeometryNative::build_world_map_height_biome_bytes(
		int map_size,
		int world_size,
		int world_seed,
		double noise_frequency,
		double terrain_height,
		double max_height,
		int grass_material_id,
		int sand_material_id,
		int snow_material_id,
		int gravel_material_id) const {
	Dictionary result;
	if (map_size <= 0 || world_size <= 0 || max_height <= 0.0) {
		return result;
	}

	const int64_t total = static_cast<int64_t>(map_size) * static_cast<int64_t>(map_size);
	if (total <= 0 || total > std::numeric_limits<int32_t>::max()) {
		return result;
	}

	PackedByteArray height_bytes;
	height_bytes.resize(static_cast<int>(total));
	PackedByteArray biome_bytes;
	biome_bytes.resize(static_cast<int>(total));
	uint8_t *height_write = height_bytes.ptrw();
	uint8_t *biome_write = biome_bytes.ptrw();
	const double half_world_size = double(world_size) * 0.5;
	const double sample_scale = double(world_size) / double(map_size);

	const auto fill_rows = [&](int start_z, int end_z) {
		fastnoiselite::FastNoiseLite height_noise(world_seed);
		height_noise.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_Value);
		height_noise.SetFrequency(static_cast<float>(noise_frequency));
		height_noise.SetFractalType(fastnoiselite::FastNoiseLite::FractalType_FBm);
		height_noise.SetFractalOctaves(5);
		height_noise.SetFractalLacunarity(2.0f);
		height_noise.SetFractalGain(0.5f);

		fastnoiselite::FastNoiseLite biome_noise(world_seed + 100);
		biome_noise.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_OpenSimplex2);
		biome_noise.SetFrequency(0.002f);
		biome_noise.SetFractalType(fastnoiselite::FastNoiseLite::FractalType_FBm);
		biome_noise.SetFractalOctaves(3);
		biome_noise.SetFractalGain(0.5f);

		for (int z = start_z; z < end_z; ++z) {
			const float world_z = static_cast<float>(double(z) * sample_scale - half_world_size);
			const int row_offset = z * map_size;
			for (int x = 0; x < map_size; ++x) {
				const float world_x = static_cast<float>(double(x) * sample_scale - half_world_size);
				const int index = row_offset + x;
				const double height_raw = static_cast<double>(height_noise.GetNoise(world_x, world_z));
				const double height = terrain_height + (height_raw * 0.5 + 0.5) * terrain_height;
				const double normalized_height = std::clamp(height / max_height, 0.0, 1.0);
				const int encoded_height = static_cast<int>(std::round(normalized_height * 255.0));
				height_write[index] = static_cast<uint8_t>(std::clamp(encoded_height, 0, 255));

				const double biome_value = static_cast<double>(biome_noise.GetNoise(world_x, world_z));
				int biome = grass_material_id;
				if (biome_value < -0.2) {
					biome = sand_material_id;
				} else if (biome_value > 0.6) {
					biome = snow_material_id;
				} else if (biome_value > 0.2) {
					biome = gravel_material_id;
				}
				biome_write[index] = static_cast<uint8_t>(std::clamp(biome, 0, 255));
			}
		}
	};

	const int worker_count = native_row_worker_count(map_size);
	if (worker_count <= 1) {
		fill_rows(0, map_size);
	} else {
		std::vector<std::thread> workers;
		workers.reserve(worker_count);
		for (int worker = 0; worker < worker_count; ++worker) {
			const int start_z = worker * map_size / worker_count;
			const int end_z = (worker + 1) * map_size / worker_count;
			workers.emplace_back(fill_rows, start_z, end_z);
		}
		for (std::thread &worker_thread : workers) {
			worker_thread.join();
		}
	}

	result["height_bytes"] = height_bytes;
	result["biome_bytes"] = biome_bytes;
	result["pixel_count"] = static_cast<int>(total);
	result["worker_count"] = worker_count;
	return result;
}

Dictionary PrefabGeometryNative::apply_world_map_lakes(
		const PackedByteArray &water_data,
		const PackedByteArray &road_data,
		const PackedByteArray &height_data,
		int map_size,
		int world_size,
		int world_seed,
		double lake_threshold,
		double road_width,
		double road_blend_margin,
		int road_block_threshold,
		double terrain_height,
		double water_level,
		double max_height,
		bool deep_lakes_enabled) const {
	Dictionary result;
	if (map_size <= 0 || world_size <= 0 || max_height <= 0.0) {
		return result;
	}

	const int64_t pixel_count_64 = static_cast<int64_t>(map_size) * static_cast<int64_t>(map_size);
	const int64_t road_byte_count_64 = pixel_count_64 * 2;
	if (
			pixel_count_64 <= 0 ||
			pixel_count_64 > std::numeric_limits<int32_t>::max() ||
			water_data.size() < pixel_count_64 ||
			height_data.size() < pixel_count_64 ||
			road_data.size() < road_byte_count_64) {
		return result;
	}

	PackedByteArray water_bytes = water_data;
	PackedByteArray height_bytes = height_data;
	uint8_t *water_write = water_bytes.ptrw();
	uint8_t *height_write = height_bytes.ptrw();
	const uint8_t *road_read = road_data.ptr();

	const double water_road_buffer = road_width * 0.5 + road_blend_margin;
	const int road_buffer_pixels = static_cast<int>(water_road_buffer);
	const double lake_cutoff = lake_threshold - 0.05;
	const double shore_submerge = 1.25;
	const double basin_depth_max = std::clamp(terrain_height * 0.65, 2.5, 8.0);
	const double half_world_size = double(world_size) * 0.5;
	const double sample_scale = double(world_size) / double(map_size);
	const int threshold = std::clamp(road_block_threshold, 0, 255);

	struct LakeWorkerCounts {
		int water_pixels = 0;
		int carved_pixels = 0;
		int road_blocked_pixels = 0;
		int near_road_blocked_pixels = 0;
	};

	const auto process_rows = [&](int start_z, int end_z, LakeWorkerCounts &counts) {
		fastnoiselite::FastNoiseLite lake_noise(world_seed + 300);
		lake_noise.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_OpenSimplex2);
		lake_noise.SetFrequency(0.0008f);
		lake_noise.SetFractalType(fastnoiselite::FastNoiseLite::FractalType_None);

		for (int z = start_z; z < end_z; ++z) {
			const float world_z = static_cast<float>(double(z) * sample_scale - half_world_size);
			const int row_offset = z * map_size;
			for (int x = 0; x < map_size; ++x) {
				const float world_x = static_cast<float>(double(x) * sample_scale - half_world_size);
				const int index = row_offset + x;
				const int road_index = index * 2;

				if (road_read[road_index] >= threshold) {
					counts.road_blocked_pixels += 1;
					continue;
				}

				bool near_road = false;
				for (int dr = -road_buffer_pixels; dr <= road_buffer_pixels; dr += 4) {
					const int check_x = x + dr;
					if (check_x >= 0 && check_x < map_size) {
						const int check_road_index = (z * map_size + check_x) * 2;
						if (road_read[check_road_index] >= threshold) {
							near_road = true;
							break;
						}
					}

					const int check_z = z + dr;
					if (check_z >= 0 && check_z < map_size) {
						const int check_road_index = (check_z * map_size + x) * 2;
						if (road_read[check_road_index] >= threshold) {
							near_road = true;
							break;
						}
					}
				}
				if (near_road) {
					counts.near_road_blocked_pixels += 1;
					continue;
				}

				const double lake_value = static_cast<double>(lake_noise.GetNoise(world_x, world_z));
				if (lake_value <= lake_cutoff) {
					continue;
				}

				water_write[index] = 255;
				counts.water_pixels += 1;
				if (!deep_lakes_enabled) {
					continue;
				}

				double depth_t = std::clamp((lake_value - lake_cutoff) / std::max(0.001, 1.0 - lake_cutoff), 0.0, 1.0);
				depth_t = depth_t * depth_t * (3.0 - 2.0 * depth_t);
				const double current_height = double(height_write[index]) / 255.0 * max_height;
				const double target_height = water_level - shore_submerge - basin_depth_max * depth_t;
				if (current_height > target_height) {
					height_write[index] = encode_height_byte_native(target_height, max_height);
					counts.carved_pixels += 1;
				}
			}
		}
	};

	const int worker_count = native_row_worker_count(map_size);
	std::vector<LakeWorkerCounts> worker_counts(worker_count);
	if (worker_count <= 1) {
		process_rows(0, map_size, worker_counts[0]);
	} else {
		std::vector<std::thread> workers;
		workers.reserve(worker_count);
		for (int worker = 0; worker < worker_count; ++worker) {
			const int start_z = worker * map_size / worker_count;
			const int end_z = (worker + 1) * map_size / worker_count;
			workers.emplace_back(process_rows, start_z, end_z, std::ref(worker_counts[worker]));
		}
		for (std::thread &worker_thread : workers) {
			worker_thread.join();
		}
	}

	int water_pixels = 0;
	int carved_pixels = 0;
	int road_blocked_pixels = 0;
	int near_road_blocked_pixels = 0;
	for (const LakeWorkerCounts &counts : worker_counts) {
		water_pixels += counts.water_pixels;
		carved_pixels += counts.carved_pixels;
		road_blocked_pixels += counts.road_blocked_pixels;
		near_road_blocked_pixels += counts.near_road_blocked_pixels;
	}

	result["water_bytes"] = water_bytes;
	result["height_bytes"] = height_bytes;
	result["pixel_count"] = static_cast<int>(pixel_count_64);
	result["water_pixel_count"] = water_pixels;
	result["height_carve_count"] = carved_pixels;
	result["road_blocked_pixel_count"] = road_blocked_pixels;
	result["near_road_blocked_pixel_count"] = near_road_blocked_pixels;
	result["worker_count"] = worker_count;
	return result;
}

Dictionary PrefabGeometryNative::build_world_map_minimap_rgb_bytes(
		const PackedByteArray &height_data,
		const PackedByteArray &biome_data,
		const PackedByteArray &road_data,
		const PackedByteArray &water_data,
		const PackedByteArray &building_data,
		int width,
		int height,
		const PackedInt32Array &material_rgb_lut,
		int road_material_id,
		int water_r,
		int water_g,
		int water_b,
		int building_r,
		int building_g,
		int building_b) const {
	Dictionary result;
	if (width <= 0 || height <= 0) {
		return result;
	}

	const int64_t pixel_count_64 = static_cast<int64_t>(width) * static_cast<int64_t>(height);
	if (
			pixel_count_64 <= 0 ||
			pixel_count_64 > std::numeric_limits<int32_t>::max() ||
			pixel_count_64 > std::numeric_limits<int32_t>::max() / 3 ||
			height_data.size() < pixel_count_64 ||
			biome_data.size() < pixel_count_64) {
		return result;
	}

	const int pixel_count = static_cast<int>(pixel_count_64);
	PackedByteArray rgb_bytes;
	rgb_bytes.resize(pixel_count * 3);

	const uint8_t *height_read = height_data.ptr();
	const uint8_t *biome_read = biome_data.ptr();
	const uint8_t *road_read = road_data.ptr();
	const uint8_t *water_read = water_data.ptr();
	const uint8_t *building_read = building_data.ptr();
	const int32_t *lut_read = material_rgb_lut.ptr();
	const int lut_size = material_rgb_lut.size();
	uint8_t *rgb_write = rgb_bytes.ptrw();

	const int road_size = road_data.size();
	const int water_size = water_data.size();
	const int building_size = building_data.size();
	const int clamped_water_r = std::clamp(water_r, 0, 255);
	const int clamped_water_g = std::clamp(water_g, 0, 255);
	const int clamped_water_b = std::clamp(water_b, 0, 255);
	const int clamped_building_r = std::clamp(building_r, 0, 255);
	const int clamped_building_g = std::clamp(building_g, 0, 255);
	const int clamped_building_b = std::clamp(building_b, 0, 255);

	struct MinimapWorkerCounts {
		int road_pixels = 0;
		int water_pixels = 0;
		int building_pixels = 0;
	};

	const auto process_rows = [&](int start_y, int end_y, MinimapWorkerCounts &counts) {
		for (int y = start_y; y < end_y; ++y) {
			const int row_offset = y * width;
			for (int x = 0; x < width; ++x) {
				const int index = row_offset + x;
				const double shade = 0.5 + (static_cast<double>(height_read[index]) / 255.0) * 0.5;
				int r = 80;
				int g = 160;
				int b = 60;
				lookup_minimap_lut_rgb(lut_read, lut_size, static_cast<int>(biome_read[index]), r, g, b);

				const int road_index = index * 2;
				if (road_index < road_size && road_read[road_index] > 128) {
					lookup_minimap_lut_rgb(lut_read, lut_size, road_material_id, r, g, b);
					counts.road_pixels += 1;
				}

				if (index < water_size && water_read[index] > 128) {
					r = clamped_water_r;
					g = clamped_water_g;
					b = clamped_water_b;
					counts.water_pixels += 1;
				}

				if (index < building_size && building_read[index] > 128) {
					r = clamped_building_r;
					g = clamped_building_g;
					b = clamped_building_b;
					counts.building_pixels += 1;
				}

				const int rgb_index = index * 3;
				rgb_write[rgb_index] = encode_shaded_rgb_byte(r, shade);
				rgb_write[rgb_index + 1] = encode_shaded_rgb_byte(g, shade);
				rgb_write[rgb_index + 2] = encode_shaded_rgb_byte(b, shade);
			}
		}
	};

	const int worker_count = native_row_worker_count(height);
	std::vector<MinimapWorkerCounts> worker_counts(worker_count);
	if (worker_count <= 1) {
		process_rows(0, height, worker_counts[0]);
	} else {
		std::vector<std::thread> workers;
		workers.reserve(worker_count);
		for (int worker = 0; worker < worker_count; ++worker) {
			const int start_y = worker * height / worker_count;
			const int end_y = (worker + 1) * height / worker_count;
			workers.emplace_back(process_rows, start_y, end_y, std::ref(worker_counts[worker]));
		}
		for (std::thread &worker_thread : workers) {
			worker_thread.join();
		}
	}

	int road_pixels = 0;
	int water_pixels = 0;
	int building_pixels = 0;
	for (const MinimapWorkerCounts &counts : worker_counts) {
		road_pixels += counts.road_pixels;
		water_pixels += counts.water_pixels;
		building_pixels += counts.building_pixels;
	}

	result["rgb_bytes"] = rgb_bytes;
	result["pixel_count"] = pixel_count;
	result["worker_count"] = worker_count;
	result["road_pixel_count"] = road_pixels;
	result["water_pixel_count"] = water_pixels;
	result["building_pixel_count"] = building_pixels;
	return result;
}

Dictionary PrefabGeometryNative::rasterize_world_map_segments(
		const Array &segments,
		const PackedByteArray &height_data,
		const PackedByteArray &biome_data,
		const PackedByteArray &road_data,
		int map_size,
		int world_seed,
		double road_blend_margin,
		double default_width,
		double max_height,
		int road_material_id,
		bool path_mode) const {
	Dictionary result;
	if (map_size <= 0 || max_height <= 0.0 || default_width <= 0.0) {
		return result;
	}

	const int64_t pixel_count_64 = static_cast<int64_t>(map_size) * static_cast<int64_t>(map_size);
	const int64_t road_byte_count_64 = pixel_count_64 * 2;
	if (
			pixel_count_64 <= 0 ||
			pixel_count_64 > std::numeric_limits<int32_t>::max() ||
			height_data.size() < pixel_count_64 ||
			biome_data.size() < pixel_count_64 ||
			road_data.size() < road_byte_count_64) {
		return result;
	}

	PackedByteArray height_bytes = height_data;
	PackedByteArray biome_bytes = biome_data;
	PackedByteArray road_bytes = road_data;
	uint8_t *height_write = height_bytes.ptrw();
	uint8_t *biome_write = biome_bytes.ptrw();
	uint8_t *road_write = road_bytes.ptrw();

	fastnoiselite::FastNoiseLite road_noise(world_seed + 200);
	road_noise.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_ValueCubic);
	road_noise.SetFrequency(0.008f);
	road_noise.SetFractalType(fastnoiselite::FastNoiseLite::FractalType_FBm);
	road_noise.SetFractalOctaves(5);
	road_noise.SetFractalLacunarity(2.0f);
	road_noise.SetFractalGain(0.5f);

	const int half = map_size / 2;
	const uint8_t road_material = static_cast<uint8_t>(std::clamp(road_material_id, 0, 255));
	int valid_segments = 0;
	int scanned_pixels = 0;
	int touched_pixels = 0;
	int surface_pixels = 0;
	int blend_pixels = 0;

	for (int segment_index = 0; segment_index < segments.size(); ++segment_index) {
		const Variant segment_variant = segments[segment_index];
		if (segment_variant.get_type() != Variant::DICTIONARY) {
			continue;
		}
		const Dictionary segment = segment_variant;
		Vector2 from_v;
		Vector2 to_v;
		if (!variant_to_vector2(segment.get("from", Vector2()), from_v) ||
				!variant_to_vector2(segment.get("to", Vector2()), to_v)) {
			continue;
		}

		const double seg_width = std::max(0.001, double(segment.get("width", default_width)));
		const Vector2 delta = to_v - from_v;
		const double seg_len = std::sqrt(double(delta.length_squared()));
		if (seg_len < (path_mode ? 0.5 : 1.0)) {
			continue;
		}
		valid_segments += 1;

		const Vector2 dir = delta / float(seg_len);
		const double half_width = seg_width * 0.5;
		const double from_y = double(segment.get("from_y", 12.0));
		const double to_y = double(segment.get("to_y", from_y));
		const double rise = std::abs(to_y - from_y);
		const double flatten_width = path_mode
				? (seg_width * 2.5 + road_blend_margin + rise * 0.85)
				: (seg_width + road_blend_margin);

		const int min_x = std::clamp(static_cast<int>(std::min(from_v.x, to_v.x) - flatten_width) + half, 0, map_size - 1);
		const int max_x = std::clamp(static_cast<int>(std::max(from_v.x, to_v.x) + flatten_width) + half, 0, map_size - 1);
		const int min_z = std::clamp(static_cast<int>(std::min(from_v.y, to_v.y) - flatten_width) + half, 0, map_size - 1);
		const int max_z = std::clamp(static_cast<int>(std::max(from_v.y, to_v.y) + flatten_width) + half, 0, map_size - 1);

		for (int pz = min_z; pz <= max_z; ++pz) {
			const double wz = double(pz - half);
			const int row_offset = pz * map_size;
			for (int px = min_x; px <= max_x; ++px) {
				scanned_pixels += 1;
				const double wx = double(px - half);
				const Vector2 point{float(wx), float(wz)};
				const Vector2 ap = point - from_v;
				const double projection = std::clamp(double(ap.dot(dir)), 0.0, seg_len);
				const Vector2 closest = from_v + dir * float(projection);
				const double dist = std::sqrt(double((point - closest).length_squared()));
				if (dist > flatten_width) {
					continue;
				}

				const int pixel_index = row_offset + px;
				const int road_index = pixel_index * 2;
				touched_pixels += 1;

				if (path_mode) {
					const double path_u = projection / seg_len;
					const double eased_u = smoothstep01(path_u);
					const double path_y = lerp_double(from_y, to_y, eased_u);
					if (dist < half_width) {
						const int road_height_byte = static_cast<int>(std::clamp(path_y / 64.0, 0.0, 1.0) * 255.0);
						road_write[road_index] = static_cast<uint8_t>(std::max<int>(road_write[road_index], 196));
						road_write[road_index + 1] = static_cast<uint8_t>(std::max<int>(road_write[road_index + 1], road_height_byte));
						biome_write[pixel_index] = road_material;
						height_write[pixel_index] = encode_height_byte_native(path_y, max_height);
						surface_pixels += 1;
					} else {
						const double blend_t = std::clamp((dist - half_width) / std::max(0.001, flatten_width - half_width), 0.0, 1.0);
						const double smooth_t = smoothstep01(smoothstep01(blend_t));
						const double original_height = double(height_write[pixel_index]) / 255.0 * max_height;
						height_write[pixel_index] = encode_height_byte_native(lerp_double(path_y, original_height, smooth_t), max_height);
						blend_pixels += 1;
					}
					continue;
				}

				const double road_height = stepped_road_height_native(road_noise, closest.x, closest.y);
				if (dist < half_width) {
					const int road_height_byte = static_cast<int>(std::clamp(road_height / 64.0, 0.0, 1.0) * 255.0);
					road_write[road_index] = 255;
					road_write[road_index + 1] = static_cast<uint8_t>(std::clamp(road_height_byte, 0, 255));
					biome_write[pixel_index] = road_material;
					height_write[pixel_index] = encode_height_byte_native(road_height, max_height);
					surface_pixels += 1;
				} else {
					const double blend_t = std::clamp((dist - half_width) / std::max(0.001, flatten_width - half_width), 0.0, 1.0);
					const double original_height = double(height_write[pixel_index]) / 255.0 * max_height;
					height_write[pixel_index] = encode_height_byte_native(lerp_double(road_height, original_height, blend_t), max_height);
					blend_pixels += 1;
				}
			}
		}
	}

	result["height_bytes"] = height_bytes;
	result["biome_bytes"] = biome_bytes;
	result["road_bytes"] = road_bytes;
	result["segment_count"] = valid_segments;
	result["scanned_pixel_count"] = scanned_pixels;
	result["touched_pixel_count"] = touched_pixels;
	result["surface_pixel_count"] = surface_pixels;
	result["blend_pixel_count"] = blend_pixels;
	result["path_mode"] = path_mode;
	return result;
}

Dictionary PrefabGeometryNative::footprint_hits_world_map_road_segments(
		const Array &segments,
		double bldg_x,
		double bldg_z,
		const Vector2i &footprint,
		double default_width,
		double road_blend_margin) const {
	Dictionary result;
	if (footprint.x <= 0 || footprint.y <= 0 || default_width <= 0.0) {
		return result;
	}

	const Vector2 rect_min{float(bldg_x), float(bldg_z)};
	const Vector2 rect_max{float(bldg_x + double(footprint.x)), float(bldg_z + double(footprint.y))};
	bool hit = false;
	int checked_segments = 0;
	int valid_segments = 0;

	for (int segment_index = 0; segment_index < segments.size(); ++segment_index) {
		const Variant segment_variant = segments[segment_index];
		if (segment_variant.get_type() != Variant::DICTIONARY) {
			continue;
		}
		const Dictionary segment = segment_variant;
		Vector2 from_v;
		Vector2 to_v;
		if (!variant_to_vector2(segment.get("from", Vector2()), from_v) ||
				!variant_to_vector2(segment.get("to", Vector2()), to_v)) {
			continue;
		}
		valid_segments += 1;
		checked_segments += 1;
		const double width = std::max(0.001, double(segment.get("width", default_width)));
		const double clearance_radius = width * 0.5 + road_blend_margin + 0.75;
		if (distance_segment_to_rect_2d(from_v, to_v, rect_min, rect_max) <= clearance_radius) {
			hit = true;
			break;
		}
	}

	result["hit"] = hit;
	result["checked_segment_count"] = checked_segments;
	result["valid_segment_count"] = valid_segments;
	return result;
}

Dictionary PrefabGeometryNative::footprint_hits_packed_world_map_road_segments(
		const PackedFloat32Array &segment_data,
		double bldg_x,
		double bldg_z,
		const Vector2i &footprint) const {
	Dictionary result;
	if (footprint.x <= 0 || footprint.y <= 0 || segment_data.size() < 5) {
		return result;
	}

	const int segment_count = segment_data.size() / 5;
	const float *segment_read = segment_data.ptr();
	const Vector2 rect_min{float(bldg_x), float(bldg_z)};
	const Vector2 rect_max{float(bldg_x + double(footprint.x)), float(bldg_z + double(footprint.y))};
	bool hit = false;
	int checked_segments = 0;

	for (int segment_index = 0; segment_index < segment_count; ++segment_index) {
		const int base = segment_index * 5;
		const Vector2 from_v{segment_read[base], segment_read[base + 1]};
		const Vector2 to_v{segment_read[base + 2], segment_read[base + 3]};
		const double clearance_radius = std::max(0.0, double(segment_read[base + 4]));
		checked_segments += 1;
		if (distance_segment_to_rect_2d(from_v, to_v, rect_min, rect_max) <= clearance_radius) {
			hit = true;
			break;
		}
	}

	result["hit"] = hit;
	result["checked_segment_count"] = checked_segments;
	result["valid_segment_count"] = segment_count;
	return result;
}

Dictionary PrefabGeometryNative::resolve_world_map_building_support(
		const PackedByteArray &height_data,
		int map_size,
		double bldg_x,
		double bldg_z,
		const Vector2i &footprint,
		double max_height,
		int half,
		const Dictionary &config) const {
	Dictionary empty;
	if (map_size <= 0 || max_height <= 0.0 || footprint.x <= 0 || footprint.y <= 0) {
		return empty;
	}

	const int64_t pixel_count_64 = static_cast<int64_t>(map_size) * static_cast<int64_t>(map_size);
	if (pixel_count_64 <= 0 || pixel_count_64 > std::numeric_limits<int32_t>::max() || height_data.size() < pixel_count_64) {
		return empty;
	}

	const uint8_t *height_read = height_data.ptr();
	const int min_x = std::clamp(static_cast<int>(std::floor(bldg_x)) + half, 0, map_size - 1);
	const int min_z = std::clamp(static_cast<int>(std::floor(bldg_z)) + half, 0, map_size - 1);
	const int max_x = std::clamp(static_cast<int>(std::ceil(bldg_x + double(footprint.x) - 1.0)) + half, 0, map_size - 1);
	const int max_z = std::clamp(static_cast<int>(std::ceil(bldg_z + double(footprint.y) - 1.0)) + half, 0, map_size - 1);

	double height_sum = 0.0;
	int preferred_sample_count = 0;
	for (int z = min_z; z <= max_z; z += 2) {
		const int row_offset = z * map_size;
		for (int x = min_x; x <= max_x; x += 2) {
			height_sum += clamp_support_height_byte(height_read[row_offset + x], max_height);
			preferred_sample_count += 1;
		}
	}
	const double preferred_y = preferred_sample_count > 0 ? height_sum / double(preferred_sample_count) : 12.0;

	const std::vector<Vector2> sample_points = build_support_sample_points(footprint, config);
	if (sample_points.empty()) {
		Dictionary result;
		result["valid"] = false;
		result["reason"] = "no_samples";
		return result;
	}

	std::vector<double> heights;
	heights.reserve(sample_points.size());
	double min_h = std::numeric_limits<double>::infinity();
	double max_h = -std::numeric_limits<double>::infinity();
	double sum_h = 0.0;
	for (const Vector2 &offset : sample_points) {
		const double sampled = sample_world_map_support_height(height_read, map_size, bldg_x + double(offset.x), bldg_z + double(offset.y), max_height, half);
		if (std::isnan(sampled) || sampled <= -900.0) {
			Dictionary result;
			result["valid"] = false;
			result["reason"] = "missing_height";
			return result;
		}
		heights.push_back(sampled);
		min_h = std::min(min_h, sampled);
		max_h = std::max(max_h, sampled);
		sum_h += sampled;
	}
	if (heights.empty()) {
		Dictionary result;
		result["valid"] = false;
		result["reason"] = "no_heights";
		return result;
	}

	std::vector<double> sorted = heights;
	std::sort(sorted.begin(), sorted.end());
	const double mean_h = sum_h / double(heights.size());
	double median_h = sorted[sorted.size() / 2];
	if (sorted.size() % 2 == 0 && sorted.size() > 1) {
		const int upper_idx = int(sorted.size() / 2);
		const int lower_idx = std::max(0, upper_idx - 1);
		median_h = (sorted[lower_idx] + sorted[upper_idx]) * 0.5;
	}

	const int search_radius = std::max(1, int(config.get("search_radius", 3)));
	const double seed_values[] = {
		std::floor(min_h), std::round(min_h), std::ceil(min_h),
		std::floor(mean_h), std::round(mean_h), std::ceil(mean_h),
		std::floor(median_h), std::round(median_h), std::ceil(median_h),
		std::floor(max_h), std::round(max_h), std::ceil(max_h),
		std::floor(preferred_y), std::round(preferred_y), std::ceil(preferred_y)
	};
	std::unordered_set<int> unique_levels;
	unique_levels.reserve(64);
	for (const double seed : seed_values) {
		const int seed_int = int(seed);
		for (int delta = -search_radius; delta <= search_radius; ++delta) {
			unique_levels.insert(seed_int + delta);
		}
	}
	std::vector<int> candidate_levels(unique_levels.begin(), unique_levels.end());
	std::sort(candidate_levels.begin(), candidate_levels.end());
	if (candidate_levels.empty()) {
		Dictionary result;
		result["valid"] = false;
		result["reason"] = "no_candidates";
		return result;
	}

	const double float_weight = double(config.get("float_weight", 7.0));
	const double embed_weight = double(config.get("embed_weight", 3.5));
	const double float_peak_weight = double(config.get("float_peak_weight", 5.5));
	const double embed_peak_weight = double(config.get("embed_peak_weight", 4.0));
	const double preferred_weight = double(config.get("preferred_weight", 0.35));
	const double balance_weight = double(config.get("balance_weight", 0.75));
	const double count = std::max(1.0, double(heights.size()));

	bool has_best = false;
	double best_level = 0.0;
	double best_avg_float = 0.0;
	double best_avg_embed = 0.0;
	double best_max_float = 0.0;
	double best_max_embed = 0.0;
	double best_score = 0.0;

	for (const int level_int : candidate_levels) {
		const double level_y = double(level_int);
		double total_float = 0.0;
		double total_embed = 0.0;
		double max_float = 0.0;
		double max_embed = 0.0;
		for (const double height : heights) {
			const double delta = level_y - height;
			if (delta >= 0.0) {
				total_float += delta;
				max_float = std::max(max_float, delta);
			} else {
				const double embed = -delta;
				total_embed += embed;
				max_embed = std::max(max_embed, embed);
			}
		}

		const double avg_float = total_float / count;
		const double avg_embed = total_embed / count;
		const double score = (
				total_float * float_weight +
				total_embed * embed_weight +
				max_float * max_float * float_peak_weight +
				max_embed * max_embed * embed_peak_weight +
				std::abs(level_y - preferred_y) * preferred_weight +
				std::abs(avg_float - avg_embed) * balance_weight);
		if (!has_best || score < best_score) {
			has_best = true;
			best_level = level_y;
			best_avg_float = avg_float;
			best_avg_embed = avg_embed;
			best_max_float = max_float;
			best_max_embed = max_embed;
			best_score = score;
		}
	}

	const double max_float_gap = double(config.get("max_float_gap", 0.75));
	const double max_embed_depth = double(config.get("max_embed_depth", 1.5));
	const double max_height_range = double(config.get("max_height_range", 0.0));
	const double height_range = max_h - min_h;

	Dictionary result;
	result["resolved_y"] = best_level;
	result["avg_float_gap"] = best_avg_float;
	result["avg_embed_depth"] = best_avg_embed;
	result["max_float_gap"] = best_max_float;
	result["max_embed_depth"] = best_max_embed;
	result["score"] = best_score;
	result["preferred_y"] = preferred_y;
	result["mean_height"] = mean_h;
	result["median_height"] = median_h;
	result["min_height"] = min_h;
	result["max_height"] = max_h;
	result["height_range"] = height_range;
	result["valid"] = (
			best_max_float <= max_float_gap &&
			best_max_embed <= max_embed_depth &&
			(max_height_range <= 0.0 || height_range <= max_height_range));
	result["origin"] = Vector2(float(bldg_x), float(bldg_z));
	result["footprint"] = footprint;
	result["sample_count"] = int(heights.size());
	result["preferred_sample_count"] = preferred_sample_count;
	result["backend"] = "native";
	return result;
}

Dictionary PrefabGeometryNative::flatten_world_map_building_pad(
		const PackedByteArray &height_data,
		int map_size,
		double bldg_x,
		double bldg_z,
		const Vector2i &footprint,
		double bldg_y,
		double max_height,
		int half,
		double support_height_range,
		const Dictionary &protected_columns) const {
	Dictionary result;
	if (map_size <= 0 || max_height <= 0.0 || footprint.x <= 0 || footprint.y <= 0) {
		return result;
	}

	const int64_t pixel_count_64 = static_cast<int64_t>(map_size) * static_cast<int64_t>(map_size);
	if (pixel_count_64 <= 0 || pixel_count_64 > std::numeric_limits<int32_t>::max() || height_data.size() < pixel_count_64) {
		return result;
	}

	std::unordered_set<Vector2i, Vector2iHash> protected_set;
	if (!protected_columns.is_empty()) {
		const Array keys = protected_columns.keys();
		protected_set.reserve(keys.size());
		for (int i = 0; i < keys.size(); ++i) {
			Vector2i key;
			if (variant_to_vector2i(keys[i], key)) {
				protected_set.insert(key);
			}
		}
	}

	const uint8_t *height_read = height_data.ptr();
	PackedInt32Array changed_indices;
	PackedByteArray changed_values;
	const uint8_t flat_height_byte = encode_height_byte_native(bldg_y, max_height);
	const double longest_side = std::max(double(footprint.x), double(footprint.y));
	const double support_range = support_height_range;
	const int pad = std::max(6, static_cast<int>(std::ceil(longest_side * 0.5 + support_range * 1.25)));
	const int base_world_x = static_cast<int>(std::floor(bldg_x));
	const int base_world_z = static_cast<int>(std::floor(bldg_z));
	const int map_base_x = static_cast<int>(bldg_x + double(half));
	const int map_base_z = static_cast<int>(bldg_z + double(half));
	const int width = footprint.x + pad * 2;
	const int depth = footprint.y + pad * 2;
	const double inner_flat = 1.25 + std::min(1.5, support_range * 0.3);
	const double pad_double = double(pad);

	int scanned_pixels = 0;
	int changed_pixels = 0;
	int protected_skip_count = 0;
	changed_indices.resize((width + 1) * (depth + 1));
	changed_values.resize((width + 1) * (depth + 1));
	int write_index = 0;

	for (int fz = -pad; fz < depth - pad + 1; ++fz) {
		const int fpz = std::clamp(map_base_z + fz, 0, map_size - 1);
		const int row_offset = fpz * map_size;
		const int world_z = base_world_z + fz;
		const bool inside_z = fz >= 0 && fz < footprint.y;
		const double fz_double = double(fz);
		const double dz = std::max(0.0, std::max(0.0 - fz_double, fz_double - double(footprint.y)));
		for (int fx = -pad; fx < width - pad + 1; ++fx) {
			const bool inside_surface = inside_z && fx >= 0 && fx < footprint.x;
			if (!inside_surface && !protected_set.empty()) {
				const Vector2i world_col(base_world_x + fx, world_z);
				if (protected_set.find(world_col) != protected_set.end()) {
					protected_skip_count += 1;
					continue;
				}
			}

			const int fpx = std::clamp(map_base_x + fx, 0, map_size - 1);
			const int height_index = row_offset + fpx;
			const uint8_t original_height_byte = height_read[height_index];
			const double fx_double = double(fx);
			const double dx = std::max(0.0, std::max(0.0 - fx_double, fx_double - double(footprint.x)));
			const double dist = std::sqrt(dx * dx + dz * dz);
			scanned_pixels += 1;
			bool should_write = false;
			uint8_t target_height_byte = original_height_byte;
			if (dist <= inner_flat) {
				target_height_byte = flat_height_byte;
				should_write = true;
			} else if (dist < pad_double) {
				const double blend_t = (dist - inner_flat) / std::max(0.001, pad_double - inner_flat);
				const double smooth_t = smoothstep01(blend_t);
				const int blended = static_cast<int>(lerp_double(double(flat_height_byte), double(original_height_byte), smooth_t));
				target_height_byte = static_cast<uint8_t>(std::clamp(blended, 0, 255));
				should_write = true;
			}
			if (should_write && target_height_byte != original_height_byte) {
				if (write_index >= changed_indices.size()) {
					changed_indices.resize(write_index + 128);
					changed_values.resize(write_index + 128);
				}
				changed_indices.set(write_index, height_index);
				changed_values.set(write_index, target_height_byte);
				write_index += 1;
					changed_pixels += 1;
			}
		}
	}
	changed_indices.resize(write_index);
	changed_values.resize(write_index);

	result["height_indices"] = changed_indices;
	result["height_values"] = changed_values;
	result["backend"] = "native";
	result["pad"] = pad;
	result["scanned_pixel_count"] = scanned_pixels;
	result["changed_pixel_count"] = changed_pixels;
	result["protected_skip_count"] = protected_skip_count;
	return result;
}

Array PrefabGeometryNative::build_world_map_excavation_modifications(const Array &segments, const Vector3 &spawn_origin) const {
	Array result;
	result.resize(segments.size());
	int write_index = 0;
	const int base_x = static_cast<int>(std::floor(double(spawn_origin.x)));
	const int base_z = static_cast<int>(std::floor(double(spawn_origin.z)));
	for (int i = 0; i < segments.size(); ++i) {
		if (segments[i].get_type() != Variant::DICTIONARY) {
			continue;
		}
		const Dictionary segment = segments[i];
		const double world_y_min = double(spawn_origin.y) + double(segment.get("min_y", 0));
		const double world_y_max = double(spawn_origin.y) + double(segment.get("max_y", -1)) + 1.0;
		if (world_y_max <= world_y_min) {
			continue;
		}
		const int world_x = base_x + int(segment.get("x", 0));
		const int world_z = base_z + int(segment.get("z", 0));

		Array brush_pos;
		brush_pos.resize(3);
		brush_pos[0] = double(world_x) + 0.5;
		brush_pos[1] = (world_y_min + world_y_max) * 0.5;
		brush_pos[2] = double(world_z) + 0.5;

		Dictionary modification;
		modification["brush_pos"] = brush_pos;
		modification["radius"] = 0.6;
		modification["value"] = 10.0;
		modification["shape"] = 2;
		modification["layer"] = 0;
		modification["y_min"] = world_y_min;
		modification["y_max"] = world_y_max;
		modification["material_id"] = -1;
		result[write_index++] = modification;
	}
	result.resize(write_index);
	return result;
}

Array PrefabGeometryNative::build_vegetation_instances(const Dictionary &config, const PackedFloat32Array &height_map) const {
	const Dictionary result = build_vegetation_instances_result(config, height_map, false, Transform3D(), AABB());
	return result.get("instances", Array());
}

Dictionary PrefabGeometryNative::build_vegetation_instances_with_render_payload(
		const Dictionary &config,
		const PackedFloat32Array &height_map,
		const Transform3D &render_space_inverse,
		const AABB &mesh_bounds) const {
	return build_vegetation_instances_result(config, height_map, true, render_space_inverse, mesh_bounds);
}

PackedFloat32Array PrefabGeometryNative::build_noise_samples(const Callable &noise_sampler, int chunk_origin_x, int chunk_origin_z, int chunk_stride, int step, bool use_noise) const {
	PackedFloat32Array samples;
	if (!use_noise || !noise_sampler.is_valid() || chunk_stride <= 0 || step <= 0) {
		return samples;
	}

	const int samples_per_axis = (chunk_stride + step - 1) / step;
	const int sample_count = samples_per_axis * samples_per_axis;
	samples.resize(sample_count);

	float *write_ptr = samples.ptrw();
	int write_index = 0;
	for (int x = 0; x < chunk_stride; x += step) {
		for (int z = 0; z < chunk_stride; z += step) {
			const Variant value = noise_sampler.call(float(chunk_origin_x + x), float(chunk_origin_z + z));
			write_ptr[write_index++] = float(value);
		}
	}
	return samples;
}

Array PrefabGeometryNative::filter_removed_vegetation_entries(const Array &entries, const Dictionary &removed_lookup) const {
	if (entries.is_empty() || removed_lookup.is_empty()) {
		return entries.duplicate(false);
	}

	Array filtered;
	filtered.resize(entries.size());
	int write_index = 0;
	for (int i = 0; i < entries.size(); ++i) {
		const Variant item = entries[i];
		if (item.get_type() == Variant::DICTIONARY) {
			Dictionary entry = item;
			const Vector3 fallback_world_pos = dictionary_get_vector3(entry, "world_pos");
			const Vector3 hash_pos = dictionary_get_vector3(entry, "hit_pos", fallback_world_pos);
			if (removed_lookup.has(vegetation_position_hash(hash_pos))) {
				continue;
			}
		}
		filtered[write_index++] = item;
	}

	filtered.resize(write_index);
	for (int i = 0; i < filtered.size(); ++i) {
		Variant item = filtered[i];
		if (item.get_type() != Variant::DICTIONARY) {
			continue;
		}
		Dictionary entry = item;
		entry["index"] = i;
		filtered[i] = entry;
	}
	return filtered;
}

Dictionary PrefabGeometryNative::build_global_vegetation_render_payload(const Array &instances, const Transform3D &render_space_inverse, const AABB &mesh_bounds) const {
	Dictionary result;
	result["buffer"] = PackedFloat32Array();
	result["instance_count"] = 0;
	result["bounds"] = AABB();
	result["has_bounds"] = false;

	if (instances.is_empty()) {
		return result;
	}

	PackedFloat32Array buffer;
	buffer.resize(instances.size() * 12);
	float *write_ptr = buffer.ptrw();
	int instance_count = 0;
	AABB bounds;
	bool has_bounds = false;

	for (int i = 0; i < instances.size(); ++i) {
		const Variant item = instances[i];
		Transform3D transform;
		if (!extract_transform_from_variant(item, transform)) {
			transform = Transform3D();
		}

		if (item.get_type() == Variant::DICTIONARY) {
			Dictionary dict = item;
			if (!bool(dict.get("alive", true))) {
				continue;
			}

			Variant world_pos_variant = dict.get("world_pos", transform.origin);
			Vector3 world_pos = transform.origin;
			if (world_pos_variant.get_type() == Variant::VECTOR3) {
				world_pos = world_pos_variant;
			}
			transform.origin = render_space_inverse.xform(world_pos);
		}

		const AABB instance_bounds = transform.xform(mesh_bounds);
		if (has_bounds) {
			bounds.merge_with(instance_bounds);
		} else {
			bounds = instance_bounds;
			has_bounds = true;
		}
		pack_transform_to_buffer(transform, write_ptr + instance_count * 12);
		instance_count += 1;
	}

	if (instance_count <= 0) {
		return result;
	}

	buffer.resize(instance_count * 12);

	result["buffer"] = buffer;
	result["instance_count"] = instance_count;
	result["bounds"] = bounds;
	result["has_bounds"] = has_bounds;
	return result;
}

Dictionary PrefabGeometryNative::build_global_vegetation_cluster_render_payload(const Dictionary &payloads, const Array &coord_keys, double bounds_padding) const {
	Dictionary result;
	result["buffer"] = PackedFloat32Array();
	result["bounds"] = AABB();
	result["has_bounds"] = false;
	result["chunk_count"] = 0;
	result["instance_count"] = 0;

	if (payloads.is_empty() || coord_keys.is_empty()) {
		return result;
	}

	std::vector<VegetationClusterPayloadChunk> chunks;
	chunks.reserve(coord_keys.size());

	int total_float_count = 0;
	int total_instance_count = 0;
	int chunk_count = 0;
	AABB bounds;
	bool has_bounds = false;

	for (int i = 0; i < coord_keys.size(); ++i) {
		const Variant coord_key = coord_keys[i];
		const Variant chunk_payload_variant = payloads.get(coord_key, Variant());
		if (chunk_payload_variant.get_type() != Variant::DICTIONARY) {
			continue;
		}

		Dictionary chunk_payload = chunk_payload_variant;
		const int instance_count = int(chunk_payload.get("instance_count", 0));
		if (instance_count <= 0) {
			continue;
		}

		const Variant chunk_buffer_variant = chunk_payload.get("buffer", PackedFloat32Array());
		if (chunk_buffer_variant.get_type() != Variant::PACKED_FLOAT32_ARRAY) {
			continue;
		}

		PackedFloat32Array chunk_buffer = chunk_buffer_variant;
		const int required_float_count = instance_count * 12;
		if (chunk_buffer.size() < required_float_count) {
			continue;
		}

		VegetationClusterPayloadChunk chunk;
		chunk.buffer = chunk_buffer;
		chunk.float_count = required_float_count;
		chunks.push_back(chunk);

		total_float_count += required_float_count;
		total_instance_count += instance_count;
		chunk_count += 1;

		if (bool(chunk_payload.get("has_bounds", false))) {
			const Variant bounds_variant = chunk_payload.get("bounds", AABB());
			if (bounds_variant.get_type() == Variant::AABB) {
				const AABB chunk_bounds = bounds_variant;
				if (has_bounds) {
					bounds.merge_with(chunk_bounds);
				} else {
					bounds = chunk_bounds;
					has_bounds = true;
				}
			}
		}
	}

	if (total_float_count <= 0 || total_instance_count <= 0) {
		return result;
	}

	PackedFloat32Array buffer;
	buffer.resize(total_float_count);
	float *write_ptr = buffer.ptrw();
	int write_offset = 0;
	for (const VegetationClusterPayloadChunk &chunk : chunks) {
		const float *read_ptr = chunk.buffer.ptr();
		std::memcpy(write_ptr + write_offset, read_ptr, sizeof(float) * chunk.float_count);
		write_offset += chunk.float_count;
	}

	if (has_bounds && bounds_padding > 0.0) {
		const Vector3 padding(bounds_padding, bounds_padding, bounds_padding);
		bounds.position -= padding;
		bounds.size += padding * 2.0;
	}

	result["buffer"] = buffer;
	result["bounds"] = bounds;
	result["has_bounds"] = has_bounds;
	result["chunk_count"] = chunk_count;
	result["instance_count"] = total_instance_count;
	return result;
}

PackedFloat32Array PrefabGeometryNative::pack_multimesh_buffer_from_instances(const Array &instances) const {
	PackedFloat32Array buffer;
	if (instances.is_empty()) {
		return buffer;
	}

	buffer.resize(instances.size() * 12);
	float *write_ptr = buffer.ptrw();
	int write_offset = 0;

	for (int i = 0; i < instances.size(); ++i) {
		Transform3D transform;
		if (!extract_transform_from_variant(instances[i], transform)) {
			transform = Transform3D();
		}

		pack_transform_to_buffer(transform, write_ptr + write_offset);
		write_offset += 12;
	}

	return buffer;
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
