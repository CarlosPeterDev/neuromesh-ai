# NeuroMesh AI development handoff

## Start here

NeuroMesh AI is a Flutter workspace for private local AI with optional cloud providers. Users can download or import models, chat with files, work with a tool-using agent, and connect compatible devices. Android uses Kotlin/JNI and bundled llama.cpp. The Windows and Linux packages include a CPU llama-server. See [GitHub](https://github.com/carlospeter582011-prog/neuromesh-ai) and [installation and build instructions](README.md).

Read this file, check the current branch and working tree, and review the latest GitHub runs and open pull requests before choosing work. Update this file when the next task, release status, or known limitations change.

## Release and verification

- The last published build checked on 2026-11-19 was **v1.0.100**, built from `31e7754`. All six normal installers are published together: Android ARM64 and universal APKs, a Play AAB, Windows x64 EXE, Linux x64 DEB and AppImage. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.100) · [Moving download channel](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/latest)
- [Actions run 44490592052](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44490592052), attempt 2, passed the Android, Windows, Linux and publication jobs. Attempt 1 stopped on Maven HTTP 429 dependency downloads; retrying the same application code succeeded.
- Analysis and the full Flutter regression suite passed. Android APK signatures verified with matching certificates, the slim APK passed its ARM64-only check, and clean install/reinstall passed on an Android 12/API 31 x86_64 emulator. Windows and Linux native image-runtime smoke tests passed.
- Publication required every installer to exist and verified all six entries in the shared SHA256SUMS.txt. The version and moving-channel assets were checked to have matching names, sizes and GitHub SHA-256 digests. No ZIP installer is published. This full run exercised the release changes from [issue #13](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/13).
- Both release tags are **prereleases**, because production Android signing is not configured. The tag named `latest` is the current download channel; do not confuse it with GitHub's stable-release Latest badge. Ephemeral development signers do not support compatible upgrades between different development builds.
- Real ARM64 Android inference, the physical Lenovo tablet, microphone/echo/Bluetooth behavior, Windows/Linux GUI and model inference on target hosts, and Play internal-track installation remain unverified. These artifacts are not certified production-ready.

### Voice changes included in v1.0.100

Interrupted speech no longer starts after WAV/native-player preparation or falls back to system speech after an interrupted worker failure. Pending assigned/legacy speech-worker waits are cancellable, service-owned connections close on interruption, late network errors retain handlers, and legacy voice requests disable redirects. Failed playback is stopped before its error is surfaced; completion listeners are released.

Nine deterministic playback/worker regression cases passed, including cancellation before a worker responds and normal response/playback behavior. These are service-level tests, not measurements of real microphone sensitivity. [Playback PR](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/14) · [Fallback PR](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/16) · [Worker cancellation PR](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/17)

## Where to work

| Area | Entry points and current behavior |
| --- | --- |
| Chat and agent | `lib/controllers/chat_controller.dart`, `lib/views/chat_view.dart`, `lib/services/agent_service.dart`. Chat supports text, attachments, cloud and local inference. Agent tools cover files, approved actions, MCP, and memory. |
| Projects, Skills and attachments | `lib/services/agent_service.dart`, `lib/services/skills_service.dart`, `lib/utils/skill_context.dart`, `lib/utils/page_text.dart`. Chats can use named workspaces. Explicit skill mentions are scoped to a chat. Local agent chat can retrieve additional context pages as needed. |
| Models and local inference | `lib/controllers/model_controller.dart`, `lib/services/hf_service.dart`, `lib/services/model_helper_service.dart`, `lib/services/inference_*.dart`. Some helper files are linked to a main model. Runtime and architecture compatibility depend on the model and platform. |
| Voice, images and devices | `lib/services/voice_service.dart`, `lib/services/voice_worker.dart`, `lib/services/local_image_service.dart`, `lib/services/cluster_service.dart`, `lib/services/cluster_backup.dart`, `lib/services/openai_server_service.dart`. Platform capabilities vary. |
| Diagnostics | `lib/services/diagnostics_service.dart`, `lib/views/diagnostics_view.dart`, and `workers/diagnostics/`. The report UI previews the ZIP before sending. See [diagnostic delivery configuration](SECURITY.md#developer-diagnostic-delivery). |
| Packaging | `.github/workflows/android-release.yml`, `android/app/build.gradle.kts`, `scripts/package_linux.sh`, and `installer/neuromesh.iss`. Build jobs use Flutter 3.38.x. Android uses JDK 17 and application ID `com.neuromesh.ai`. |

## Run the checks

```bash
git submodule update --init --recursive
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
python -m unittest discover -s scripts -p 'test_report_build_config.py'
```

Full release packaging also needs the dependencies in the GitHub workflow. Linux packaging uses Ubuntu 24.04. The release uses version name `1.0.<run_number>` and Android version code `5000 + run_number`. The Android release path builds the Play AAB and standalone APKs with `PLAY_BUILD=true`. Alpine downloads on demand on supported ARM64 devices. CI generates an ephemeral development key if production signing is unavailable, so plan a clean install when testing different development builds. Follow [release signing](SECURITY.md#release-signing) and [Play Store preparation](docs/PLAY_STORE.md).

## Next tasks

1. Configure stable owner-controlled production Android signing as described in SECURITY.md before wider distribution or promising compatible upgrades. Keep signing secrets out of the repository.
2. On a real ARM64 phone, record the release version, device and Android version. Install and open the app, load a small GGUF, generate a reply, and exercise chat attachments and project workspace recovery. Record pass or fail and link a redacted report for failures.
3. Smoke-test the Windows installer and both Linux packages on target hosts. Record app launch, model loading and generation results. Verify signing and try the Play internal track before broader distribution.
