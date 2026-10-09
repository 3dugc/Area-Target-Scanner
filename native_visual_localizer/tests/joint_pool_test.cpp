#include "../src/joint_pool.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) {
        std::cerr << "FAIL: " << message << '\n';
        std::exit(1);
    }
}

joint_pool::Observation observation(float x, float y, float object_x,
                                    int query, int keyframe = 0,
                                    int train = 0, float distance = 10.0f) {
    return {{x, y}, {object_x, 0.0f, 1.0f}, query, keyframe, train, distance};
}

bool sameObservation(const joint_pool::Observation& a,
                     const joint_pool::Observation& b) {
    return a.image == b.image && a.object == b.object &&
           a.query_index == b.query_index && a.keyframe_id == b.keyframe_id &&
           a.train_index == b.train_index && a.distance == b.distance;
}

bool samePool(const joint_pool::Pool& a, const joint_pool::Pool& b) {
    if (a.input_count != b.input_count || a.query_groups != b.query_groups ||
        a.conflict_groups != b.conflict_groups ||
        a.object_conflict_groups != b.object_conflict_groups ||
        a.points.size() != b.points.size()) {
        return false;
    }
    for (std::size_t i = 0; i < a.points.size(); ++i) {
        if (!sameObservation(a.points[i], b.points[i])) return false;
    }
    return true;
}

void emptyInputHasZeroCounts() {
    const auto pool = joint_pool::consolidate({});
    require(pool.points.empty() && pool.input_count == 0 &&
                pool.query_groups == 0 && pool.conflict_groups == 0 &&
                pool.object_conflict_groups == 0,
            "empty input has no observations or groups");
}

void repeatedQueriesDoNotAddVotes() {
    const std::vector<joint_pool::Observation> input{
        observation(10, 10, 0.00f, 7, 4, 6, 20),
        observation(10, 10, 0.01f, 7, 2, 8, 10),
        observation(11, 10, 0.02f, 8, 1, 9, 10),
        observation(12, 10, 0.03f, 9, 1, 3, 10)};
    const auto pool = joint_pool::consolidate(input);
    require(pool.input_count == 4 && pool.query_groups == 1 &&
                pool.points.size() == 1 && pool.conflict_groups == 0 &&
                pool.object_conflict_groups == 0,
            "repeated query pixels contribute one vote");
    require(sameObservation(pool.points.front(), input.back()),
            "representative uses distance then keyframe then train index");
}

void equalDistanceUsesIndicesBeforeSignedZero() {
    const std::vector<joint_pool::Observation> input{
        observation(10, 10, 0, 7, 5, 0, -0.0f),
        observation(10, 10, 0, 3, 2, 0, 0.0f)};
    const auto pool = joint_pool::consolidate(input);
    require(pool.points.size() == 1 && sameObservation(pool.points.front(), input.back()),
            "equal numeric distance respects keyframe and query index before signed-zero ties");
    const auto query_tie = joint_pool::consolidate({
        observation(10, 10, 0, 7, 2, 0, 4),
        observation(10, 10, 0, 3, 2, 0, 4)});
    require(query_tie.points.size() == 1 && query_tie.points.front().query_index == 3,
            "query index determines representative after distance, keyframe and train ties");
}

void sameQueryIndexAlwaysSharesAGroup() {
    const auto pool = joint_pool::consolidate({
        observation(10, 10, 0.00f, 7), observation(80, 80, 0.02f, 7, 1)});
    require(pool.query_groups == 1 && pool.points.size() == 1,
            "same valid query index joins observations even with distant pixels");
}

void queryRadiusUsesConnectedComponents() {
    const auto pool = joint_pool::consolidate({
        observation(10, 10, 0.00f, 0, 0, 0, 2),
        observation(13, 10, 0.04f, 1, 1, 0, 1),
        observation(16, 10, 0.08f, 2, 2, 0, 3)});
    require(pool.query_groups == 1 && pool.points.size() == 1,
            "three-pixel chain forms a single component");

    const auto separate = joint_pool::consolidate({
        observation(10, 10, 0, 0), observation(13.01f, 10, 1, 1)});
    require(separate.query_groups == 2 && separate.points.size() == 2,
            "query distance above three pixels does not join components");
}

void conflictingEndpointsRejectTheWholeChain() {
    const auto pool = joint_pool::consolidate({
        observation(10, 10, 0.00f, 0, 0, 0, 2),
        observation(13, 10, 0.06f, 1, 1, 0, 1),
        observation(16, 10, 0.12f, 2, 2, 0, 3)});
    require(pool.points.empty() && pool.query_groups == 1 &&
                pool.conflict_groups == 1,
            "object spread checks all pairs, including nonrepresentative endpoints");
}

