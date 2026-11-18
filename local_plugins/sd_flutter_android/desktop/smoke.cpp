#include <cstddef>
#include <cstdint>

extern "C" {
int sd_ffi_get_cores();
void sd_ffi_set_extra_paths(const char*, const char*, const char*, const char*);
uint8_t* sd_ffi_generate(void*, const char*, const char*, int, int, int, int64_t,
                        float, int, int, bool, size_t*);
void sd_ffi_release_image(uint8_t*);
}

int main() {
    if (sd_ffi_get_cores() < 1) return 1;
    sd_ffi_set_extra_paths(nullptr, nullptr, nullptr, nullptr);
    size_t bytes = 0;
    if (sd_ffi_generate(nullptr, "", "", 64, 64, 1, 1, 1.0f, 0, 0, false, &bytes)) {
        return 2;
    }
    sd_ffi_release_image(nullptr);
    return bytes == 0 ? 0 : 3;
}
