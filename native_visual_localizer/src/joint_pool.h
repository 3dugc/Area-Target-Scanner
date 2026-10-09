#ifndef AREA_TARGET_JOINT_POOL_H
#define AREA_TARGET_JOINT_POOL_H

#include <opencv2/core/types.hpp>
#include <opencv2/core/version.hpp>
#if CV_VERSION_MAJOR >= 5
#include <opencv2/geometry/2d.hpp>
#else
#include <opencv2/imgproc.hpp>
#endif

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <numeric>
#include <tuple>
#include <utility>
#include <vector>

namespace joint_pool {

inline constexpr float kQueryRadiusPixels = 3.0f;
inline constexpr float kMaximumObjectSpreadMeters = 0.10f;
inline constexpr float kObjectCoincidenceMeters = 0.01f;

struct Observation {
    cv::Point2f image;
    cv::Point3f object;
    int query_index;
    int keyframe_id;
    int train_index;
    float distance;
};

struct Pool {
    std::vector<Observation> points;
    int input_count = 0;
    int query_groups = 0;
    int conflict_groups = 0;
    int object_conflict_groups = 0;
};

namespace detail {

inline bool finiteImage(const cv::Point2f& point) {
    return std::isfinite(point.x) && std::isfinite(point.y);
}

inline bool validObservation(const Observation& observation) {
    return finiteImage(observation.image) &&
           std::isfinite(observation.object.x) &&
           std::isfinite(observation.object.y) &&
           std::isfinite(observation.object.z) &&
           std::isfinite(observation.distance) && observation.distance >= 0 &&
           observation.query_index >= 0 && observation.keyframe_id >= 0 &&
           observation.train_index >= 0;
}

inline double imageDistanceSquared(const cv::Point2f& a, const cv::Point2f& b) {
    const double x = static_cast<double>(a.x) - b.x;
    const double y = static_cast<double>(a.y) - b.y;
    return x * x + y * y;
}

inline double objectDistanceSquared(const cv::Point3f& a, const cv::Point3f& b) {
    const double x = static_cast<double>(a.x) - b.x;
    const double y = static_cast<double>(a.y) - b.y;
    const double z = static_cast<double>(a.z) - b.z;
    return x * x + y * y + z * z;
}

inline double squared(float threshold) {
    const double value = threshold;
    return value * value;
}

// Representatives are valid, so only signed zero needs a tie-break beyond <.
inline bool floatLess(float a, float b) {
    if (a < b) return true;
    if (b < a) return false;
    return std::signbit(a) && !std::signbit(b);
}

inline bool observationLess(const Observation& a, const Observation& b) {
    if (a.distance < b.distance) return true;
    if (b.distance < a.distance) return false;
    const auto indices_a = std::tie(a.keyframe_id, a.train_index, a.query_index);
    const auto indices_b = std::tie(b.keyframe_id, b.train_index, b.query_index);
    if (indices_a != indices_b) return indices_a < indices_b;
    const std::array<float, 5> coordinates_a{
        a.image.x, a.image.y, a.object.x, a.object.y, a.object.z};
    const std::array<float, 5> coordinates_b{
        b.image.x, b.image.y, b.object.x, b.object.y, b.object.z};
    for (std::size_t i = 0; i < coordinates_a.size(); ++i) {
        if (floatLess(coordinates_a[i], coordinates_b[i])) return true;
        if (floatLess(coordinates_b[i], coordinates_a[i])) return false;
    }
    return floatLess(a.distance, b.distance);
}

class Components {
public:
    explicit Components(std::size_t size) : parent_(size) {
        std::iota(parent_.begin(), parent_.end(), std::size_t{0});
    }

    std::size_t root(std::size_t index) {
        while (parent_[index] != index) {
            parent_[index] = parent_[parent_[index]];
            index = parent_[index];
        }
        return index;
    }

