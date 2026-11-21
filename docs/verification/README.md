# Verification evidence — 2026-11-21

Application source commit: `3a2a559` (repair/model-directed-agent).

| Check | Actual result |
| --- | --- |
| `flutter test` | 227 passed; 4 optional skips; exit 0 |
| `flutter analyze --no-fatal-infos` | Zero errors/warnings; 257 informational findings; exit 0 |
| Python build configuration tests | 3 passed |
| Real Qwen3-0.6B Q8_0 host inference | Same GGUF: thinking on/off prompts differ; correct 156 in both; enabled reasoning closes; disabled reasoning absent |
| Real native tool inference | Model selected calculator; validated arguments; real arithmetic 323; native tool roles/IDs round trip; grounded final answer; greeting without a call |
| ARM64 JNI syntax check | Exit 0; nine deprecation warnings |
| ARM64 common library | Built with global hidden visibility; six checked JNI-required symbols exported |
| Live anonymous Pollinations | Actual JPEG decoded at 768×768; [image](pollinations-live.jpg) |
| Android integration/device tests | Not executed; no attached device/emulator |
| APK/AAB preview | [Run 44936408107](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/44936408107), pending |

The GGUF SHA-256 was `9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031`. The native test source is `tool/verify_model_thinking.cpp`; the CI script downloads and verifies the same model hash. Full host output remains in `/workspace/live-native-tools-final.log`. Flutter output is in `/workspace/tests-release-candidate.log` and `/workspace/analyze-release-candidate.log`. These local raw logs are ignored by the repository's `*.log` rule; this tracked record and CI provide reviewable evidence.

Mocked tests cover cloud native transports, compound agent planning, web services, Android method channels and synthesis samples. They use real temporary file writes and audio/image decoding where indicated. They do not prove Android document-provider or engine behavior. General live compound-task planning, actual Android JNI execution, keyed image editing, playback, real keyboard/rotation and physical distributed inference remain unverified. No production release was published.
