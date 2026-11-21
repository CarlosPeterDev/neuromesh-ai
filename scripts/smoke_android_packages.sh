#!/usr/bin/env bash
set -euo pipefail

app_id=com.neuromesh.ai
activity="$app_id/.MainActivity"
bundletool="$RUNNER_TEMP/bundletool.jar"
apk_set="$RUNNER_TEMP/neuro-preview.apks"
aab=build/app/outputs/bundle/release/app-release.aab

launch_app() {
    adb shell am force-stop "$app_id"
    adb shell am start -W -n "$activity" | tr -d '\r' | grep -F 'Status: ok'
    sleep 4
    adb shell pidof "$app_id" | grep -E '[0-9]+'
}

adb install "$RUNNER_TEMP/universal.apk"
launch_app
adb install -r "$RUNNER_TEMP/universal.apk"
adb uninstall "$app_id"

# Sign the emulator APKs with the temporary preview key. The AAB keeps
# its original upload signature.
java -jar "$bundletool" build-apks --bundle="$aab" --output="$apk_set" \
    --connected-device --ks=android/release.jks --ks-key-alias=androiddebugkey \
    --ks-pass=pass:android --key-pass=pass:android --overwrite
java -jar "$bundletool" install-apks --apks="$apk_set"
launch_app
