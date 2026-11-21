# Architecture audit — 2026-11-21

Baseline: bc0acc8. Repository inventory and hashes recorded before edits in /workspace/repository-inventory.tsv. Flutter/GetX UI; Hive preferences/history; Kotlin method channels for SAF/device actions; bundled llama.cpp/JNI for Android GGUF; desktop llama-server; LiteRT; optional cloud providers and LAN cluster/relay workers.

## Traced faults

- ChatController.sendMessage → ImageRequest.parse / WebSearchService.shouldSearch / narration helpers selected and executed optional tools before the user request reached inference. Image preparation only improved a preselected image prompt. CloudService.sendMessage received no tool schemas.
- AgentService.runToolLoop had direct TTS/file branches, automatic research, keyword nudges, and a fallback that saved an ordinary model answer. wantsTools and _toolsFor used request keywords. This violated model-directed selection and lost compound tasks.
- AgentTool used prose parameter signatures without argument validation. callTool invoked raw handlers, bypassing availability and policy. Tool results were injected as user instructions without a clear untrusted envelope.
- Shared Folder is real SAF, not simulated. DeviceBridge.writeFile returned true after stream close without read-back verification. resolve(create) skipped the final parent directory, breaking nested writes. Tool results did not expose document URIs or a binary output export operation.
- VoiceService supports real local Sherpa WAV synthesis and worker placement. File synthesis lacked system TTS fallback and persisted-output read-back verification. Existing recording, playback and voice model paths must remain.
- Android generateChat uses ChatTemplateManager selected from filename; Qwen direct mode inserts a closed think block. It never applies GGUF Jinja metadata or enable_thinking. Bundled llama.cpp common/chat supports both. Reasoning behavior cannot be inferred from a filename or validated without a compatible model.
- HomeView adds an OpenCode AgentHub destination. Its adapter owns discovery, isolated profiles and a dedicated loopback lease. No dependency on this hub is required for local chat or clustering.
- Settings exposes PollinationsPanel under On-device performance. Legacy local diffusion services remain referenced by model-management/diagnostics/desktop packaging; removal must account for those consumers.
- Composer combines microphone/send into one control and leaves voice call in the app bar. Settings stores thinking, but there is no composer toggle in this baseline.
- Release workflow gates standalone APK/AAB and desktop jobs, checks digests and publishes individual assets. Last three public Actions runs succeeded; those are baseline evidence only, not evidence for these repairs.

## Verification policy

Mocked model/provider tests demonstrate orchestration only. SAF, Android TTS, embedded-template behavior, physical clustering and live Pollinations must be identified separately. No production release may be claimed until build/device checks pass.
