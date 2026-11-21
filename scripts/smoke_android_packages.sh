#!/usr/bin/env bash
set -euo pipefail

test_app=com.neuromesh.ai.test
play_app=com.neuromesh.ai
activity=com.neuromesh.ai.MainActivity
bundletool="$RUNNER_TEMP/bundletool.jar"
apk_set="$RUNNER_TEMP/neuro-preview.apks"
aab=build/app/outputs/bundle/release/app-release.aab
test_keystore="$RUNNER_TEMP/neuromesh-test-signing.p12"

launch_app() {
    local app_id="$1"
    adb shell am force-stop "$app_id"
    adb shell am start -W -n "$app_id/$activity" | tr -d '\r' | grep -F 'Status: ok'
    sleep 4
    adb shell pidof "$app_id" | grep -E '[0-9]+'
}

report_installed_package() {
    local app_id="$1" apk bytes total=0
    while IFS= read -r apk; do
        bytes=$(adb shell stat -c %s "$apk" | tr -d '\r')
        [[ "$bytes" =~ ^[0-9]+$ ]]
        total=$((total + bytes))
    done < <(adb shell pm path "$app_id" | tr -d '\r' | sed -n 's/^package://p')
    test "$total" -gt 0
    printf '%s installed APK files: %s bytes (excludes app data and extracted libraries)\n' "$app_id" "$total" | tee -a "$GITHUB_STEP_SUMMARY"
}

# Install a minimal older APK with the same test identity, then upgrade it.
# This exercises Android's version and certificate checks without another native build.
fixture="$RUNNER_TEMP/previous-test-app"
mkdir -p "$fixture"
cat > "$fixture/AndroidManifest.xml" <<XML
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="$test_app" android:versionCode="$((ANDROID_BUILD_NUMBER - 1))">
    <uses-sdk android:minSdkVersion="28" android:targetSdkVersion="31" />
    <application android:hasCode="false" />
</manifest>
XML
build_tools=$(find "$ANDROID_HOME/build-tools" -name aapt | sort -V | tail -n 1)
platform=$(find "$ANDROID_HOME/platforms" -name android.jar | sort -V | tail -n 1)
"$build_tools" package -M "$fixture/AndroidManifest.xml" -I "$platform" -F "$fixture/unsigned.apk"
"${build_tools%/aapt}/apksigner" sign --ks "$test_keystore" --ks-key-alias neuromesh-test \
    --ks-pass pass:android --key-pass pass:android --out "$fixture/previous.apk" "$fixture/unsigned.apk"
adb install "$fixture/previous.apk"
adb install -r "$RUNNER_TEMP/universal.apk"
launch_app "$test_app"
report_installed_package "$test_app"

# Install the Play-style splits alongside the public test app. The Play
# bundle keeps its separate signing identity and application ID.
play_keystore="$RUNNER_TEMP/emulator-play-signing.p12"
keytool -genkeypair -noprompt -keystore "$play_keystore" -storetype PKCS12 \
    -storepass android -keypass android -alias emulator-play -keyalg RSA \
    -keysize 2048 -validity 7 -dname 'CN=NeuroMesh Emulator Play Split Test'
java -jar "$bundletool" build-apks --bundle="$aab" --output="$apk_set" \
    --connected-device --ks="$play_keystore" --ks-key-alias=emulator-play \
    --ks-pass=pass:android --key-pass=pass:android --overwrite
java -jar "$bundletool" install-apks --apks="$apk_set"
launch_app "$play_app"
report_installed_package "$play_app"
adb shell pm path "$test_app" | grep -F 'package:'
