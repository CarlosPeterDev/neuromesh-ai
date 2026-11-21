# NeuroMesh AI handoff — 2026-11-21

Branch: `repair/model-directed-agent`; final application source: `1bd94d3`, based on `bc0acc8`. Draft [PR #62](https://github.com/CarlosPeterDev/neuromesh-ai/pull/62).

Read [the repair report](docs/REBUILD_REPORT.md), [the architecture audit](docs/ARCHITECTURE_REPAIR.md) and [verification evidence](docs/verification/README.md). OpenCode and abandoned local diffusion are removed; do not restore their hub/adapters/settings. Online Pollinations remains under the registry and Models → Images key configuration.

Implemented: model-first local/cloud agent loop; native Android GGUF/OpenAI-compatible/Google/Anthropic tool transports; validated structured adapter for other local backends; dynamic schemas/availability/permissions; plans/dependencies, progress, limits and cancellation; verified workspace/SAF writes and binary export; text-file-to-WAV with installed offline system-voice fallback; separate composer mic/Voice/Send and persisted Think; embedded GGUF templates/enable_thinking. Relay foreground-service support was preserved separately. Internal history markers and final-answer wrappers prevent quoted tool syntax from executing. Unsupported schema assertions disable tools. Approval cancellation races are guarded; context failures preserve completed output links. Explicit short anonymous image retry limits receive bounded cancellable retries.

Evidence: **229 Flutter tests passed / 4 optional skips**; analyzer zero errors/warnings (259 informational findings); **3 Python checks passed**; real Qwen3 GGUF thinking on/off and native calculator/result round trip passed, including a direct greeting without a tool. ARM64 JNI syntax/common-library export checks passed. Live Pollinations decoded 768×768 images; a native-model three-image probe saved Moon while Saturn/Orion returned 429/503. No three-image live completion is claimed.

[Final preview 44937058470](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/44937058470) **passed** for source `1bd94d3`: Android AAB, ARM64/universal APKs, signatures/policy/size/checksum checks, Android 12 emulator upgrade/Play-split coexistence smoke tests, Linux/Windows packages and real-GGUF host inference. Version `1.0.189`; Play arm64 download 71,183,445 bytes. The earlier linker failure was fixed by exporting common/chat symbols from `llama-common` and linking shared libc++. Local Gradle exhausted the 8 GB workspace; CI supplied the successful packages. No production release, merge or Latest update occurred.

Remaining critical verification: actual Android SAF providers/revoked grants, installed offline TTS output/playback, ARM JNI thinking/native tools, real phone/tablet keyboard/rotation and physical clustering. `integration_test/android_capabilities_test.dart` exists but has not run. The x86 CI install smoke test does not exercise the ARM-only GGUF JNI path. General live compound-task planning, real cloud transports and keyed image editing remain unverified. Small models may fail tool protocols; validation/repair bounds stop unsafe progress but do not guarantee planning quality. Keep draft until these checks pass.

Commands:

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
python -m unittest discover -s scripts -p test_report_build_config.py
scripts/check_model_thinking.sh /path/to/compatible.gguf
```

Use the report's Android commands with a folder already granted through the app and an installed offline TTS voice. The downloaded host-test GGUF and generated ARM64 check build were cleaned after verification; model hash/log evidence remains. GitHub CLI credentials expired late in the session; connected GitHub tools continued CI/artifact access.

Release follow-up: a manual `publish_preview_run` workflow input can publish the verified Android assets from an existing successful preview run without rebuilding. It validates the source workflow, test-signing filenames and package hashes, uploads individual APK/AAB/checksum assets into a draft, verifies their remote sizes/digests, then publishes a prerelease with `Latest=false`. An already published release cannot be replaced. This was added after workspace uploads returned HTTP 401 from uploads.github.com, while the normal GitHub API remained authenticated. Bash syntax, actionlint and the three build-configuration tests passed; Publication passed in [run 44941279798](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/44941279798); [v1.0.189-agent-preview](https://github.com/CarlosPeterDev/neuromesh-ai/releases/tag/v1.0.189-agent-preview) is public with individual ARM64 APK, universal APK, AAB and checksum assets. Remote sizes and SHA-256 digests matched. Production Latest remains v1.0.158.

In-progress follow-up (source not yet released): native/cloud incremental agent text with argument buffering; no visible Understanding-request status; small core tool schemas and explicit real-capability guidance; bounded duplicate-discovery recovery; millisecond tool timing; full voice results persisted before speech completes; common image Save/Share viewer; real audio Save As with Android one-document SAF/hash verification; encoded output links and legacy space-name repair. Full Flutter suite: 251 passed / 4 optional skips; analysis zero errors/warnings. Live pinned Artemis Q4_K_M host inference selected audio then image across an explicit handler-error fixture, answered a greeting briefly and exposed readable partial text without raw tool arguments. ARM64 JNI syntax passed with 11 deprecation warnings. New Android Save UI, JNI preview transport and full new packages still need CI/device verification. A real-Artemis host regression gate has been added. Earlier public prerelease v1.0.189 does not include this follow-up.

Additional requested scope now in progress: model-author search filter; saved cloned-voice selection in calls; an LLM-visible catalog for choosing TTS voices; permission visibility in model onboarding/recommendations. Keep all previous stream, media persistence and Save/Share fixes.
