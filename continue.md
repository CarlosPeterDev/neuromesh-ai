# NeuroMesh AI handoff — 2026-11-21

Current work: `repair/model-directed-agent`, based on `bc0acc8`.

Read [the repair report](docs/REBUILD_REPORT.md) and [the architecture audit](docs/ARCHITECTURE_REPAIR.md). This is an implemented repair branch, not a verified production release. OpenCode is abandoned and removed; do not restore its hub, adapters or model bridge. Local diffusion was removed after its downloader was disabled. Online Pollinations remains under the tool registry and Models → Images.

Implemented: model-first local/cloud agent loop; native Android GGUF/OpenAI-compatible/Google/Anthropic tools; validated structured adapter; dynamic schemas/availability/policies; plans and dependencies; bounded multi-step execution; verified workspace/SAF writes and binary export; text-file-to-WAV plus offline Android system-engine fallback; separate composer microphone/voice/send and persisted Think; embedded GGUF templates/enable_thinking; cleaned navigation/settings. Relay foreground-service setup was extracted from the removed image notification service.

Evidence: full Flutter suite 229 passed / 4 optional skips; analyzer zero errors/warnings with informational lints; 3 Python checks passed; native common host build passed; same real Qwen3 GGUF thinking on/off passed; ARM64 NDK syntax check passed with deprecation warnings; live anonymous Pollinations returned decoded 768×768 images; a three-image native-model probe saved Moon while Saturn/Orion hit provider 429/503 errors. Raw results are in docs/verification. Android device integration tests have not run. Local APK compilation was blocked by Gradle exhausting the 8 GB workspace after SDK provisioning. No release was published. Draft PR #62 is open; inspect the latest preview-only Actions results.

Follow-up: Android native schemas, actual common/chat tool parser, canonical tool-result roles and IDs, native Google/Anthropic transports (including Google thought signatures), final-answer wrappers and internal tool-history markers are implemented. Unsupported schemas disable discovery/execution. Approval cancellation races are guarded. Context fitting preserves tool JSON/call pairs and reports failures with completed output links. Offline system voices must explicitly report installed/offline capability. Real Qwen native calculator + direct-answer checks passed. ARM64 common library builds with global hidden visibility and exports the six checked JNI-needed symbols.

Remaining critical work: full APK/AAB preview for the final commit and actual SAF/TTS/voice/JNI thinking/native tools/composer behavior and physical cluster checks. General live multi-tool compound planning remains unverified. Cloud native transport tests are mocked. Keep draft until verified. Avoid claiming mocks establish live functionality. The prior full preview `44919250711` passed native-host/Linux/Windows but failed Android linker visibility; this follow-up fixes that library visibility and shared C++ runtime linkage.

Release workflow retains separate APK/AAB assets, signing and package checks, digest verification and Latest publication. A real-GGUF host thinking gate is added. Publishing must not proceed after failed critical checks.

Checks:

```sh
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
python -m unittest discover -s scripts -p test_report_build_config.py
scripts/check_model_thinking.sh /path/to/compatible.gguf
```

Run Android integration tests using the pre-granted folder/model instructions in the report. The existing supported distributed text/voice functionality is retained; native device performance remains unverified. Earlier release history and the previous handoff remain in Git history.
