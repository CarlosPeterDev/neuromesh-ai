# Android Chat inference and dependency audit

Baseline is main at a0cfa75 (v1.0.201). [Android package and release run](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/45234270165).

| Former component | Consumers and ownership | Implementation plan |
| --- | --- | --- |
| Agent loop, discovery and intent helpers | Chat and voice have a separate bounded loop. The old narration, image and attachment shortcuts still bypass it. | Route Chat through the bounded model protocol. Preserve computation, attachment pages, search, synthesis and Pollinations through explicit schemas. |
| Agent workspace | Chat attachments and generated media, project switcher, context mentions, API file endpoints and cluster backups share it. | Keep the paths, existing message metadata, file limits and project boundaries. |
| Agent memory | Manual memory UI, inferred memory, Chat system prompt and cluster backup. | Keep stored notes and the shared memory service. Drop phrase-based memory actions and unused controls. |
| Agent tool permissions | Shell, MCP and shared-folder permissions are obsolete. Network image upload and active Chat tools still have a user-facing approval path. | Remove obsolete permission surfaces and keep settings for the active catalog. |
| Linux/PRoot | Setup installs Alpine for the prior Agent shell and its terminal. Release workflow injects four Termux libraries. The status bridge also serves audio, battery, network and native memory diagnostics. | Remove Alpine, shell and native library lookup. Keep retained bridge methods, desktop local inference and desktop platform diagnostics. |
| Android shared-folder automation | Agent-only SAF channel exposes file mutations. Model folder import in MainActivity has its own SAF flow. | Remove Agent-only tree grants and commands. Keep the model picker and app-scoped attachments. |
| MCP | Disabled connection flag, legacy runtime/client/OAuth settings and parsing tests. | Remove live code and configuration UI. Leave saved configuration on disk. |
| Scheduled prompts | Discontinued Agent jobs, no active registration. Android boot receiver and background services also serve retained image notifications. | Remove the prompt scheduler. Keep image notification lifecycle and infrastructure. |
| Desktop OpenCode | Discontinued standalone Agent hub and dedicated loopback binding. The normal OpenAI-compatible server supports unrelated Chat and media consumers. | Remove the preview and binding. Keep the normal HTTP server. |
| Python | Previously ran through Alpine or desktop shell and inherited their privileges. | Keep bounded arithmetic in Dart. This build has no isolated Python runtime. |

## Retained dependencies

- `ChatToolService` keeps the private workspace used by Chat, voice calls, context mentions, media viewers, project restore, and the OpenAI-style file and image endpoints. The app continues to recognize existing `nmfile:` links and workspace snapshots.
- `SkillsService` keeps explicit skill and attachment selection and the paged context tools. Its archive validation and YAML parser still serve skill imports. Document extraction and offline retrieval remain available.
- `MainActivity` keeps the model import and download channels. Android model-folder imports still use the system picker. `DeviceBridge` keeps audio decoding, device state, thermal status and shared-text intake. The camera, microphone, network and media permissions remain. The Agent-only folder channel, its `androidx.documentfile` dependency and broad all-files permission were removed.
- The boot receiver, notification plugin and background service still support image notifications. Removing scheduled Agent prompts removes the app's direct `timezone` dependency. The notification package can still include it transitively. The unused in-app browser package and its platform registrations were removed.
- Google Play uses the original application ID. Repository APKs use the persistent update signer when configured or the existing public Test identity. The Play release keeps the normal signing path. Desktop GGUF inference still uses the private loopback llama-server path.

## Investigation

The old Chat tool path asked for strict JSON on every pass, hid the entire stream, and retried a response that failed parsing. Android GGUF and LiteRT also treated a missing first token as failure after 60 seconds for text and 90 seconds for LiteRT media. These independent behaviors could leave the user with no answer despite model progress. A native method-channel failure could leave the Dart stream waiting, because the request future was discarded. The original phone's CPU/backend, memory state, load status, and Android log were unavailable.

