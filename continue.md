# NeuroMesh AI handoff — 2026-11-21

Current work: `repair/model-directed-agent`, based on `bc0acc8`.

Read [the repair report](docs/REBUILD_REPORT.md) and [the architecture audit](docs/ARCHITECTURE_REPAIR.md). This is an implemented repair branch, not a verified production release. OpenCode is abandoned and removed; do not restore its hub, adapters or model bridge. Local diffusion was removed after its downloader was disabled. Online Pollinations remains under the tool registry and Models → Images.

Implemented: model-first local/cloud agent loop; native OpenAI-compatible cloud tools; validated structured adapter; dynamic schemas/availability/policies; plans and dependencies; bounded multi-step execution; verified workspace/SAF writes and binary export; text-file-to-WAV plus offline Android system-engine fallback; separate composer microphone/voice/send and persisted Think; embedded GGUF templates/enable_thinking; cleaned navigation/settings. Relay foreground-service setup was extracted from the removed image notification service.

Evidence: full Flutter suite 217 passed / 4 optional skips; analyzer zero errors/warnings with pre-existing informational lints; 3 Python checks passed; native common host build passed; same real Qwen3 GGUF thinking on/off passed; ARM64 NDK syntax check passed with deprecation warnings; live anonymous Pollinations returned a decoded 768×768 image. Raw results are in docs/verification. Android device integration tests have not run. Local APK compilation was blocked by Gradle exhausting the 8 GB workspace after SDK provisioning. No release was published. Draft PR #62 and preview-only Actions run 44918909909 were opened; inspect their current results. Follow-up mocked grant/orchestration checks passed 10 tests.

Remaining critical work: native local tool transport (currently structured adapter, even when metadata advertises tools), native Google/Anthropic provider adapters, live local multi-tool planning, full Android APK/AAB compilation, actual SAF/TTS/voice/JNI thinking/composer behavior and physical cluster checks. Keep draft until verified. Avoid claiming mocked services establish live functionality.

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
