#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

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

private:
    std::string pending_;
};
