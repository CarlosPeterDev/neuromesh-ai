#!/usr/bin/env bash
set -euo pipefail
# Real model inference and partial parsing; explicit error fixtures stand in for Android tool handlers. Requires CMake/Ninja/C++ and a compatible GGUF.
# The model is supplied separately and never included in release assets.
model=${1:?Pass a compatible model.gguf}
root=$(cd "$(dirname "$0")/.." && pwd)
build=${NEUROMESH_NATIVE_TEST_BUILD:-"$root/build/native-thinking"}
source="$root/local_plugins/llama_flutter_android/android/src/main/cpp/llama.cpp"
cmake -S "$source" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_OPENSSL=OFF -DGGML_NATIVE=OFF
cmake --build "$build" --target llama-common --parallel 2
c++ -std=c++17 -O2 "$root/tool/verify_agent_stream.cpp" \
  -I"$source/common" -I"$source/include" -I"$source/ggml/include" \
  -I"$source/vendor" -I"$source/vendor/nlohmann" -L"$build/bin" \
  -Wl,-rpath,"$build/bin" -Wl,-rpath-link,"$build/bin" \
  -lllama-common -lllama -lggml -lggml-base -o "$build/verify_agent_stream"
"$build/verify_agent_stream" "$model"
