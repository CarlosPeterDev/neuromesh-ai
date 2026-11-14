# continue.md — NeuroMesh AI development state

## Overview
Small base app (Flutter + Kotlin + llama.cpp) to be extended step by step. Repo: carlospeter582011-prog/neuromesh-ai.

## Build status (verified 2026-11-14)
CI run on commit de9bb01 succeeded: analyze + tests passed, arm64 APK, universal APK and AAB built, release `v1.0.4` and moving `latest` published as DEV-signed pre-releases. Fixes needed on the way: Flutter pinned to 3.38.x (stable 3.50 needs Gradle 9.3.1), modern glslc installed for Vulkan shaders, submodule pointer restored. Install/inference on a real device: NOT tested.

## Done (code in place)
- Source imported from an MIT-licensed open-source Flutter LLM client (release 1.0.7-cluster tree), single import commit.
- Renamed: app ID `com.neuromesh.ai`, Dart package `neuromesh_ai`, plugin Kotlin package `com.neuromesh.llama_flutter_android` (JNI symbols renamed to match), QR scheme `neuromesh://`.
- Removed old Firebase project config, old marketing images, old author credits from the UI. Update checker now points at this repo's releases.
- Original logo + adaptive launcher icon generated (navy / cyan / violet / lime node network).
- CI: `.github/workflows/android-release.yml` (analyze, test, arm64 APK, universal APK, AAB, SHA-256, tag `v1.0.N` + moving `latest`).

## Models screen (added after v1.0.4)
- Browse tab replaced by a live Hugging Face GGUF search (`lib/services/hf_service.dart`, `lib/views/hf_browser.dart`): search box, per-repo file list with sizes/quants, download into the app or save to the phone's public Downloads folder. Hard-coded catalog links are no longer shown (catalog data still exists in code for already-downloaded models and image models).
- Import sheet gained a "Get from Hugging Face" shortcut. File/folder import is unchanged.
- UNVERIFIED on a device; only analyze/unit tests in CI.
- Not handled: gated repos (hidden behind a notice), split multi-part GGUFs and vision projector files (filtered out).

## Not done / unverified
- Native JNI rename is untested on a device (build compiles, runtime unverified).
- Not implemented: new cluster wizard, model manager rework, agents, document RAG, voice, performance center, Arabic/RTL, theme redesign, new navigation. Existing features from the base remain as inherited.
- No hardware testing performed.

## Versioning
`1.0.<run_number>`, versionCode = run number, no version commits (no workflow loop).

## Signing
Dev-signed + pre-release unless ANDROID_KEYSTORE_* secrets exist (see SECURITY.md).

## Next
1. Test install on a real arm64 phone.
2. Verify install + local inference on a real arm64 phone.
3. Then add features one at a time, updating this file.
