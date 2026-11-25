# Physical Android verification

Record Android version, RAM, SoC, ABI, model file and checksum, runtime/backend, context size, app build, network type, pass/fail and a redacted log. Use at least two ARM64 phones with different RAM and performance profiles. Include a low-memory phone and one phone that supports the intended GPU backend.

1. Install the normal APK and Play-derived splits where signing permits. Launch after clean install and upgrade an existing same-signer installation. Check data migration, startup retry after unavailable storage, backgrounding, process death and permissions.
2. Load a known-small GGUF and a supported LiteRT model using CPU and hardware acceleration where available. Run text, vision and LiteRT audio where supported. Cancel before the first output and during streaming. Switch chats and resend immediately, then unload and switch models during a response. Check that previous output never appears in the replacement chat.
3. In each runtime, use short and long prompts, multiple languages, a cited factual query, an ambiguous request, calculations with large integers, an attachment transformation and malicious instructions quoted in a source or file. Exercise disabled tools, blocked permissions, a timed-out provider, partial sources and repeated searches.
4. Generate and save a Pollinations image, reopen it after restarting, test an expired key or HTTP 429, and cancel during generation. Try both anonymous generation and the configured-key edit path.
5. Generate a WAV with one default voice and one explicitly selected installed voice. Check waveform playback, labels, cancel/error states, and opening the attachment after restart. Remove the voice model and output file separately and verify recovery feedback.
6. Pair two phones over Wi-Fi using QR and manual entry. Reject malformed codes and duplicate workers. Start workers simultaneously and test occupied ports, foreground-service denial, process death, and repeated Off → Worker transitions.
7. Load a split model whose placement is independently confirmed from llama.cpp/RPC logs. Disconnect the worker before the first output and mid-stream. Kill worker and master processes separately. Reconnect with a different IP, move from Wi-Fi to a hotspot, and add latency and packet loss. Check partial-load recovery, unload during recovery and a user-cancelled recovery.
8. Repeat local and split benchmarks with the same prompt/settings and process cold/warm states. Record load time and first output and compare with logs. Use tokenizer IDs from the runtime for token rate, and Android memory instrumentation for process PSS. Verify backend selection, no stale result after cancellation, and recovery after an out-of-memory failure.
9. Exercise import/download/transfer with interrupted Wi-Fi, disappearing documents, permission revocation, full storage, and restart. Verify file integrity and retry. Validate model switches and persisted inference, voice, storage and cluster settings after abrupt process termination.

## Artemis 0.8B regression

- Use the same ARM64 phone and quantization from the original report if available. Load the GGUF at 512 and 1024 tokens, send `Hi` in a fresh Chat, and record the stage transitions and visible first output. Run with the matching BF16 Vision Helper loaded, with the helper disabled, and with a missing or mismatched helper.
- Send the same text prompt without an attachment and then send a real image question. Record projector initialization and image evaluation separately. Verify the text-only turn has no image-evaluation stage.
- Repeat with local model thinking enabled and disabled. Cancel while evaluating the prompt and during a tool call or approval dialog. Send another message immediately, then switch chats and repeat on a different model.
- Record actual input tokens, prompt evaluation, first visible chunk, final time, native decode rate, and cancellation time from the app log and Android logcat. Record any tool request that failed schema validation or selected the wrong tool.

## Direct Chat tools

- Unload the chat model, open the composer’s tool picker, and run Search with a non-English query. Confirm sources open, snippets are visible, the step expands, and the next draft defaults to Auto. Retry with no network and cancel a slow request.
- Choose Transcribe, attach a WAV with **+**, and send with the text field empty. Verify transcription with an installed Whisper model. Repeat with an Android-decoded audio format, a missing listening model, and an assigned speech worker. Check that cancelling leaves a cancelled step.
- Submit a formula in Calc, an image description in Image, and exact words in Speak. Check the saved traces and media. Block one tool in **Tools & permissions** and verify the same direct choice respects the block.