void objectSpreadThresholdIsInclusive() {
    const auto boundary = joint_pool::consolidate({
        observation(10, 10, 0, 0), observation(11, 10, 0.10f, 1)});
    require(boundary.points.size() == 1 && boundary.conflict_groups == 0,
            "exactly ten-centimeter object spread is accepted");
    const auto outside = joint_pool::consolidate({
        observation(10, 10, 0, 0), observation(11, 10, 0.1001f, 1)});
    require(outside.points.empty() && outside.conflict_groups == 1,
            "object spread above ten centimeters rejects the component");
}

void invalidInputsAreRejected() {
    const float nan = std::numeric_limits<float>::quiet_NaN();
    const float infinity = std::numeric_limits<float>::infinity();
    std::vector<joint_pool::Observation> invalid;
    auto item = observation(10, 10, 0, 0);
    item.image.x = nan;
    invalid.push_back(item);
    item = observation(10, 10, 0, 0);
    item.image.y = infinity;
    invalid.push_back(item);
    item = observation(10, 10, 0, 0);
    item.object.x = nan;
    invalid.push_back(item);
    item = observation(10, 10, 0, 0);
    item.object.y = infinity;
    invalid.push_back(item);
    item = observation(10, 10, 0, 0);
    item.object.z = nan;
    invalid.push_back(item);
    item = observation(10, 10, 0, 0);
    item.distance = nan;
    invalid.push_back(item);
    item = observation(10, 10, 0, 0);
    item.distance = infinity;
    invalid.push_back(item);
    item = observation(10, 10, 0, 0);
    item.distance = -1;
    invalid.push_back(item);
    item = observation(10, 10, 0, -1);
    invalid.push_back(item);
    item = observation(10, 10, 0, 0, -1);
    invalid.push_back(item);
    item = observation(10, 10, 0, 0, 0, -1);
    invalid.push_back(item);
    for (const auto& bad : invalid) {
        const auto pool = joint_pool::consolidate({bad});
        require(pool.input_count == 1 && pool.query_groups == 1 &&
                    pool.points.empty() && pool.conflict_groups == 1,
                "nonfinite fields and negative distance or indices reject a group");
    }
}

void invalidMemberRejectsAnOtherwiseValidGroup() {
    auto bad = observation(80, 80, 0, 7, 1);
    bad.object.x = std::numeric_limits<float>::quiet_NaN();
    const auto pool = joint_pool::consolidate({observation(10, 10, 0, 7), bad});
    require(pool.query_groups == 1 && pool.points.empty() &&
                pool.conflict_groups == 1,
            "a NaN member cannot be hidden by a valid representative");
    bad = observation(80, 80, 0, 7, 1);
    bad.image.x = std::numeric_limits<float>::quiet_NaN();
    const auto bad_image = joint_pool::consolidate({observation(10, 10, 0, 7), bad});
    require(bad_image.query_groups == 1 && bad_image.points.empty() &&
                bad_image.conflict_groups == 1,
            "nonfinite image still shares its valid query index and rejects that group");
}

void invalidQueryIndicesDoNotJoinUnrelatedInputs() {
    const auto pool = joint_pool::consolidate({
        observation(10, 10, 0, -1), observation(80, 80, 1, -1)});
    require(pool.query_groups == 2 && pool.conflict_groups == 2 &&
                pool.points.empty(),
            "unrelated invalid indices do not create a shared component");
}

void oneObjectAtDifferentQueryPixelsRejectsBothGroups() {
    const auto pool = joint_pool::consolidate({
        observation(10, 10, 0, 0), observation(80, 80, 0.01f, 1)});
    require(pool.query_groups == 2 && pool.points.empty() &&
                pool.conflict_groups == 0 && pool.object_conflict_groups == 2,
            "one-centimeter object coincidence at distinct query pixels rejects both groups");
    const auto outside = joint_pool::consolidate({
        observation(10, 10, 0, 0), observation(80, 80, 0.0101f, 1)});
    require(outside.points.size() == 2 && outside.object_conflict_groups == 0,
            "object separation above one centimeter is not an object conflict");
}

void objectConflictsInspectEveryComponentMember() {
    const auto pool = joint_pool::consolidate({
        observation(10, 10, 0.08f, 0, 0, 0, 1),
        observation(12, 10, 0.04f, 1, 1, 0, 2),
        observation(80, 80, 0.035f, 2, 2, 0, 1)});
    require(pool.query_groups == 2 && pool.points.empty() &&
                pool.object_conflict_groups == 2,
            "nonrepresentative member can establish a cross-component object conflict");
}

