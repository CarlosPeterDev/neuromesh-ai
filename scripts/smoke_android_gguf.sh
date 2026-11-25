#!/usr/bin/env bash
set -euo pipefail

apk=$1
model=$2
projector=$3
scratch=$(mktemp -d)
device_dir=/data/local/tmp/neuromesh-gguf-smoke
trap 'adb shell rm -rf "$device_dir" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT

d8=$(find "$ANDROID_HOME/build-tools" -name d8 | sort -V | tail -1)
mkdir -p "$scratch/classes" "$scratch/dex"
javac --release 8 -encoding UTF-8 -d "$scratch/classes" scripts/gguf-smoke/LlamaFlutterAndroidPlugin.java
dart scripts/gguf-smoke/tool_intent_prompt.dart > "$scratch/visual-intent.txt"
dart scripts/gguf-smoke/tool_intent_prompt.dart follow-up > "$scratch/visual-follow-up.txt"
dart scripts/gguf-smoke/tool_intent_prompt.dart calculator > "$scratch/calculator-options.txt"
dart scripts/gguf-smoke/tool_intent_prompt.dart confirm-image > "$scratch/confirm-image.txt"
dart scripts/gguf-smoke/compact_tool_cases.dart > "$scratch/compact-tools.tsv"
mapfile -d '' classes < <(find "$scratch/classes" -name '*.class' -print0)
"$d8" --min-api 28 --output "$scratch/dex" "${classes[@]}"

# Run the exact JNI libraries shipped in the APK in an isolated Android VM
# process. A clean process keeps the fixture independent of user data and UI.
unzip -q "$apk" 'lib/x86_64/libllama*.so' 'lib/x86_64/libggml*.so' \
    'lib/x86_64/libmtmd.so' 'lib/x86_64/libc++_shared.so' -d "$scratch"
python - "$scratch/red.png" <<'PY'
import struct
import sys
import zlib
from pathlib import Path

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

size = 64
header = struct.pack('>2I5B', size, size, 8, 2, 0, 0, 0)
pixels = (b'\0' + bytes([255, 0, 0]) * size) * size
Path(sys.argv[1]).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header)
    + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))
PY

adb shell mkdir -p "$device_dir/lib"
adb push "$scratch/lib/x86_64/." "$device_dir/lib/"
adb push "$scratch/dex/classes.dex" "$device_dir/classes.dex"
adb push "$model" "$device_dir/model.gguf"
adb push "$projector" "$device_dir/mmproj.gguf"
adb push "$scratch/red.png" "$device_dir/red.png"
adb push "$scratch/visual-intent.txt" "$device_dir/visual-intent.txt"
adb push "$scratch/visual-follow-up.txt" "$device_dir/visual-follow-up.txt"
adb push "$scratch/calculator-options.txt" "$device_dir/calculator-options.txt"
adb push "$scratch/confirm-image.txt" "$device_dir/confirm-image.txt"
adb push "$scratch/compact-tools.tsv" "$device_dir/compact-tools.tsv"
timeout 480 adb shell "CLASSPATH=$device_dir/classes.dex LD_LIBRARY_PATH=$device_dir/lib \
    /system/bin/app_process64 / com.neuromesh.llama_flutter_android.LlamaFlutterAndroidPlugin \
    $device_dir/lib $device_dir/model.gguf $device_dir/mmproj.gguf $device_dir/red.png \
    $device_dir/visual-intent.txt $device_dir/visual-follow-up.txt \
    $device_dir/calculator-options.txt $device_dir/confirm-image.txt $device_dir/compact-tools.tsv" |
    tee "$scratch/result.txt"
grep -Fx 'GGUF_INFERENCE_SMOKE_OK' "$scratch/result.txt"