    void join(std::size_t a, std::size_t b) {
        a = root(a);
        b = root(b);
        if (a == b) return;
        if (a > b) std::swap(a, b);
        parent_[b] = a;
    }

private:
    std::vector<std::size_t> parent_;
};

}  // namespace detail

inline Pool consolidate(const std::vector<Observation>& input) {
    Pool pool;
    pool.input_count = static_cast<int>(input.size());
    detail::Components components(input.size());
    const double query_radius_squared = detail::squared(kQueryRadiusPixels);
    const double object_spread_squared = detail::squared(kMaximumObjectSpreadMeters);
    const double object_coincidence_squared = detail::squared(kObjectCoincidenceMeters);

    // Build the complete proximity graph before choosing any representative.
    // Invalid query indices do not establish an index-based equivalence.
    for (std::size_t a = 0; a < input.size(); ++a) {
        for (std::size_t b = a + 1; b < input.size(); ++b) {
            const bool same_query = input[a].query_index >= 0 &&
                                    input[a].query_index == input[b].query_index;
            const bool nearby = detail::finiteImage(input[a].image) &&
                                detail::finiteImage(input[b].image) &&
                                detail::imageDistanceSquared(input[a].image, input[b].image) <=
                                    query_radius_squared;
            if (same_query || nearby) components.join(a, b);
        }
    }

    std::vector<std::vector<std::size_t>> members_by_root(input.size());
    std::vector<bool> valid(input.size());
    for (std::size_t i = 0; i < input.size(); ++i) {
        members_by_root[components.root(i)].push_back(i);
        valid[i] = detail::validObservation(input[i]);
    }
    std::vector<std::vector<std::size_t>> groups;
    for (auto& members : members_by_root) {
        if (!members.empty()) groups.push_back(std::move(members));
    }
    pool.query_groups = static_cast<int>(groups.size());

    std::vector<bool> rejected(groups.size(), false);
    std::vector<bool> object_conflict(groups.size(), false);
    for (std::size_t group = 0; group < groups.size(); ++group) {
        const auto& members = groups[group];
        for (const auto index : members) {
            if (!valid[index]) rejected[group] = true;
        }
        for (std::size_t a = 0; a < members.size(); ++a) {
            for (std::size_t b = a + 1; b < members.size(); ++b) {
                if (valid[members[a]] && valid[members[b]] &&
                    detail::objectDistanceSquared(input[members[a]].object,
                                                  input[members[b]].object) >
                        object_spread_squared) {
                    rejected[group] = true;
                }
            }
        }
        if (rejected[group]) ++pool.conflict_groups;
    }

    // Check every valid member, including evidence in an already rejected group.
    // The two rejection counters describe causes and may overlap for a group.
    for (std::size_t a = 0; a < groups.size(); ++a) {
        for (std::size_t b = a + 1; b < groups.size(); ++b) {
            bool conflicting = false;
            for (const auto first : groups[a]) {
                if (!valid[first]) continue;
                for (const auto second : groups[b]) {
                    if (!valid[second]) continue;
                    if (detail::objectDistanceSquared(input[first].object, input[second].object) <=
                            object_coincidence_squared &&
                        detail::imageDistanceSquared(input[first].image, input[second].image) >
                            query_radius_squared) {
                        conflicting = true;
                        break;
                    }
                }
                if (conflicting) break;
            }
            if (conflicting) object_conflict[a] = object_conflict[b] = true;
        }
    }

    for (std::size_t group = 0; group < groups.size(); ++group) {
        if (object_conflict[group]) ++pool.object_conflict_groups;
        if (rejected[group] || object_conflict[group]) continue;
        const auto best = std::min_element(
            groups[group].begin(), groups[group].end(),
            [&](std::size_t a, std::size_t b) {
                return detail::observationLess(input[a], input[b]);
            });
        pool.points.push_back(input[*best]);
    }
    std::sort(pool.points.begin(), pool.points.end(), detail::observationLess);
    return pool;
}

inline bool spatiallyDistributed(const std::vector<cv::Point2f>& points,
                                int width, int height) {
    if (width <= 0 || height <= 0 || points.size() < 8) return false;
    std::array<bool, 16> occupied{};
    int cells = 0;
    for (const auto& point : points) {
        if (!detail::finiteImage(point) || point.x < 0 || point.y < 0 ||
            static_cast<double>(point.x) >= width ||
            static_cast<double>(point.y) >= height) {
            return false;
        }
        const int column = static_cast<int>(static_cast<double>(point.x) * 4 / width);
        const int row = static_cast<int>(static_cast<double>(point.y) * 4 / height);
        const auto cell = static_cast<std::size_t>(row * 4 + column);
        if (!occupied[cell]) {
            occupied[cell] = true;
            ++cells;
        }
    }
    if (cells < 4) return false;
    std::vector<cv::Point2f> hull;
    cv::convexHull(points, hull);
    return cv::contourArea(hull) >= 0.01 * static_cast<double>(width) * height;
}

}  // namespace joint_pool

#endif  // AREA_TARGET_JOINT_POOL_H
