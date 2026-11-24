#pragma once

#include <cmath>
#include <cstddef>
#include <limits>

enum class GgufLogitsStatus { usable, missing, non_finite, flat };

// Check the backend's raw scores before any sampler mutates them. A masked
// score may be -infinity, but sampling needs a meaningful finite distribution.
inline GgufLogitsStatus ggufLogitsStatus(const float* logits, size_t count) {
    if (!logits || !count) return GgufLogitsStatus::missing;
    float minimum = std::numeric_limits<float>::infinity();
    float maximum = -minimum;
    for (size_t i = 0; i < count; ++i) {
        const float score = logits[i];
        if (score == -std::numeric_limits<float>::infinity()) continue;
        if (!std::isfinite(score)) return GgufLogitsStatus::non_finite;
        if (score < minimum) minimum = score;
        if (score > maximum) maximum = score;
    }
    return minimum < maximum ? GgufLogitsStatus::usable : GgufLogitsStatus::flat;
}

inline const char* ggufLogitsStatusName(GgufLogitsStatus status) {
    switch (status) {
        case GgufLogitsStatus::usable: return "usable";
        case GgufLogitsStatus::missing: return "missing";
        case GgufLogitsStatus::non_finite: return "non-finite";
        case GgufLogitsStatus::flat: return "flat";
    }
    return "unknown";
}
