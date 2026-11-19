# NeuroMesh AI

**Connect Devices. Multiply Intelligence.**

NeuroMesh AI is an Android AI workspace for running language models privately on your own hardware. It combines on-device GGUF inference (llama.cpp), optional cloud providers, an OpenAI-compatible local server, and device clustering.

> Status: early base. This repository is a small foundation that will be extended step by step. See [`continue.md`](continue.md) for exactly what works, what is unverified, and what is next.

## What is in the base today

- Local GGUF inference on Android (llama.cpp, CPU with optional GPU backends)
- Cloud providers (bring your own API key) alongside local models
- Device clustering over the local network (worker discovery, QR / manual pairing)
- Local OpenAI-compatible API server
- Document text extraction, image generation plugin, background service
- Hugging Face search and download for chat (GGUF) and image models, with queue and Wi-Fi-only option
- Voice calls with on-device listening and speaking, optional voice cloning (English) and a worker phone
- Chat with your documents (offline keyword search), agent with memory and remote MCP tools
- Toolbox: roles, prompts, profiles, export/import, backup, compare, benchmark

Anything not listed here is not implemented yet.

## Install

Download the APK from the [Releases](../../releases) page.

The normal APK and AAB include the small ARM64 native Linux launcher. Alpine itself is an optional download from **Install Alpine Linux** in Chat tools or the terminal; it is not bundled with the app. The normal standalone APK uses the same Play build flags and restricted manifest as the AAB. Other Android ABIs can use chat features; the Alpine launcher currently requires ARM64. Store distribution of downloadable runtime packages still requires policy review.

In **Models**, filter **Main models** or **Helpers**. Open a model and choose **Find model helpers** to inspect its original repository. Downloaded vision helpers can be linked to a matching installed model. Reload the main model after the helper download completes. File-role detection uses names, and each helper shows its runtime and compatibility requirements.
Builds without production signing secrets are **development builds** and are labeled as pre-releases. They are not production-ready.

## Skills and context

Open **Settings → Skills** to create a skill or import `SKILL.md` / a ZIP containing one skill folder, including `references`, `scripts` and `assets`. The format follows [Agent Skills](https://agentskills.io/specification). Imports validate metadata, reject links and unsafe archive paths, and never run scripts automatically. Enable or disable each skill locally. Tap **@** in the chat composer to pick a skill or a current-workspace file, or type `@skill:code-review` / `@file:"docs/notes.md"`.

For local agent chat, relevant enabled skills are selected using BM25 keyword ranking over names and descriptions. Selected documents are divided into overlapping pages. `read_context`, `search_context` and `list_skill_files` load the next relevant resources; active pages are rebuilt in the system prompt on each tool turn, separately from history compaction. This is bounded retrieval, not a guarantee that a small model follows arbitrarily long instructions. The app preserves the current user request and reports a capacity error instead of silently cutting mandatory instructions. Cloud text chat receives selected excerpts; paged agent tools currently require local agent chat. Explicit skill mentions remain active within the current chat until the skill is disabled; new chats select independently. Skill tasks never become cross-chat user memories.

Agent activity appears as a compact row. Open it for a live tool list and tap a step for request/result details. These show actual tool activity, not hidden model reasoning.

## Build

Builds run in GitHub Actions (`.github/workflows/android-release.yml`) on every push to `main` or manual dispatch. Locally you need Flutter (stable), JDK 17, the Android SDK and NDK, then:

```bash
git submodule update --init --recursive
flutter pub get
flutter build apk --release
```

Release signing: see [`SECURITY.md`](SECURITY.md#release-signing).

## License

MIT — see [`LICENSE`](LICENSE). Bundled third-party components and their licenses are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
