# NeuroMesh AI development handoff

## Direct Chat tools for small models

The Chat composer now offers **Auto**, **Search**, **Calc**, **Image**, **Speak**, and **Transcribe**. Auto uses the existing model-directed tool flow. The other choices send one typed request to the selected tool and add no hidden tokens or language-model passes. Search shows source excerpts and links. Calc accepts a formula, Image sends the description to Pollinations, Speak synthesizes the exact words entered using the selected voice, and Transcribe takes an attached audio file and uses an installed or assigned listening model. The next draft returns to Auto. Regenerating a saved turn keeps its original choice.

Direct Chat reuses the argument validator, workspace, approval policies, bounded execution, cancellation, and expandable traces. Six focused tests cover routing, missing audio, permissions, cancellation, persistence, and direct media and calculator results. A seventh extracts words from an actual WAV through the app's Whisper Tiny recognizer. All 26 Chat submission tests passed with the Whisper fixture. The Whisper fixture can be exercised by setting `NEUROMESH_TEST_WHISPER_TINY` to the extracted directory. Physical Android interaction and provider availability need device verification.

## Calculator routing and hidden context

Artemis answered the reported fraction as prose and gave the wrong value. The verified eight-place result is `420436.17803423`. A short model decision now selects Calc for a numerical answer. For a single supported literal expression the app keeps the original operands and grouping, including common Unicode and LaTeX forms. It asks about decimal precision using only the text left after removing the expression. The calculator's result and tool trace go directly into the reply. Requests without a separable literal expression continue through the regular tool loop.

The final shared decision uses 54 actual Artemis input tokens for a greeting, down from 105 for the previous image-only decision. The arithmetic path excludes chat history, memory and the full tool catalog during its focused calls. Local Chat uses compact tool instructions and limits automatic memory to an estimated 160 tokens. Image decisions with ambiguous follow-up output are confirmed by the model before calling Pollinations.

With the reconstructed arithmetic request, the older first pass counted 155 tokens. The new first pass counted 104 for the Unicode formula and 105 for LaTeX. The separate precision pass counted 75 and 72 tokens respectively, and the real calculator returned `420436.17803423` in both runs. All 222 fixture-backed Flutter tests passed. Static analysis reported zero warnings or errors. [Android build and packaged inference](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/45513251337)

