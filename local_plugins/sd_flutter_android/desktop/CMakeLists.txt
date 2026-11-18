cmake_minimum_required(VERSION 3.22)
project(NeuroMeshImageRuntime LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(SD_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(SD_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SD_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
# Use the baseline x64 instruction set on systems without AVX2.
foreach(feature SSE42 AVX AVX2 BMI2 FMA F16C)
  set(GGML_${feature} OFF CACHE BOOL "" FORCE)
endforeach()

set(image_sources "${CMAKE_CURRENT_SOURCE_DIR}/../android/src/main/cpp")
add_subdirectory("${image_sources}/stable-diffusion.cpp" stable-diffusion)
add_library(neuromesh_sd SHARED "${image_sources}/sd_jni_wrapper.cpp")
target_include_directories(neuromesh_sd PRIVATE
  "${image_sources}/stable-diffusion.cpp/include"
)
target_link_libraries(neuromesh_sd PRIVATE stable-diffusion)
install(TARGETS neuromesh_sd RUNTIME DESTINATION native LIBRARY DESTINATION native)

enable_testing()
add_executable(neuromesh_sd_smoke smoke.cpp)
target_link_libraries(neuromesh_sd_smoke PRIVATE neuromesh_sd)
add_test(NAME desktop-image-runtime COMMAND neuromesh_sd_smoke)