The investigation reproduced the old response-format failure with the published Artemis 0.8B Q4_K_M GGUF. The model generated the text of a greeting inside an incomplete JSON object. Neither the format failure nor the host timings establish the sole cause of the reported Android hang. For text-only turns, the Android native code invokes the projector only when a media path is present. Loading the helper still adds memory pressure and model readiness time. [Artemis model and projector](https://huggingface.co/turintech/Qwen3.5-0.8B-Artemis-GGUF)

## Changes verified in source and automated tests

- Chat can display a plain reply on its first pass. It buffers incomplete tool envelopes and reasoning tags. A completed tool request has to use the negotiated format, name an allowed tool and pass argument validation.
- GGUF metadata identifies models that declare the ChatML function/parameter markup format. A cancellable idle check samples usable text and a single tool request and caches the observation by model identity and runtime configuration. The cloud adapter handles OpenAI-compatible function deltas on eligible providers and caches protocol rejections. Other Chat runtimes use the JSON envelope, with a shorter flat form for constrained contexts and a bounded format correction.
- Attachment retrieval stays scoped to the selected context. Existing Hive settings, chat metadata, tool-trace markers and workspace paths retain their serialized forms. Old Agent and MCP settings have no runtime consumer.
- Older turns can be omitted at complete-message boundaries. Android GGUF also checks the tokenized, formatted text prompt and keeps the system and newest user message intact. The Vision Helper accounts for image token positions in native code. LiteRT currently uses the Dart-side estimate because its Android API does not expose a tokenizer count.
- An early no-token watchdog records the evaluation phase. The runtime keeps its longer hard deadline and cancellation remains available. App logs give load and assembly timing, first output/chunk counts, pass and invalid-call counts, execution time, cancellation and total duration. Android native logs provide prompt evaluation timing, exact GGUF counts and sampled tokens. The added timing records contain no message text or reasoning.
- Invalid requests get one correction. Equivalent calls and repeated no-progress results are bounded. Tool results remain visible and can be expanded. Search and image transport close on cancellation. Speech workers receive the cancellation signal, and local synthesis observes cancellation between chunks.

## Host comparison

The real Artemis 0.8B Q4_K_M and matching BF16 projector ran under llama.cpp b12675 on x86-64 CPU, two threads, 1,024 context tokens, temperature 0 and seed 42. The measurement used the Android-style ChatML suffix with thinking disabled, the synthetic text `Hi`, no image, and no cached prompt tokens. The host was shared, so timings are single observations. First output is the first raw streamed chunk.

| Host prompt | Helper loaded | Input tokens | Prompt evaluation | First output | Output tokens / decode time | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Old JSON requirement | No | 245 | 5.65 s | 6.07 s | 17 / 1.99 s | Incomplete JSON, rejected by old Chat |
| Compact portable protocol | No | 136 | 2.51 s | 2.59 s | 10 / 1.01 s | Visible greeting |
| Declared GGUF tool protocol | No | 260 | 4.56 s | 4.60 s | 10 / 1.08 s | Visible greeting |
| Old JSON requirement | Yes | 245 | 3.27 s | 3.51 s | 17 / 1.29 s | Incomplete JSON, rejected by old Chat |
| Compact portable protocol | Yes | 136 | 1.73 s | 1.86 s | 10 / 0.71 s | Visible greeting |
| Declared GGUF tool protocol | Yes | 260 | 2.89 s | 2.94 s | 10 / 1.00 s | Visible greeting |

The genuine helper identified a synthetic red image correctly on the same host. The host server logged model ready at 2.06 s without the helper and 8.32 s with it. The compact portable prompt did not elicit a search or image call in initial Artemis samples. The declared markup prompt produced a valid calculator call and a valid web query in later samples. The first markup variant also chose an irrelevant speech tool for a weather request and used an invalid image style. The compact declared template still missed the image and speech requests in other host samples, and a separate semantic selection probe also chose the wrong tool for speech. The checks show why schema validity and correct tool selection need separate verification. [llama.cpp host runtime](https://github.com/ggml-org/llama.cpp/releases/tag/b12675)

## Chat through the real host engine

A separate Flutter integration check exercised `ChatController`, the repository's desktop inference adapter, actual model loading, the streamed reply and Hive persistence. Both apps received `Hi` with a 1,024-token context, temperature 0 and an output limit of 60. Baseline had zero streamed updates. Its final bubble contained the JSON example text `reply` and a verification notice.

| Host app revision | Helper loaded | Load | First visible reply | Saved assistant text |
| --- | --- | ---: | ---: | --- |
| `a0cfa75` | No | 2.22 s | No live reply, turn ended in 4.88 s | `reply` and verification notice |
| `ef8bbf1` | No | 2.16 s | 1.41 s | Hello! How can I help you today? |
| `a0cfa75` | Yes | 2.84 s | No live reply, turn ended in 5.89 s | `reply` and verification notice |
| `ef8bbf1` | Yes | 2.84 s | 1.74 s | Hello! How can I help you today? |

A separate host check cancelled while the stage was Evaluating prompt, left the original chat with only the user message, and streamed a greeting in a new chat. The host adapter follows the portable tool protocol. The declared GGUF prompt comparison above separately exercises the Android-style tool format. The original Android phone's timing and behavior remain to be measured.

## Android and retained feature coverage

Flutter coverage includes Chat and voice message persistence, attachment and project isolation, model/helper identification and imports, downloads, context limits, cluster discovery/pairing and recovery logic, provider failures, audio/image tool results, cancellation and old settings. The Flutter suite passed all 204 tests with the real Artemis projector and Kitten and Kokoro voice models. All three release-configuration tests passed. Static analysis found zero warnings or errors. Additional host checks obtained three live search results and a 47,395-byte anonymous Pollinations JPEG. Android packaging uses the existing release signers, a separate test install identity when needed, an emulator install/launch gate and independent APK/AAB release assets. [Package verification run](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/45401242438)

The Android 12 x86-64 emulator upgraded the persistent Test APK and launched it alongside an installation derived from the Play AAB. Both APKs passed signature checks, and the Play bundle passed manifest and size checks. The GitHub Latest endpoint returned `v1.0.204` at commit `ef8bbf1`. Downloads for all three packages match the release checksum manifest. Each contains the ARM64 llama runtime, and each package was checked for the removal of all four Alpine launcher libraries. The AAB uses development signing and measures 185.34 MB on disk and 104.99 MB for the ARM64 split download. [Latest release and individual installers](https://github.com/CarlosPeterDev/neuromesh-ai/releases/tag/v1.0.204)

The original ARM64 device test, Android GGUF and LiteRT inference under memory pressure, physical microphone/gallery permissions, two-phone RPC and cluster recovery, and long-session lifecycle tests require devices. LiteRT native function registration is inactive. The portable Chat tool protocol is the supported LiteRT route. [Physical Android verification](ANDROID_DEVICE_TESTS.md)
