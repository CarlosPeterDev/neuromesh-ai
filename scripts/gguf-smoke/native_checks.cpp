#include "gguf_logits.h"
#include "utf8_token_stream.h"

#include <cassert>
#include <limits>

int main() {
    constexpr float inf = std::numeric_limits<float>::infinity();
    const float valid[] = {-inf, -3.0f, 1.0f, 0.0f};
    const float flat[] = {0.0f, 0.0f, 0.0f};
    const float masked[] = {-inf, -inf};
    const float invalid[] = {0.0f, std::numeric_limits<float>::quiet_NaN(), 1.0f};
    const float overflow[] = {0.0f, 1.0f, inf};
    assert(ggufLogitsStatus(valid, 4) == GgufLogitsStatus::usable);
    assert(ggufLogitsStatus(flat, 3) == GgufLogitsStatus::flat);
    assert(ggufLogitsStatus(masked, 2) == GgufLogitsStatus::flat);
    assert(ggufLogitsStatus(invalid, 3) == GgufLogitsStatus::non_finite);
    assert(ggufLogitsStatus(overflow, 3) == GgufLogitsStatus::non_finite);
    assert(ggufLogitsStatus(nullptr, 1) == GgufLogitsStatus::missing);

    const uint16_t units[] = {'A', 0, 0xd83d, 0xdc4b, 0x00e9};
    assert(utf16ToUtf8(units, 5) == std::string("A\0\xf0\x9f\x91\x8b\xc3\xa9", 8));
    const uint16_t invalid_units[] = {0xd83d, 'x', 0xdc4b};
    assert(utf16ToUtf8(invalid_units, 3) == "\xef\xbf\xbdx\xef\xbf\xbd");

    Utf8TokenStream stream;
    assert(stream.append("\xf0\x9f", 2).empty());
    assert((stream.append("\x91\x8b", 2) == std::vector<uint16_t>{0xd83d, 0xdc4b}));
    assert((stream.append("A\0", 2) == std::vector<uint16_t>{'A', 0}));
    assert(stream.append("\xe2\x82", 2).empty());
    assert(stream.finish() == std::vector<uint16_t>{0xfffd});
    assert(stream.finish().empty());
}
