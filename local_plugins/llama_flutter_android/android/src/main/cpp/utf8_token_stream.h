#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// Java strings contain UTF-16 units, including surrogate pairs. Encode the
// prompt as standard UTF-8 and preserve embedded U+0000 for the tokenizer.
inline std::string utf16ToUtf8(const uint16_t* units, size_t length) {
    std::string result;
    result.reserve(length);
    for (size_t i = 0; i < length; ++i) {
        uint32_t scalar = units[i];
        if (scalar >= 0xd800 && scalar <= 0xdbff && i + 1 < length &&
            units[i + 1] >= 0xdc00 && units[i + 1] <= 0xdfff) {
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + (units[++i] - 0xdc00);
        } else if (scalar >= 0xd800 && scalar <= 0xdfff) {
            scalar = 0xfffd;
        }
        if (scalar < 0x80) {
            result.push_back(static_cast<char>(scalar));
        } else {
            const size_t width = scalar < 0x800 ? 2 : scalar < 0x10000 ? 3 : 4;
            const unsigned prefix[] = {0, 0, 0xc0, 0xe0, 0xf0};
            result.push_back(static_cast<char>(prefix[width] | (scalar >> (6 * (width - 1)))));
            for (size_t remain = width - 1; remain > 0; --remain) {
                result.push_back(static_cast<char>(0x80 | ((scalar >> (6 * (remain - 1))) & 0x3f)));
            }
        }
    }
    return result;
}

// llama.cpp token pieces can end in the middle of a UTF-8 character. JNI
// NewStringUTF expects modified UTF-8, so emit completed UTF-16 units instead.
class Utf8TokenStream {
public:
    std::vector<uint16_t> append(const char* bytes, size_t length) {
        pending_.append(bytes, length);
        std::vector<uint16_t> text;
        text.reserve(pending_.size());
        size_t offset = 0;
        while (offset < pending_.size()) {
            const auto lead = static_cast<uint8_t>(pending_[offset]);
            const size_t width = lead < 0x80 ? 1
                : lead >= 0xc2 && lead <= 0xdf ? 2
                : lead >= 0xe0 && lead <= 0xef ? 3
                : lead >= 0xf0 && lead <= 0xf4 ? 4 : 0;
            if (!width) {
                text.push_back(0xfffd);
                ++offset;
                continue;
            }

            uint32_t scalar = lead & (0xffu >> (width == 1 ? 1 : width + 1));
            size_t read = 1;
            for (; read < width && offset + read < pending_.size(); ++read) {
                const auto next = static_cast<uint8_t>(pending_[offset + read]);
                if ((next & 0xc0) != 0x80) break;
                scalar = (scalar << 6) | (next & 0x3f);
            }

            if (read < width) {
                if (offset + read == pending_.size()) break;
                text.push_back(0xfffd);
                offset += read;
                continue;
            }
            offset += width;
            const uint32_t minimum[] = {0, 0, 0x80, 0x800, 0x10000};
            if (scalar < minimum[width] || scalar > 0x10ffff ||
                (scalar >= 0xd800 && scalar <= 0xdfff)) {
                text.push_back(0xfffd);
            } else if (scalar <= 0xffff) {
                text.push_back(static_cast<uint16_t>(scalar));
            } else {
                scalar -= 0x10000;
                text.push_back(static_cast<uint16_t>(0xd800 | (scalar >> 10)));
                text.push_back(static_cast<uint16_t>(0xdc00 | (scalar & 0x3ff)));
            }
        }
        pending_.erase(0, offset);
        return text;
    }

    std::vector<uint16_t> finish() {
        if (pending_.empty()) return {};
        pending_.clear();
        return {0xfffd};
    }

private:
    std::string pending_;
};
