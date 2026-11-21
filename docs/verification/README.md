# Verification evidence — 2026-11-21

Application source: `1bd94d3` on `repair/model-directed-agent`.

| Check | Actual result |
| --- | --- |
| `flutter test` | 229 passed; 4 optional skips; exit 0 |
| `flutter analyze --no-fatal-infos` | Zero errors/warnings; 259 informational findings; exit 0 |
| Python build configuration tests | 3 passed |
| Real Qwen3-0.6B Q8_0 host inference | Same GGUF: thinking on/off prompts differ; correct 156 in both; enabled reasoning closes; disabled reasoning absent |
| Real native tool inference | Model selected calculator; validated arguments; real arithmetic 323; native tool roles/IDs round trip; grounded final answer; greeting without a call |
| ARM64 JNI syntax check | Exit 0; nine deprecation warnings |
| ARM64 common library | Built with global hidden visibility; six checked JNI-required symbols exported |
| Live anonymous Pollinations | Actual JPEG decoded at 768×768; [image](pollinations-live.jpg) |
| Android capability/device integration tests | Not executed; no local ARM device/emulator |
| Android 12 CI emulator packaging smoke | APK upgrade and Play split coexistence passed |
| APK/AAB preview | [Run 44937058470](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/44937058470): passed; AAB and both standalone APKs, signing/policy/size/checksums, Linux/Windows and real-GGUF gate |

The GGUF SHA-256 was `9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031`. The native test source is `tool/verify_model_thinking.cpp`; the CI script downloads and verifies the same model hash. Full host output remains in `/workspace/live-native-tools-final.log`. Flutter output is in `/workspace/tests-release-final.log` and `/workspace/analyze-release-final.log`. These local raw logs are ignored by the repository's `*.log` rule; this tracked record and CI provide reviewable evidence.

Mocked tests cover cloud native transports, compound agent planning, web services, Android method channels and synthesis samples. They use real temporary file writes and audio/image decoding where indicated. They do not prove Android document-provider or engine behavior. General live compound-task planning, actual Android JNI execution, keyed image editing, playback, real keyboard/rotation and physical distributed inference remain unverified. No production release was published.

Live multi-image probe: real Qwen selected three distinct astronomy prompts. Moon was saved, decoded at 768×768 and SHA-256 verified (`c8e142b30dc063941f8f0b612034103ede6f748d315481c131fe71ac78a1317d`). Saturn/Orion initially returned retry-bearing rate limits, then HTTP 503. Mock tests establish bounded Retry-After recovery/cancellation; the live probe does not establish three-image completion. Raw output: `/workspace/live-multi-images-retry-result.log`.

Final package version: `1.0.189`, development/test signed. Play arm64 download: 71,183,445 bytes. Artifacts: `android-arm64-apk` (14720858872), `android-universal-apk` (14720888837), `android-play-aab` (14721038360), `android-checksums` (14721137855). The CI script validated all three package checksums. No production release or Latest change occurred.

Downloaded archives matched GitHub artifact SHA-256 digests. Extracted ARM64 APK, universal APK and AAB each passed the included [package checksums](SHA256SUMS.txt). Both APKs contain the new native common library and shared C++ runtime. The extracted ARM64 libraries' dependencies resolve against packaged SONAMEs/Android API 28 system libraries; the packaged C++ runtime supplies all 185 checked `std::__ndk1` imports from `llama-common`. These are static package checks, not an ARM runtime inference test. Standalone extracted files are under `/workspace/artifacts/`.
