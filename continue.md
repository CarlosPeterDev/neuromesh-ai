# NeuroMesh AI development handoff

## Start here

NeuroMesh AI is a Flutter workspace for private local AI with optional cloud providers. Users can download or import models, chat with files, work with a tool-using agent, and connect compatible devices. Android uses Kotlin/JNI and bundled llama.cpp. The Windows and Linux packages include a CPU llama-server. See [GitHub](https://github.com/carlospeter582011-prog/neuromesh-ai) and [installation and build instructions](README.md).

Read this file, check the current branch and working tree, and review the latest GitHub runs and open pull requests before choosing work. Update this file when the next task, release status, or known limitations change.

## Release and verification

- The last published build checked on 2026-11-19 was **v1.0.90**, built from `ebfae00`. It has Android ARM64 and universal APKs, a Play AAB, a Windows x64 installer, and Linux x64 DEB and AppImage installers. Android packages are development-signed. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.90)
- The v1.0.90 Android job passed analysis, tests, bundle and APK checks, and install and reinstall on an Android 12 x86_64 emulator. Windows packaging passed in that run. Linux packaging passed in a later Ubuntu 24.04 recovery run. Its assets were added to the release separately. The v1.0.90 checksum file covers the Android packages. [Original run](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44469443561) · [Linux recovery](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44476354845)
- Real ARM64 Android inference, Windows and Linux runtime behavior on user devices, and Play internal-track installation still need verification for this build. Confirm any newer results before reporting them.
- Changes for the next release are tracked in [GitHub issue #13](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/13). The workflow assembles and hashes all six installers before publishing and marks both tags as prereleases when the Android packages are development-signed. The next full build must exercise the changed workflow.

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

Full release packaging also needs the dependencies in the GitHub workflow. The Android release path builds the Play AAB and standalone APKs with `PLAY_BUILD=true`. Alpine downloads on demand on supported ARM64 devices. CI generates an ephemeral development key if production signing is unavailable, so plan a clean install when testing different development builds. Follow [release signing](SECURITY.md#release-signing) and [Play Store preparation](docs/PLAY_STORE.md).

## Next tasks

1. Review issue #13 and its linked pull request. Confirm the next full Actions run has the Android, Windows, Linux and publication jobs green. Check the release page lists six installers and that `sha256sum -c SHA256SUMS.txt` verifies each file.
2. On a real ARM64 phone, record the release version, device and Android version. Install and open the app, load a small GGUF, generate a reply, and exercise chat attachments and project workspace recovery. Record pass or fail and link a redacted report for failures.
3. Smoke-test the Windows installer and both Linux packages on target hosts. Record app launch, model loading and generation results. Verify signing and try the Play internal track before broader distribution.
