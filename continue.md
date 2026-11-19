# NeuroMesh AI development handoff

## Start here

NeuroMesh AI is a Flutter workspace for private local AI with optional cloud providers. Users can download or import models, chat with files, work with a tool-using agent, and connect compatible devices. Android uses Kotlin/JNI and bundled llama.cpp. The Windows and Linux packages include a CPU llama-server. See [GitHub](https://github.com/carlospeter582011-prog/neuromesh-ai) and [installation and build instructions](README.md).

Read this file, check the current branch and working tree, and review the latest GitHub runs and open pull requests before choosing work. Update this file when the next task, release status, or known limitations change.

## Release and verification

- **v1.0.113** was published on 2026-11-19 from `ebdfc84`. It contains two Android APKs, the Play AAB, a Windows x64 installer, and Linux x64 DEB and AppImage packages. Android is development-signed. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.113)
- The release workflow passed analysis, tests, APK signature and architecture checks, Play bundle checks, Android emulator install and reinstall, desktop packaging and native image-runtime checks. The standalone APKs and AAB include the required Alpine launcher libraries. All six asset digests match the release checksum manifest on both release pages. [Workflow](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44532641823)
- All 164 Flutter tests passed locally, including search retries, HTML attachment follow-ups, small-context trimming, model-helper classification, cluster allocation, and Linux command confirmation. Physical ARM64 Alpine startup, voice playback, model-helper combinations, cluster performance, Windows command execution and SSH VM sessions still need device tests.
- Earlier tested releases were v1.0.100, v1.0.107, and v1.0.111. [Release history](https://github.com/carlospeter582011-prog/neuromesh-ai/releases)

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

## Changes in v1.0.113

The device follow-up covers grounded web search and attachment replies, fitting smaller local contexts, model and helper imports, one-line model tabs, token-based Cloudflare Worker setup, and linked voice and text chats with cloned voice selection. The Android build now requires PRoot's shared-memory library in the AAB and both APKs. Open **Toolbox → AI tools → Alpine terminal** to use the terminal directly. ARM64 Alpine launch, audio playback, and model-helper compatibility still need device checks. [Device report](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/20)

**Settings → Setup → Downloads** recommends installing Alpine on builds that include its ARM64 runtime. Applying the selected settings starts the OS download. Developer packages and the agent’s command permission have their own controls. [Setup follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/22)

The Android cluster supports saved device weights plus speed, context and model-capacity profiles. The requested split applies on the next GGUF load and is bounded by available memory. Windows and Linux use the host shell by default. **Settings → Desktop command access** controls per-command, per-type, or all-command approval and can use a user-configured SSH VM. Multi-device inference and native Windows/SSH behavior still need device checks. [Cluster and desktop follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/24)

Hugging Face files, the active download list, the download queue, and My models show **Model**, **Helper**, or **Unknown**. The repository view keeps file sizes and compatibility notes. Model memory estimates stay in the local library and load checks. File details and the download confirmation offer a companion preview before you start a download. [Model files follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/26) · [Companion preview](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/29)

## Next tasks

1. On a real ARM64 phone, record the release version, device and Android version. Install and open the app, load a small GGUF, generate a reply, and exercise chat attachments and project workspace recovery. Record pass or fail and link a redacted report for failures.
2. Smoke-test the Windows installer and both Linux packages on target hosts. Record app launch, model loading and generation results. Verify signing and try the Play internal track before broader distribution.
