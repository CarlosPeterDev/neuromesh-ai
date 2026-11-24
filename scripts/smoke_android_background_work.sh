#!/usr/bin/env bash
set -euo pipefail

target=$1
scratch=$(mktemp -d)
fixture=com.neuromesh.ai.stopfixture
trap 'adb uninstall "$fixture" >/dev/null 2>&1 || true; rm -rf "$scratch"' EXIT

tools=$(dirname "$(find "$ANDROID_HOME/build-tools" -name aapt | sort -V | tail -1)")
platform=$(find "$ANDROID_HOME/platforms" -name android.jar | sort -V | tail -1)
mkdir -p "$scratch/classes" "$scratch/dex"
javac --release 8 -classpath "$platform" -d "$scratch/classes" scripts/gguf-smoke/BackgroundWorkSmoke.java
"$tools/d8" --lib "$platform" --min-api 28 --output "$scratch/dex" \
  "$scratch/classes/com/neuromesh/ai/stopfixture/BackgroundWorkSmoke.class"

cat > "$scratch/AndroidManifest.xml" <<XML
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$fixture">
  <uses-sdk android:minSdkVersion="28" android:targetSdkVersion="31" />
  <application />
  <instrumentation android:name=".BackgroundWorkSmoke" android:targetPackage="$target" />
</manifest>
XML
"$tools/aapt" package -M "$scratch/AndroidManifest.xml" -I "$platform" -F "$scratch/unsigned.apk"
(cd "$scratch/dex" && "$tools/aapt" add "$scratch/unsigned.apk" classes.dex)

signer=android/key.properties
export SMOKE_STORE_PASS=$(sed -n 's/^storePassword=//p' "$signer")
export SMOKE_KEY_PASS=$(sed -n 's/^keyPassword=//p' "$signer")
"$tools/apksigner" sign --ks "$(sed -n 's/^storeFile=//p' "$signer")" \
  --ks-key-alias "$(sed -n 's/^keyAlias=//p' "$signer")" \
  --ks-pass env:SMOKE_STORE_PASS --key-pass env:SMOKE_KEY_PASS \
  --out "$scratch/fixture.apk" "$scratch/unsigned.apk"
adb install "$scratch/fixture.apk"
timeout 60 adb shell am instrument -w "$fixture/.BackgroundWorkSmoke" | tr -d '\r' | tee "$scratch/result.txt"
grep -Fx 'BACKGROUND_WORK_NOTIFICATION_STOP_OK' "$scratch/result.txt"
