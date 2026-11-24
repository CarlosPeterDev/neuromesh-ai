# Android GGUF generation correctness

The reported phone streamed punctuation, digits and a narrow range of letters at about 5.2 chunks/s for a short Qwen3.5 message. Streaming establishes that callbacks were running. It gives no evidence about the validity of the scores sent to the sampler. The report does not include the device, loaded backend, exact GGUF digest or runtime log.

## Raw baseline and subsystem isolation

The reference was upstream llama.cpp b12675, commit c212d25ad, on x86-64 CPU. The app comparison used the exact v1.0.204 JNI wrapper and its vendored llama.cpp built for the Linux host, followed by the updated wrapper. All three used the same published Artemis 0.8B Q4_K_M file. The vendored v1.0.204 source tree is `53531b53cfcf9bce63567a22331f154dfed1a71c` and reports ggml 0.25.1. The update keeps that engine and bounds its tensor-validation concurrency. The first run used a fresh 1,024-token context, two threads, temperature 0, seed 42 and neutral penalties. No template, memory, skills, grammar, tool catalog, attachments or Vision Helper participated in raw completion. [Reference runtime](https://github.com/ggml-org/llama.cpp/releases/tag/b12675) · [Model and helper](https://huggingface.co/turintech/Qwen3.5-0.8B-Artemis-GGUF)

- Model SHA-256 is `01e0651f0fc5d0f9a3d1a68166fbdf12ab4d3bb135b3d725d694f42becfaa5a4`. BF16 helper SHA-256 is `8fa5933772e64b56d96509b902b70119ce01fd21462f42d8fbb2c8acf0c354a5`.
- GGUF architecture is `qwen35`, file type 15 (Q4_K_M family), with 248,320 BPE tokens. The reference encoded the raw prompt `Hello, my name is` as `[9419, 11, 821, 803, 369]`. The vendored tokenizer emitted the identical raw and ChatML input IDs. Both wrappers counted five raw input tokens and generated a coherent continuation beginning `John.`. The updated wrapper diverged later in the long continuation. The raw comparison verifies tokenization length and language output across runtimes.
- ChatML with thinking disabled counted 13 input tokens and produced `Hello! How can I help you today?` in all three paths. The opening output token was 9419 in the reference, followed by punctuation token 0. End-of-generation token 248046 terminated the reply. The fixture declares no implicit BOS or EOS insertion. GGUF end-of-generation metadata controls native termination.
- Greedy, sampled, repeated-context, cleared-context, and helper-loaded text cases passed on the host. The matching helper identified a synthetic red image, and the next text turn matched the clean greeting. An equivalent Gemma 3 270M Q4_K_M test returned a natural greeting and stopped at EOG. Its vocabulary has 262,144 tokens and enables BOS insertion.
- A host JNI cancellation test interrupted each fixture after the first emitted chunk. Both logged `finish=cancelled` and generated the clean greeting on retry. Gemma reused nine of ten prompt tokens in an uninterrupted repeat. Artemis rebuilt its recurrent state on repeat. Neither reused prompt tokens after cancellation.
- A separate native host sequence progressively added the real system prompt, current tool catalog, synthetic memory, and selected skill and file excerpts. The prompts grew from 45 to 237, 258 and 333 input tokens respectively. Each produced the same coherent greeting. A deliberately selected calculator request produced the declared structured tool envelope. The native generation path in this test had no grammar constraints.

An additional reference run explicitly selected the software Vulkan device llvmpipe with all 25 layers offloaded. On the same fixture it encoded the same five raw and 13 ChatML input tokens, generated a coherent raw continuation and emitted the identical ChatML output token IDs as CPU. This verifies one Vulkan implementation. Device GPU drivers need separate coverage.

The host JNI logs reported these timings for one run of each wrapper. They exclude loading and are subject to host contention. The new readiness probe took 328 ms in this run. The decode window includes the sampling and output loop.

| Input | Input tokens | Output tokens | v1.0.204 prompt / decode | Updated prompt / decode |
| --- | ---: | ---: | ---: | ---: |
| Raw completion | 5 | 40 | 443 / 2,962 ms | 247 / 2,953 ms |
| ChatML greeting | 13 | 9 | 267 / 553 ms | 282 / 1,058 ms |
| Red-image question | 29 before image embeddings | 1 | 1,001 / 84 ms | 1,230 / 80 ms |

A separate interleaved host run alternated the wrappers in two process pairs, with six measured, cache-cleared greetings per process after a warm-up. Over 12 replies per build, v1.0.204 had a median of 435 ms prompt evaluation and 613 ms decoding. The updated wrapper had a median of 318 ms and 490 ms. The observed ranges overlapped for both phases. A repeat with callback timing measured a median of 430 ms to the first text chunk on v1.0.204 and 253 ms on the updated wrapper. These measurements characterize this host and do not establish a speed change on the reported phone.

## Reproduced failure mechanism

A fault-injection experiment returned an all-zero score vector through the same native logits API. With ordinary temperature and a 40-token top-k setting, the released wrapper streamed `(5B&*C*13.+>4G#&&GG8)7#9C&)#62@*G4,)G99@`. A uniform score row leaves the sampler choosing among tied token IDs and explains the character pattern without a UI or UTF-8 transformation. On the same fault, the updated wrapper rejected the model during readiness. Injecting it after readiness instead produced a native `invalid_logits` error with zero emitted tokens.

Real CPU runs on the exact v1.0.204 host port remained coherent. The phone's trigger remains unconfirmed. Upstream reports document similar invalid-logit output on some Android Vulkan drivers, including a Qwen3.5 0.8B multimodal case. The latter report distinguishes its image-prefill failure from its working text-only path. [Android Vulkan reports](https://github.com/ggml-org/llama.cpp/issues/16881) · [Qwen3.5 Mali report](https://github.com/ggml-org/llama.cpp/issues/26921)

## Changes and regression checks

- Android GGUF uses the standard CPU weight layout by default. Vulkan requires the explicit GPU Fast setting. GGUF validates stored tensor representations with bounded concurrency and probes a fresh context before reporting the model ready. A Vulkan readiness failure uses the existing CPU load fallback. Every generation checks raw logits and sampled token bounds, including after multimodal prefill. A backend error invalidates the affected context.
- A corrupted copy of the Gemma fixture with a NaN in an F32 weight failed during tensor validation. Its original bytes loaded and generated normally. Stored-tensor validation checks numerical representation. Source digests are still needed to establish file identity.
- JNI converts Java UTF-16 to standard UTF-8 before counting or encoding prompts, including supplementary characters. The vendored and reference tokenizers agreed on the emoji-containing prompt. The released wrapper's modified UTF-8 conversion changed that prompt's token IDs. Native output carries split UTF-8 sequences across token boundaries and retries token pieces that exceed the small buffer. GGUF output passes through to the UI without the previous Gemma-specific token filtering.
- Native sampling follows the reference filter order and uses one terminal sampler. Greedy and Mirostat no longer feed a second distribution sampler. The model's own vocabulary and EOG tokens drive token decoding and completion. The CPU policy, tensor checks, numerical checks and Unicode transport work independently of the model's filename.
- Native logs identify architecture, GGUF file type, ggml version and build, selected backend, offloaded layers, context size, thread count, vocabulary and special-token metadata, readiness results and why decoding ended. New numerical records contain no user prompt or generated content.
- The Android workflow compiles the native guard and Unicode regression tests and builds x86-64 llama.cpp into the universal package. The package gate extracts the exact JNI libraries from that APK and runs raw completion, ChatML, seeded sampling, cache reset and reuse, a loaded helper and real image processing inside Android. Emulator install and launch checks still run. [Build and publication](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/45451632477)
- Flutter 3.38.9 analysis reported zero warnings and errors. All 204 fixture-backed Flutter tests passed. The prior cleanup removed Agent, Alpine/PRoot, MCP and OpenCode. Chat, media, models and clusters use the retained infrastructure. [Dependency ownership and retained features](ANDROID_ADAPTIVE_INFERENCE.md)

## Android release evidence

GitHub Actions built and published **v1.0.205** from `65951eeb6f34ed1288ee7fe18e804465e782da9a` and verified it as Latest. The separately downloadable ARM64 and universal APKs use the persistent public test certificate and install as NeuroMesh AI Test. The development-signed AAB is 187,782,380 bytes, with an estimated 105.00 MB ARM64 split download. [GitHub Release](https://github.com/CarlosPeterDev/neuromesh-ai/releases/tag/v1.0.205) · [Android CI logs](https://github.com/CarlosPeterDev/neuromesh-ai/actions/runs/45451632477)

Android 12 x86-64 installed and upgraded the Test APK and launched the Play split alongside it. The native harness used the exact libraries extracted from the universal APK. It completed raw text, produced `Hello! How can I help you today?` in greedy and sampled ChatML cases, repeated the greeting with the helper loaded, identified the red fixture, and returned to a clean text turn. Production signing and physical ARM64 inference are outside this emulator evidence.

All three packages passed their published SHA-256 and archive integrity checks after downloading. The packages contain the expected ARM64 libraries, and the universal APK and AAB also contain the x86-64 llama JNI library. None contains the four removed Alpine/PRoot libraries. [Published checksums](https://github.com/CarlosPeterDev/neuromesh-ai/releases/download/v1.0.205/SHA256SUMS.txt)

## Original phone verification

Record the exact model and helper SHA-256, Android version and SoC, backend and offloaded-layer counts, context size, model format and the `LlamaJNI` readiness and finish lines. Use the released build and run text-only with the helper absent, text-only with it loaded, then a real image. Repeat on the standard CPU path and on the original backend if different. Capture the prompt evaluation and first output timing, then repeat after cancellation and a chat switch. These checks need the original phone or an equivalent device. [Android device matrix](ANDROID_DEVICE_TESTS.md)
