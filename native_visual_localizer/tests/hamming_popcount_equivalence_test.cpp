#include <opencv2/core.hpp>
#if CV_VERSION_MAJOR >= 5
#include <opencv2/features.hpp>
#include <opencv2/xfeatures2d.hpp>
#else
#include <opencv2/features2d.hpp>
#endif
#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <cstring>
#include <deque>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#define private public
#include "visual_localizer_impl.h"
#undef private

// Characterization and equivalence contracts for the pure Hamming optimization.
// Both the original product implementation and the candidate must pass. The
// reference retains the original independent bytewise Kernighan calculation and
// unchanged BoW tie, IDF accumulation, and L2 normalization order. This test
// intentionally requires no experimental trace or fallback behavior.

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}

// Frozen independent reference: the original bytewise Kernighan implementation.
int referenceDistance(const unsigned char* a, const unsigned char* b, int len) {
    int distance = 0;
    for (int i = 0; i < len; ++i) {
        unsigned char bits = a[i] ^ b[i];
        while (bits != 0) {
            ++distance;
            bits &= static_cast<unsigned char>(bits - 1);
        }
    }
    return distance;
}

std::vector<float> referenceBoW(const std::vector<VocabWord>& vocabulary,
                                const cv::Mat& descriptors) {
    const int vocab_size = static_cast<int>(vocabulary.size());
    if (vocab_size == 0) return {};
    std::vector<float> bow(vocab_size, 0.0f);
    for (int row = 0; row < descriptors.rows; ++row) {
        const unsigned char* descriptor = descriptors.ptr<unsigned char>(row);
        int best_word = 0;
        int best_distance = INT_MAX;
        for (int word = 0; word < vocab_size; ++word) {
            const int length = std::min(32, static_cast<int>(vocabulary[word].descriptor.size()));
            const int distance = referenceDistance(
                descriptor, vocabulary[word].descriptor.data(), length);
            if (distance < best_distance) {
                best_distance = distance;
                best_word = word;
            }
        }
        bow[best_word] += vocabulary[best_word].idf_weight;
    }
    float norm = 0.0f;
    for (float value : bow) norm += value * value;
    norm = std::sqrt(norm);
    if (norm > 1e-9f) {
        for (float& value : bow) value /= norm;
    }
    return bow;
}

void requireExactBoW(const std::vector<float>& actual,
                     const std::vector<float>& expected, const char* message) {
    require(actual.size() == expected.size() &&
                (actual.empty() || std::memcmp(actual.data(), expected.data(),
                                              actual.size() * sizeof(float)) == 0),
            message);
}

void verifyBoW(VisualLocalizer& localizer, const cv::Mat& descriptors) {
    const auto expected = referenceBoW(localizer.vocabulary_, descriptors);
    const auto rng_before = cv::theRNG().state;
    const auto actual = localizer.computeBoW(descriptors);
    requireExactBoW(actual, expected, "BoW differs from the original accumulation and tie order");
    require(cv::theRNG().state == rng_before, "BoW changed the OpenCV RNG");
}

void exhaustiveBytesHaveTheSameDistance() {
    for (int first = 0; first < 256; ++first) {
        for (int second = 0; second < 256; ++second) {
            const auto a = static_cast<unsigned char>(first);
            const auto b = static_cast<unsigned char>(second);
            require(VisualLocalizer::hammingDistance(&a, &b, 1) == referenceDistance(&a, &b, 1),
                    "exhaustive byte distance differs");
        }
    }
}

void randomLengthsAndUnalignedPointersHaveTheSameDistance() {
    std::mt19937 random(20261008);
    std::array<unsigned char, 136> first{}, second{};
    for (int length = 0; length <= 128; ++length) {
        for (auto& value : first) value = static_cast<unsigned char>(random());
        for (auto& value : second) value = static_cast<unsigned char>(random());
        for (int first_offset = 0; first_offset < 8; ++first_offset) {
            for (int second_offset = 0; second_offset < 8; ++second_offset) {
                const auto* a = first.data() + first_offset;
                const auto* b = second.data() + second_offset;
                require(VisualLocalizer::hammingDistance(a, b, length) ==
                            referenceDistance(a, b, length),
                        "random length or unaligned-pointer distance differs");
                require(VisualLocalizer::hammingDistance(a, a, length) == 0,
                        "identical descriptor distance is nonzero");
            }
        }
    }
}