void shuffledInputGivesTheSameSortedPool() {
    std::vector<joint_pool::Observation> input{
        observation(12, 10, 0.01f, 0, 0, 0, 4),
        observation(10, 10, 0.00f, 0, 0, 0, 4),
        observation(80, 80, 2.00f, 1, 1, 2, 4),
        observation(20, 80, 3.00f, 2, 2, 0, 2),
        observation(80, 20, 3.005f, 3, 3, 0, 2),
        observation(140, 140, 4.00f, 4, 4, 0, 2)};
    input.back().distance = std::numeric_limits<float>::quiet_NaN();
    const auto expected = joint_pool::consolidate(input);
    require(expected.points.size() == 2 && expected.conflict_groups == 1 &&
                expected.object_conflict_groups == 2,
            "determinism fixture exercises retained and rejected groups");
    std::mt19937 random(20261008);
    for (int repetition = 0; repetition < 200; ++repetition) {
        std::shuffle(input.begin(), input.end(), random);
        require(samePool(joint_pool::consolidate(input), expected),
                "input permutations preserve representatives, order, and counters");
    }
}

std::vector<cv::Point2f> distributedPoints() {
    return {{10, 10}, {30, 10}, {50, 10}, {80, 10},
            {10, 30}, {30, 30}, {50, 30}, {80, 30}};
}

void distributedPointsPass() {
    require(joint_pool::spatiallyDistributed(distributedPoints(), 100, 100),
            "eight points with four cells and enough hull area pass");
}

void concentratedPointsFail() {
    require(!joint_pool::spatiallyDistributed(
                {{10, 10}, {11, 10}, {12, 10}, {10, 11},
                 {11, 11}, {12, 11}, {10, 12}, {12, 12}}, 100, 100),
            "eight concentrated points fail spatial distribution");
}

void cellAndAreaRequirementsAreIndependent() {
    require(!joint_pool::spatiallyDistributed(
                {{10, 10}, {11, 10}, {10, 11}, {80, 10},
                 {81, 10}, {80, 11}, {10, 80}, {11, 80}}, 100, 100),
            "large hull in only three grid cells fails");
    require(!joint_pool::spatiallyDistributed(
                {{10, 50}, {20, 50}, {30, 50}, {40, 50},
                 {50, 50}, {60, 50}, {70, 50}, {80, 50}}, 100, 100),
            "four grid cells with zero hull area fail");
    const std::vector<cv::Point2f> boundary{
        {20, 20}, {25, 20}, {30, 20}, {30, 25},
        {30, 30}, {25, 30}, {20, 30}, {20, 25}};
    require(joint_pool::spatiallyDistributed(boundary, 100, 100),
            "hull area exactly one percent is accepted");
    auto below = boundary;
    for (auto& point : below) if (point.x == 30) point.x = 29.99f;
    require(!joint_pool::spatiallyDistributed(below, 100, 100),
            "hull area below one percent is rejected");
}

void distributionRejectsInvalidImageInputs() {
    auto points = distributedPoints();
    points.pop_back();
    require(!joint_pool::spatiallyDistributed(points, 100, 100),
            "fewer than eight points fail");
    require(!joint_pool::spatiallyDistributed(distributedPoints(), 0, 100) &&
                !joint_pool::spatiallyDistributed(distributedPoints(), 100, 0) &&
                !joint_pool::spatiallyDistributed(distributedPoints(), -1, 100),
            "image dimensions must be positive");
    const std::vector<cv::Point2f> invalid{
        {-1, 10}, {10, -1}, {100, 10}, {10, 100},
        {std::numeric_limits<float>::quiet_NaN(), 10},
        {10, std::numeric_limits<float>::infinity()}};
    for (const auto& bad : invalid) {
        points = distributedPoints();
        points.back() = bad;
        require(!joint_pool::spatiallyDistributed(points, 100, 100),
                "every point must be finite and inside the original image");
    }
}

}  // namespace

int main() {
    emptyInputHasZeroCounts();
    repeatedQueriesDoNotAddVotes();
    equalDistanceUsesIndicesBeforeSignedZero();
    sameQueryIndexAlwaysSharesAGroup();
    queryRadiusUsesConnectedComponents();
    conflictingEndpointsRejectTheWholeChain();
    objectSpreadThresholdIsInclusive();
    invalidInputsAreRejected();
    invalidMemberRejectsAnOtherwiseValidGroup();
    invalidQueryIndicesDoNotJoinUnrelatedInputs();
    oneObjectAtDifferentQueryPixelsRejectsBothGroups();
    objectConflictsInspectEveryComponentMember();
    shuffledInputGivesTheSameSortedPool();
    distributedPointsPass();
    concentratedPointsFail();
    cellAndAreaRequirementsAreIndependent();
    distributionRejectsInvalidImageInputs();
    std::cout << "PASS: 17 joint pool contract tests\n";
    return 0;
}