**v1.0.212** was published as GitHub Latest from `9ecccfe`. Android 12 x86-64 installed and upgraded the APK, launched the Play split, verified Stop model and used the packaged GGUF runtime to confirm Calc selection and eight-place precision. Both Test APKs and the development-signed AAB passed SHA-256 and archive checks after download. Physical-device Calc and speech playback checks remain open. [Release](https://github.com/CarlosPeterDev/neuromesh-ai/releases/tag/v1.0.212)

## Chat speech voice selection

The reported Artemis call used `model_id: tts-1`, `speaker: male` and `language: en-US`. The local executor rejected the unknown model ID before synthesis. Chat now advertises a typed voice preference and resolves it against the installed speaker catalog, including the older speaker field for male and female preferences. The resolver matches the primary language from a locale tag. An unavailable model ID can be bypassed only if there is a voice preference and a matching installed voice. The saved reply and tool result name the voice actually used. An unavailable matching voice produces an actionable error. Voice age remains unverified.

The host regression passed the exact reported arguments through Chat's speech tool with the real Kitten Nano model. It selected `Voice 2 (M) · kitten-nano`, produced a non-silent WAV and kept the saved speaker preference. Kokoro synthesized its default-voice fixture, and a French request against the English-only fixture produced a targeted error. [Kitten speaker order](https://github.com/k2-fsa/sherpa-onnx/blob/master/scripts/kitten-tts/v0_8/generate_voices_bin.py)

The speech regression verifies execution for a model-selected tool call. A separate temperature-zero reference run answered the speech request in text, so general model selection of the speech tool remains variable.

## Model-directed Pollinations in Android Chat

Interactive inference preempts automatic titles and capability checks, including while a background call is waiting for the native context. A repeatable Artemis test showed that the full tool catalog could produce prose where an image was requested. Eligible local text turns now use a short deterministic model decision on the current request. Once the model selects an image, a separate short check looks for independent follow-up work. The user’s description passes through the normal argument validator and tool policy. A standalone image turn finishes with the provider result and its attachment. A mixed turn can follow up with the other tools.

Native Artemis tests distinguished English and Arabic image requests from greetings, requests for explanations, and requests to write a prompt. A host end-to-end check used the real model decision for `A flying car above Cairo`, invoked the existing Pollinations executor, and saved a 59,453-byte JPEG. This used the public anonymous endpoint and simulated approval of the test prompt. Android release verification tests the model’s decisions from the packaged JNI libraries. The phone’s approval and image display still need physical coverage.

Android’s foreground notification offers Stop for an active Pollinations request or Remote Access. Each action carries the operation’s ID. Image cancellation flows through the existing Chat stop path and closes the HTTP request. Remote Access stop closes its socket and any forwarded requests, and clears its saved enabled setting. The foreground service exits when the final operation ends. The native service replaces dependencies used only by the old notification bridge. The Android release gate drives the packaged notification actions after backgrounding the app.

The separate **Local model loaded** notification offers **Stop model** even when inference is idle. Stop cancels native generation, disposes the loaded backend, and clears the active model status. Each load has its own action ID. A stale action cannot unload a replacement model. This notification uses no foreground data-sync service or wake lock of its own.

**v1.0.210** was published as GitHub Latest from `d668b96`. Android 12 x86-64 installed and upgraded the Test APK and launched the Play split. Instrumentation verified Stop for an idle model and for a model while image work and Remote Access were both active. The Flutter cancellation test verified that Stop interrupts inference and disposes the loaded engine. The packaged JNI smoke test verified semantic decisions, text generation, and a real image input. Both separately published APKs and the development-signed AAB passed the published SHA-256 and archive checks after download. [Release](https://github.com/CarlosPeterDev/neuromesh-ai/releases/tag/v1.0.210) · [Android verification](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/45483140790)

All 218 fixture-backed Flutter tests passed. Static analysis finished with zero warnings or errors. The release gate exercised the notification actions with the app backgrounded. The reported phone still needs a physical-device check of the notification and Pollinations image display.

## Android GGUF token throughput

Live Chat, saved replies, and performance screens use the GGUF decoder’s sampled token count and elapsed time between samples. A text chunk can span multiple tokens, especially when the decoder joins UTF-8 fragments. Historical chunk rates are no longer shown. Runtimes without native token metrics omit the Chat speed. The inference fixture asserts nine sampled tokens for Artemis’s greeting. The loader also preserves the underlying error from llama.cpp in diagnostics.

All 206 fixture-backed Flutter tests passed, and analysis reported zero warnings or errors. In a host JNI check, Artemis returned four emoji and three spaces in seven streamed text chunks from 12 sampled tokens. [Android build and packaged inference check](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/45464738840)

**v1.0.206** was published as GitHub Latest from `d80d528`. The Android 12 x86-64 emulator installed and upgraded the Test APK, launched the Play split, and verified nine sampled tokens and a positive elapsed interval for the fixture greeting using the universal APK’s JNI libraries. Both APKs and the development-signed AAB are separate assets. All three passed the published SHA-256 and archive checks after download. [Release](https://github.com/CarlosPeterDev/neuromesh-ai/releases/tag/v1.0.206)

An Android 14 report from v1.0.205 recorded an Artemis load failure on an SM-A235F. The reported file was 532,795,712 bytes. The catalog download and CI fixture are 532,402,496 bytes. The report contains only the old generic loader error, so the exact failure is unconfirmed. The new diagnostics are verified with an intentionally damaged host fixture. Physical-device retesting remains open.

## Current milestone — Android GGUF correctness

The `android-gguf-correctness` branch continues from the v1.0.204 handoff. A host fault-injection experiment reproduced the ASCII corruption pattern in the old sampler path. The updated native runtime validates GGUF tensors and scores, encodes Unicode prompts correctly, and runs actual model generation as part of the Android release gate. The original phone's backend and model fingerprint remain unknown. [Investigation and results](docs/ANDROID_GGUF_CORRECTNESS.md) · [Android build and publication](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/45451632477)

**v1.0.205** was published as GitHub Latest from `65951ee`. Android 12 x86-64 upgraded the Test APK, launched the Play split, and ran raw text, ChatML, sampled, context and multimodal inference using the packaged JNI libraries. The separate APKs install as NeuroMesh AI Test. The 187.78 MB AAB is development-signed. Physical ARM64 and mobile Vulkan testing remain open. [Release assets](https://github.com/CarlosPeterDev/neuromesh-ai/releases/tag/v1.0.205) · [Physical-device matrix](docs/ANDROID_DEVICE_TESTS.md)

## Prior milestone — adaptive Android Chat

The `android-adaptive-inference` branch starts at `a0cfa75`. Chat streams ordinary replies and validates model-selected tool requests. Android GGUF Chat counts tokens for the formatted prompt, and the capability check runs in the background when the model is idle. Chat retains attachment workspaces, saved media, memory, search, image generation, speech and cluster integration. The standalone Agent, MCP, Alpine and OpenCode integrations have been removed. [Dependency map and verification](docs/ANDROID_ADAPTIVE_INFERENCE.md)

**v1.0.204** was built from `ef8bbf1` and published as GitHub Latest. Android 12 installed and upgraded the public Test APK and launched the Play-derived splits alongside it. The development-signed AAB is 185.34 MB, with a 104.99 MB ARM64 split download. All three published package digests and archive contents were checked after downloading. [Release](https://github.com/CarlosPeterDev/neuromesh-ai/releases/tag/v1.0.204) · [Build and publication](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/45401242438)

All 204 Flutter tests passed with genuine projector and voice fixtures. Analysis reported zero warnings or errors. The host Chat adapter streamed and saved replies with and without the projector and recovered after cancelling before first output. The reported phone scenario remains in the [physical Android matrix](docs/ANDROID_DEVICE_TESTS.md).

## Prior milestone — Android stability

The `android-stability` branch starts at `bc0acc8`. Ordinary text and voice Chat now use a bounded, schema-validated tool loop. Android startup waits for Hive, Chat sequences context transitions, and failed worker starts clear the role. The standalone Agent tab, scheduled agent startup, and MCP connections are disabled. GitHub's release workflow builds and publishes Android artifacts individually. [Audit and evidence](docs/ANDROID_STABILITY_AUDIT.md) · [Physical Android test list](docs/ANDROID_DEVICE_TESTS.md)

The current audit is against `main`. Open PRs #61 and #62 describe different Android agent work and were not merged into this branch. Their checks do not verify this branch. [PR #61](https://github.com/CarlosPeterDev/neuromesh-ai/pull/61) · [PR #62](https://github.com/CarlosPeterDev/neuromesh-ai/pull/62)

### Verification on this branch

- Flutter 3.38.9 full suite passed 233 tests, with four optional fixture and desktop smoke checks skipped. The final focused run passed all 25 Chat, tool-loop and LiteRT channel tests after the last UI metrics and trace changes. Static analysis completed with informational findings and no warnings or errors. The three Python build-configuration tests, workflow YAML check, publication script syntax check and `git diff --check` passed.
- The Android ARM64 debug Flutter asset bundle compiled. The modified Kotlin LiteRT bridge compiled in an isolated API check against Android SDK 36, the Flutter embedding and the real LiteRT-LM 0.12.0 AAR. That check used the available Kotlin 2.0.21 compiler with dependency metadata validation bypassed. Production Kotlin compilation remains part of the Gradle build.
- Release APK and AAB attempts did not produce artifacts. After configuring the proxy and reducing the Gradle heap, APK configuration hit HTTP 503 fetching `com.android.tools.utp:android-test-plugin-result-listener-gradle-proto:30.3.0` through `piper_phonemize`. The AAB configuration stopped on an incomplete local NDK 28.2.13676358 installation. Both NDK versions were requested by this build. No release was published or marked Latest from these changes.
- Real Android model output, LiteRT cancellation on device, two-phone RPC, and native speech playback remain pending. Native function calling stays disabled while the LiteRT Android tool-registration path lacks verification. [Audit and device coverage](docs/ANDROID_STABILITY_AUDIT.md)

## Start here

NeuroMesh AI is a Flutter workspace for private local AI with optional cloud providers. Users can download or import models, chat with files and model-directed tools, and connect compatible devices. Android uses Kotlin/JNI and bundled llama.cpp. Historical Windows and Linux packages included a CPU llama-server. See [GitHub](https://github.com/carlospeter582011-prog/neuromesh-ai) and [installation and build instructions](README.md).

Read this file, check the current branch and working tree, and review the latest GitHub runs and open pull requests before choosing work. Update this file when the next task, release status, or known limitations change.

## Combined OpenCode and Android preview

Build `8554a20` combines the OpenCode terminal preview and the smaller Play AAB. All 221 Flutter tests and three build-configuration tests passed locally. The entire Flutter suite ran in a network namespace with only loopback available. It used the published Artemis GGUF and BF16 projector and the Kitten Nano and Kokoro voice models. OpenCode streamed from the local GGUF in Xfce Terminal, the genuine projector was recognized, and both voice models generated WAV audio.

The combined v1.0.150 Actions run passed. Windows and Linux produced native packages and passed their desktop image-runtime tests. The Android 12 x86-64 emulator launched the universal APK, accepted its in-place reinstall, and launched a separate installation generated from the AAB. The development-signed AAB was 186,667,730 bytes. Bundletool measured a 105,701,927-byte ARM64 download. The Android APK signatures and the three published preview file checksums passed. These smoke tests cover startup. Physical Android devices and desktop installer operation need their own checks. [Combined preview PR](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/57) · [Package build and emulator results](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44851432639)

## NeuroMesh 2.0 desktop OpenCode milestone

- **Agents** discovers installed OpenCode and shows whether the local terminal preview is available. On Linux with OpenCode v1.19.6 and a supported terminal, it links the loaded model over a dedicated authenticated loopback endpoint. Provider configuration and CLI history are scoped to a temporary profile. [Historical OpenCode preview](https://github.com/CarlosPeterDev/neuromesh-ai/pull/54)
- Local verification passed 217 Flutter tests and all three build-config tests. Four optional checks were skipped in the standard suite. The separate Linux smoke test passed with Xfce Terminal, real OpenCode and Artemis GGUF in a loopback-only network namespace. [Implementation and checks](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/54/checks)
- The preview exposes text completions. Next is the agent session API and native Chat UI, followed by structured tool support and approval tests. Windows and macOS launch, physical cluster operation through the bridge, Android runtime distribution, and a release from this branch remain pending.
- The v1.0.139 AAB was 324,350,971 bytes. Meeting the 200 MB raw AAB requirement needs an Android packaging pass and a separate raw artifact check. The existing preview assets are pre-releases.

## Automatic GitHub Releases

Every push to `main` starts the Android release workflow. The publish job verifies the build outputs and SHA-256 digests, then publishes one versioned GitHub Release with individual installer downloads. GitHub marks the newest eligible version **Latest**, and the Android updater uses GitHub’s Latest release endpoint with a fallback for the historical channel. Development-signed packages carry a development label and the `-dev` filename suffix. [Latest release](https://github.com/CarlosPeterDev/neuromesh-ai/releases/latest)

## Persistent Android test APKs

The standard v1.0.139 and v1.0.155 APKs had different temporary signers. CI now uses a stable public test certificate for GitHub APKs when a private signer is unavailable. These APKs install as **NeuroMesh AI Test** with a separate package ID. The Play AAB keeps the normal application ID and its own signer. Two independent imports of the public fixture produced the same signing fingerprint. Android CI verifies both package IDs and upgrades a lower-version signed fixture on the emulator before installing the Play-generated splits alongside Test. [Signing and migration](SECURITY.md#public-test-apks) · [Tracking issue](https://github.com/CarlosPeterDev/neuromesh-ai/issues/58)

## Release and verification

- **v1.0.139** was published from `b97a515d23a8d18ca2ad7dc0c2b3192038960398`. It includes tool discovery, Android shared-folder access, clickable replies, the narration fixes, and local Kitten and Kokoro synthesis. The Android 12 emulator passed installation and reinstallation. All six installers match the checksums on both release pages. The GitHub APKs use a temporary preview signer. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.139) · [ARM64 APK](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/download/v1.0.139/NeuroMesh-AI-v1.0.139-arm64-dev.apk) · [Build and publication](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44796547105)
- **v1.0.135** was published from `1e92b4661314fcd7cee3c400afeac9cf82eec1c4`. The Android 12 emulator passed installation and reinstallation, and all six installers match the published checksums. The GitHub APKs use a temporary preview signer. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.135) · [Build and publication](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44791100634)
- All 213 local Flutter tests passed with the real Artemis projector and two published voice models. Live Qwen 3.5 0.8B Artemis used tool discovery and executed the calculator. Physical Android calls, storage-provider operations, and two-device pairing remain to be verified. [Tool discovery](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/48) · [Offline voice](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/50)
- **v1.0.133** was published on 2026-11-20 from `1339ddf3e388b92131f3ec5fb778a45d37af8f2b`. All six installers match their published checksums, and Android 12 passed clean install and upgrade. Android is development-signed. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.133) · [Build and publication](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44707175729)
- All 194 local Flutter tests passed. Live checks verified a renamed SmolVLM projector against the publisher’s file and checksum. Actual Android imports and pairing remain to be tested. [General matching](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/42) · [Composite projector follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/44)
- **v1.0.128** was published on 2026-11-20 from `a7b8630f0f25b69b6ad875df03c89726dbcb3730`. All six installers match their published checksums, and the Android 12 emulator passed clean install and upgrade. Android is development-signed. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.128) · [Build and publication](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44652746758)
- All 188 Flutter tests passed locally. Live checks covered public web search and anonymous Pollinations generation. Linux host checks covered source-bound transfer connections, Artemis vision recovery and UTF-8 token decoding. Pairing and transfer on the originally reported physical Android devices remain open. [Model and connection fixes](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/38) · [Narration fix](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/40)
- **v1.0.113** was published on 2026-11-19 from `ebdfc84`. It contains two Android APKs, the Play AAB, a Windows x64 installer, and Linux x64 DEB and AppImage packages. Android is development-signed. [Release](https://github.com/carlospeter582011-prog/neuromesh-ai/releases/tag/v1.0.113)
- The release workflow passed analysis, tests, APK signature and architecture checks, Play bundle checks, Android emulator install and reinstall, desktop packaging and native image-runtime checks. The standalone APKs and AAB include the required Alpine launcher libraries. All six asset digests match the release checksum manifest on both release pages. [Workflow](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44532641823)
- All 164 Flutter tests passed locally, including search retries, HTML attachment follow-ups, small-context trimming, model-helper classification, cluster allocation, and Linux command confirmation. Physical ARM64 Alpine startup, voice playback, model-helper combinations, cluster performance, Windows command execution and SSH VM sessions still need device tests.
- Earlier tested releases were v1.0.100, v1.0.107, and v1.0.111. [Release history](https://github.com/carlospeter582011-prog/neuromesh-ai/releases)

## Play AAB size

The v1.0.139 bundle was 324,350,971 bytes, including 124,471,709 bytes of native debug metadata. Android release packaging omits that metadata and the two largest browser-only speech payloads. Gradle generated a development-signed v1.0.146 AAB of 186,664,083 bytes. The corrected workflow check passed on that exact bundle and measured an ARM64 split download of 105,699,551 bytes. The signature, manifest, and stripped Flutter binaries passed verification. Bundletool generated splits for all three supported ABIs. The normal build now checks the final signed AAB against the 200 MB target and separately measures the ARM64 split download. Local Flutter checks passed 210 tests with three optional fixture tests skipped. [Play preparation](docs/PLAY_STORE.md) · [Packaging PR](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/56) · [Measured Gradle artifact](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44848498057/artifacts/14684554372)

## Where to work

| Area | Entry points and current behavior |
| --- | --- |
| Chat and tools | `lib/controllers/chat_controller.dart`, `lib/views/chat_view.dart`, `lib/services/chat_tool_loop.dart`, `lib/services/chat_tool_service.dart`. Chat supports model-selected bounded tools, local and cloud inference, attachments and saved memory. |
| Projects, Skills and attachments | `lib/services/chat_tool_service.dart`, `lib/services/skills_service.dart`, `lib/utils/skill_context.dart`, `lib/utils/page_text.dart`. Chats can use named workspaces. Explicit skill mentions are scoped to a chat. Chat can retrieve additional context pages as needed. |
| Models and local inference | `lib/controllers/model_controller.dart`, `lib/services/hf_service.dart`, `lib/services/model_helper_service.dart`, `lib/services/inference_*.dart`. Some helper files are linked to a main model. Runtime and architecture compatibility depend on the model and platform. |
| Voice, images and devices | `lib/services/voice_service.dart`, `lib/services/voice_worker.dart`, `lib/services/pollinations_image_service.dart`, `lib/services/cluster_service.dart`, `lib/services/cluster_backup.dart`, `lib/services/openai_server_service.dart`. Platform capabilities vary. |
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

Full release packaging also needs the dependencies in the GitHub workflow. Linux packaging uses Ubuntu 24.04. The release uses version name `1.0.<run_number>` and Android version code `5000 + run_number`. The Play AAB uses `PLAY_BUILD=true`. Standalone APKs use `PLAY_BUILD=false` and can check for GitHub updates. Alpine downloads on supported ARM64 devices. GitHub APKs support a persistent signer. The Play bundle preview uses a temporary upload key when signing credentials are unavailable. The standalone Test APK uses the persistent public test certificate. Follow [release signing](SECURITY.md#release-signing) and [Play Store preparation](docs/PLAY_STORE.md).

## Changes in v1.0.113

The device follow-up covers grounded web search and attachment replies, fitting smaller local contexts, model and helper imports, one-line model tabs, token-based Cloudflare Worker setup, and linked voice and text chats with cloned voice selection. The Android build now requires PRoot's shared-memory library in the AAB and both APKs. Open **Toolbox → AI tools → Alpine terminal** to use the terminal directly. ARM64 Alpine launch, audio playback, and model-helper compatibility still need device checks. [Device report](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/20)

**Settings → Setup → Downloads** recommends installing Alpine on builds that include its ARM64 runtime. Applying the selected settings starts the OS download. Developer packages and the agent’s command permission have their own controls. [Setup follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/22)

The Android cluster supports saved device weights plus speed, context and model-capacity profiles. The requested split applies on the next GGUF load and is bounded by available memory. Windows and Linux use the host shell by default. **Settings → Desktop command access** controls per-command, per-type, or all-command approval and can use a user-configured SSH VM. Multi-device inference and native Windows/SSH behavior still need device checks. [Cluster and desktop follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/24)

Hugging Face files, the active download list, the download queue, and My models show **Model**, **Helper**, or **Unknown**. The repository view keeps file sizes and compatibility notes. Model memory estimates stay in the local library and load checks. File details and the download confirmation offer a companion preview before you start a download. [Model files follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/26) · [Companion preview](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/29)

## Next tasks

1. On a real ARM64 phone, record the release version, device and Android version. Install and open the app, load a small GGUF, generate a reply, and exercise chat attachments and project workspace recovery. Record pass or fail and link a redacted report for failures.
2. Run the Android device matrix, then verify signing and the Play internal track before broader distribution. [Physical Android test list](docs/ANDROID_DEVICE_TESTS.md)

## Android vision, cluster and device transfer follow-up

- **Artemis vision pair** — use the publisher’s `Qwen3.5-0.8B-Artemis-Q4_K_M.gguf` with `mmproj-BF16.gguf` or `mmproj-F16.gguf` from the same repository. The repository-based helper ID `mmproj-39d50a89a8cb459a6.gguf` corresponds to its BF16 projector. [Publisher files and compatibility notes](https://huggingface.co/turintech/Qwen3.5-0.8B-Artemis-GGUF)
- **GGUF load diagnosis** — Huihui’s `patch-all-5.gguf` contains 27 replacement tensors for compatible Unsloth base weights. NeuroMesh categorizes it as a helper before attempting to load. Complete 27B weights require substantially more memory than the reported tablet had available. [Publisher patch notes](https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF#patch-unsloth-9)
- **Vision and calls** — Android bounds image encoding and reply length, serializes native context access and records the last image attempt for diagnostics. Use **Settings → Model parameters → Local model thinking** for supported GGUF templates. The call controls offer a camera switch on devices with both lenses.
- **Cluster** — Automatic and Best speed keep models local when memory allows. For larger models, they estimate layer placement using measured connection latency and advertised memory bandwidth. Voice and image-generation jobs already have separate assignments in **Workload placement**. GGUF projectors run on the inference device. Compare the same prompt, context and generation settings on one phone versus multiple phones before claiming a speedup.
- **Transfer** — **Settings → Device transfer** offers models, helpers, chats, portable preferences, saved memory, workspaces, documents, skills and voice profiles. Workspaces stream as authenticated records. Chats and other metadata still have per-category size limits. The receiving device can reinstall Alpine through Setup and open the restored workspace in its terminal. Re-enter credentials and re-pair devices on the destination.
- **Chat and diagnostics** — Automatic web search checks multiple providers. Literal audio-file requests use the WAV tool directly. Chat renders common inline and display LaTeX. The report screen shows sending progress and distinguishes Telegram rejection from network timeouts.
- **Device verification pending** — reproduce the Artemis photo prompt on physical ARM64, test a video call camera switch and two-device restore, and measure cluster throughput. Live Telegram delivery depends on the configured bot and target chat. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/31)

### Verification for the device follow-up

- All 168 Flutter tests passed locally, and GitHub passed analysis and tests on both follow-up PRs. [Application checks](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44568877126) · [Packaging workflow checks](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44570894587)
- Verified both downloaded Artemis file digests against the publisher. The bundled Android C++ wrapper ran on a Linux CPU against the repo’s llama.cpp with simulated JNI calls. It completed image, text, and image turns in order, returned a context error for an oversized image prompt, and answered another text turn after the error. Separately, llama-server b12543 at 4096 context completed two 576 × 768 synthetic image requests in about 4.6 seconds each with a 256-token image cap, compared with about 8.8 seconds each at its default image limit on the same host. This measures the host setup and simple image questions. [Publisher checksums](https://huggingface.co/turintech/Qwen3.5-0.8B-Artemis-GGUF/blob/main/README.md#verified-artifact-hashes)
- The v1.0.117 Android packaging attempt stopped while resolving Kotlin libraries. PR #33 added Maven Central to Flutter’s included Gradle plugin build. Run 44571481873 tracks the next Android and desktop packaging attempt. [Dependency fix](https://github.com/carlospeter582011-prog/neuromesh-ai/pull/33) · [Release workflow](https://github.com/carlospeter582011-prog/neuromesh-ai/actions/runs/44571481873)

## Optional model helpers, setup and LAN pairing

- For a GGUF with a vision projector, **My models → Load** offers **Load with vision helper** and **Load without helpers**. Text-only mode skips the projector download and load for that session. Loading the last model again and retrying a failed load retain the chosen mode. Importance-matrix files such as `imatrix_micro3.gguf` are classified as helpers.
- **Settings → Setup** recommends **Qwen 3.5 0.8B Artemis Q4_K_M** and the matching **BF16 projector**. The pair takes about 739 MB of storage. Supported Android builds preselect Alpine and its developer packages. The terminal shares the agent workspace. Command approvals retain the existing setting.
- Models and Chat show a down arrow near the bottom-right of long lists. It scrolls to the end of the current list or conversation.
- **Device transfer** and **Phone cluster** prefer local Wi-Fi or hotspot addresses and allow choosing among available interfaces. Android workers show Ready once the RPC socket is listening. Pairing can recheck a worker at a new discovered address. Transfer route errors omit the pairing token. Both devices need direct access to each other on the local network.
- All 173 Flutter tests passed locally. A Linux host smoke test verified the RPC readiness signal against a bound and an occupied port, and the transfer client reached an HTTP listener on the chosen private interface. Two physical Android devices still need a transfer and cluster pairing test. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/35)

## Imported projectors, online images and device transfer

- In **Models → My models**, the importer and loader reuse an installed GGUF vision helper when the main model and helper have the same specific family name, or when a known Artemis BF16 or F16 projector matches the publisher’s SHA-256. A saved manual link takes priority when its file is present. Ambiguous names can still be linked manually. **Load without helpers** continues to skip vision.
- Chat’s built-in `generate_image` tool prefers an active local or cluster image model. The fallback uses Pollinations’ public Sana endpoint and attributes online results in Chat. Explicit standalone image requests also work while no chat model is loaded. Confirm agent-composed online calls before sending the prompt. An anonymous 768 × 768 generation returned a valid Sana JPEG. Requests for other models were routed to Sana or hit the anonymous rate limit.
- **Models → Voice → Import voice models (.zip)** accepts multiple supported archives and reports per-file errors without stopping the batch.
- The transfer client first tries the system route, then up to two explicitly bound local IPv4 source addresses. It reuses the successful source for downloads and gives different recovery steps for no route, refused connections, and timeouts. Phone Cluster pairing tests alternate private addresses advertised by the worker before rediscovery. Test the receiver and sender on the original Android Wi-Fi setup and on a device hotspot. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/37)
- Local checks passed, including the real BF16 projector, a source-bound HTTP round trip, and direct chat image routing with no text model loaded. Physical Android transfer, vision and batch voice import still need device verification.

## Public web search and researched audio

- Search uses public DuckDuckGo and Wikipedia pages and public Bing and Google News feeds. It requires no credentials. The search query omits follow-up writing and audio instructions. Relevant results are ranked before the app reads supporting passages.
- An explicit request to search, write a paragraph and create an audio file runs those three stages in order. The WAV reads the sourced paragraph, with citation markers omitted. Repeated tool calls and unsuccessful context searches now lead to a single final answer pass.
- Android llama.cpp token streaming preserves UTF-8 characters across token boundaries and sends UTF-16 to Kotlin. A host check covered fragmented emoji, Arabic, malformed and ASCII characters. The app’s live web search returned sources for the reported sports question and the coding model question. Device reproduction remains open.

Normal writing requests that explicitly ask for narration use the same two-stage flow. Chat runs the writing stage with tools off, then sends the finished text to the WAV tool. No intermediate notes file is necessary. Local orchestration tests cover both writing requests from the user’s screenshot. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/39)

## Matching imported models and helpers

- **My models** classifies artifacts from their filenames and supported GGUF and Safetensors metadata. Renamed GGUF projectors and LoRA adapters can be identified from their headers. Associations use saved links, publisher base-model metadata, family names, and verified checksums from Hugging Face. The Artemis BF16 and F16 publisher digests are available offline.
- **Find main models** and **Find helpers** display compatible installed candidates and show the publisher’s repository when identified. A generic file with insufficient evidence can be searched by model name or repository, or linked manually after compatibility confirmation. Only supported GGUF vision projectors can be attached from this screen. Other helpers are identified and listed for comparison.
- Tests cover renamed projectors and adapters, general base-model associations, checksum matching, ambiguous files, and the genuine BF16 artifact. Physical Android import and pairing remain to be checked. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/41)
- A live SmolVLM projector check verifies the projector's published bytes and its finished model identity. Projector matching ignores training datasets and distinguishes the finished vision model from its language and vision components. [Composite projector follow-up](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/43)

## Online images, Android updates and navigation

- **Models → Images** explains the internet requirement and stores the optional Pollinations key in secure storage. Chat asks for missing details, can refine the prompt with the selected language model, and uses Pollinations for image creation. Keyless creation uses the anonymous Sana endpoint. A configured key enables selection from advertised free models. Edits require a source image, a key and a free editor that accepts images.
- Local image generation downloads and loading are retired. Vision helpers for understanding images remain a separate model capability.
- Android Back follows screen and tab history and asks before exiting the Home screen. The Models arrow jumps up and Back resets the Models list to the top. The Chat arrow jumps to the latest turn.
- Chat and voice call answers use the same selectable Markdown and math renderer. Named links, bare web addresses, and expanded source chips open in the browser. Voice playback and researched WAVs omit sources, URLs and citation numbers. If call playback stalls or produces silence, the app tries the system voice and keeps the response in the transcript. The call shows Speaking during audio playback and Preparing voice during synthesis.
- Android validates APK package, signer and version ahead of installation. GitHub APKs enable the updater. A persistent update signer can be configured through Actions settings. This GitHub integration cannot write repository secrets. Previously generated ephemeral signing keys cannot be recovered from the APK. [Signing setup](SECURITY.md#persistent-github-apk-updates)
- Android cluster workers can be restarted on another port. Pairing distinguishes refused connections, missing routes and timeouts. Two physical devices on the affected network still need verification. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/45)


## Tool discovery, shared folders and audio follow-ups

- Tool-enabled model turns can call `search_tools` using a task or capability. It lists up to three matching available tools with their argument schemas and asks the model to use the result. Blocked tools and capabilities that are unavailable are omitted. The small-context prompt includes the command when it fits.
- **Chat → Tools & permissions → Share a folder…** grants Android folder access through the system picker. The agent can list and read files, create and edit text files, append text, create subfolders, rename files and delete individual files. Changes ask by default. Android checks the saved write grant and relative path. Editing rejects binary and incomplete reads. The app's project workspace has its own files and revision history.
- Requests like “Create audio file talk about the importance of sports” draft the narration and call the built-in WAV tool. A request to turn the previous answer into speech uses that answer as input, omits sources and links the new WAV. A tool-name correction can resume a pending narration request. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/47)
- All 211 local Flutter tests passed. A live CPU smoke test with the published Qwen 3.5 0.8B Artemis GGUF verified that the model called `search_tools`, then `calculator`, and returned 133 for 19 × 7. The shared-folder tests verified tool approvals and Android channel arguments. The system picker and storage provider operations still need a physical Android test.

## Offline voice phonemes

- Sherpa-ONNX 2.x expects phoneme codepoints for English Kitten and Kokoro models. NeuroMesh initializes the bundled Piper phonemizer and supplies these codepoints to the model. Selected speakers keep their IDs. Kokoro multilingual input containing Chinese uses the available model lexicon.
- Host regression tests called the actual `text_to_speech` tool with the published Kitten Nano and Kokoro English archives. Both created WAVs with audible sample levels and plausible playback duration. To rerun, put the extracted voice folders under `NEUROMESH_TEST_VOICE_MODELS` and make the sherpa and Piper Linux native libraries available via `LD_LIBRARY_PATH`. Run `flutter test test/voice_model_synthesis_test.dart`. Android voice calls still need a device check. [Tracking issue](https://github.com/carlospeter582011-prog/neuromesh-ai/issues/49)