void fullBitDifferencesAndNonpositiveLengthsAreExact() {
    std::array<unsigned char, 136> zeros{}, ones{};
    ones.fill(255);
    for (int length = 0; length <= 128; ++length) {
        for (int offset = 0; offset < 8; ++offset) {
            require(VisualLocalizer::hammingDistance(zeros.data() + offset,
                                                    ones.data() + offset, length) == 8 * length,
                    "all-bit distance or tail byte count differs");
        }
    }
    for (int length : {0, -1, -8, -128, INT_MIN}) {
        require(VisualLocalizer::hammingDistance(nullptr, nullptr, length) == 0,
                "nonpositive length must not dereference null pointers");
    }
}

std::vector<VocabWord> tieVocabulary() {
    std::vector<VocabWord> words;
    words.push_back({90, std::vector<unsigned char>(9, 0), 0.2f});
    words.back().descriptor[0] = 1;
    words.push_back({7, std::vector<unsigned char>(9, 0), 0.7f});
    words.back().descriptor[0] = 2;
    words.push_back({30, std::vector<unsigned char>(17, 255), 1.1f});
    words.push_back({20, std::vector<unsigned char>(33, 0xA5), 0.3f});
    words.back().descriptor.back() = 0x5A;  // byte 32 is outside the original 32-byte comparison.
    return words;
}

void tiesAndPartialVocabularyLengthsPreserveBoWBytes() {
    VisualLocalizer localizer;
    localizer.vocabulary_ = tieVocabulary();
    cv::Mat storage(11, 40, CV_8UC1, cv::Scalar(0xCC));
    cv::Mat descriptors = storage.colRange(3, 35);
    require(!descriptors.isContinuous(), "tie fixture must have noncontiguous rows");
    for (int row = 0; row < descriptors.rows; ++row) {
        auto* descriptor = descriptors.ptr<unsigned char>(row);
        const unsigned char value = row % 3 == 0 ? 0 : row % 3 == 1 ? 255 : 0xA5;
        std::fill(descriptor, descriptor + 32, value);
    }
    verifyBoW(localizer, descriptors);
    const auto result = localizer.computeBoW(descriptors);
    require(result[0] > 0 && result[1] == 0 && result[2] > 0 && result[3] > 0,
            "equal-distance tie must favor vocabulary position before word ID");
    verifyBoW(localizer, cv::Mat());
    localizer.vocabulary_.clear();
    verifyBoW(localizer, descriptors);
    localizer.vocabulary_ = {{99, {}, 0.2f}, {1, {}, 0.8f}};
    verifyBoW(localizer, descriptors);
    const auto empty_words = localizer.computeBoW(descriptors);
    require(empty_words[0] == 1 && empty_words[1] == 0,
            "empty vocabulary descriptor must retain zero-length tie semantics");
}

void thousandWordRandomVocabularyPreservesBoWBytes() {
    VisualLocalizer localizer;
    std::mt19937 random(20261009);
    const std::array<int, 9> lengths{7, 9, 15, 17, 24, 31, 32, 33, 61};
    for (int word = 0; word < 1000; ++word) {
        VocabWord entry;
        entry.word_id = 10000 - word;
        entry.descriptor.resize(lengths[random() % lengths.size()]);
        for (auto& value : entry.descriptor) value = static_cast<unsigned char>(random());
        entry.idf_weight = static_cast<float>(1 + random() % 10000) / 3333.0f;
        localizer.vocabulary_.push_back(std::move(entry));
    }
    for (int offset = 0; offset < 8; ++offset) {
        cv::Mat storage(17, 40, CV_8UC1);
        for (int row = 0; row < storage.rows; ++row) {
            for (int column = 0; column < storage.cols; ++column) {
                storage.at<unsigned char>(row, column) = static_cast<unsigned char>(random());
            }
        }
        verifyBoW(localizer, storage.colRange(offset, offset + 32));
    }
}

}  // namespace

int main() {
    try {
        cv::setNumThreads(1);
        exhaustiveBytesHaveTheSameDistance();
        randomLengthsAndUnalignedPointersHaveTheSameDistance();
        fullBitDifferencesAndNonpositiveLengthsAreExact();
        tiesAndPartialVocabularyLengthsPreserveBoWBytes();
        thousandWordRandomVocabularyPreservesBoWBytes();
        std::cout << "PASS: exact Hamming and BoW equivalence contracts\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
