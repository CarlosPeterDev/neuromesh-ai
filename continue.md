# NeuroMesh AI — development state

Updated: 2026-11-19. Repository: carlospeter582011-prog/neuromesh-ai.
This file records verified results separately from device-dependent behavior.

## Verified release

Release `v1.0.90` and the moving `latest` contain individually downloadable normal
ARM64/universal APKs, AAB, Windows EXE, Linux DEB and AppImage. No Pro installer or
ZIP installer is published. Android/Windows were built by workflow run
44469443561; Linux was recovered on Ubuntu 24.04 by run 44476354845 after dependency
downloads exceeded the original timeout. The application code is shared; Linux
recovery changed build/packaging configuration only.

Verified checks:
- Dart analysis and the Flutter unit/widget suite passed in the Android build.
- Both Android APK signatures verified and their signing certificates matched.
- The standalone APK contains ARM64 libraries only. Its downloaded SHA-256 matches
  the release asset. Version code is 5090.
- Clean installation and reinstall succeeded on an Android 12/API 31 emulator.
- Windows and Linux builds and their native image-runtime smoke tests passed.
- Linux llama-server started with `--version`; the executable dependency check
  reported no unresolved libraries. Both DEB and AppImage were required to exist.
- GitHub Latest and v1.0.90 expose matching asset names, sizes and digests.

These checks do not establish successful model inference, microphone/echo behavior,
Bluetooth audio or installation on Carlos's physical Lenovo tablet.

## Implemented capabilities and code locations

- Skills: `SkillsService`, `SkillsView` and `ContextMentionButton` support creating,
  editing, importing SKILL.md or a single-skill ZIP, enable/disable switches, and
  explicit @skill:name / @file mentions. Context is retrieved in bounded pages;
  preserve source indentation. A small model can still miss instructions.
- Agent steps: `widgets/agent_steps.dart` renders live summaries, a step list and
  optional details. Tool traces should not be shown as raw JSON in normal chat.
- Models: GGUF metadata/helper classification, compatibility guidance and helper
  search are generic. A helper, a missing split, or an unsupported architecture
  cannot be made into a standalone text model simply by bypassing validation.
  See model_helpers, gguf_metadata and image_bundle tests.
- Voice: calls reuse a chat and workspace, retain messages, allow files, show agent
  steps and support selected/cloned voices and interruption. Native speech and
  real microphone sensitivity remain device-dependent.
- Android Linux workspace: Alpine rootfs is optional and downloaded inside the
  normal app. Only the loader libraries are bundled. Desktop commands use the
  computer's shell. Downloaded skills do not bypass existing tool permissions.
- Diagnostics: model load stages, metadata, device state, native failures and logs
  feed a previewable ZIP report. Developer delivery is compiled from private CI
  secrets; downloaders do not enter bot credentials. See SECURITY.md for the
  unavoidable extractability of credentials embedded in client binaries.
- Security/transfer regression suites cover secure MCP token handling, tunnel
  host keys, worker addressing and cluster backup scopes. Hardware/network
  interoperability still requires real devices.

## Work following v1.0.90

Voice playback cancellation is being hardened at asynchronous preparation/start
boundaries. Regression tests exercise stopping before preparation completes,
stopping while the native player starts, listener cleanup, and normal playback.
Do not describe this follow-up as present in v1.0.90; verify its CI/release first.

## Release and verification rules

- Keep Linux release builders on Ubuntu 24.04. Dependency installation excludes
  recommended extras, uses bounded retries, and has a 20-minute hard deadline.
- Require both Linux package formats; packaging failures must stop publication.
- Main releases use 1.0.<run_number>; Android versionCode is 5000 + run_number.
  Desktop metadata must use the same version name as its installer.
- Production signing requires the owner's four ANDROID_KEYSTORE_* secrets.
  Without them Android artifacts are development-signed. A newly generated
  development signer does not provide a stable certificate for future upgrades.
- Google Play submission requires separate authorization. No store submission has
  been performed. Never claim physical-device or full inference tests passed
  unless they actually ran.

## Origin

Imported from the MIT-licensed PrivateLM 1.0.7-cluster source. App ID is
com.neuromesh.ai, Dart package neuromesh_ai, URI scheme neuromesh://.
