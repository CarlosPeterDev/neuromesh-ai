# Header-only cpp-httplib v0.28.0 (MIT). Needed by llama-common; no TLS
# dependency is enabled in the Android inference runtime.
add_library(cpp-httplib INTERFACE)
target_include_directories(cpp-httplib INTERFACE ${CMAKE_CURRENT_SOURCE_DIR})
