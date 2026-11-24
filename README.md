# NeuroMesh AI

**Connect Devices. Multiply Intelligence.**

NeuroMesh AI is a Flutter app for running language models on Android, Windows and Linux. It combines local GGUF inference, optional cloud providers, an OpenAI-compatible local server, and device clustering.

See [the development handoff](continue.md) for release status, verification results, and the next tasks.

## Features

- Local GGUF inference on Android (llama.cpp, CPU with optional GPU backends)
- Cloud providers (bring your own API key) alongside local models
- Device clustering over the local network (worker discovery, QR / manual pairing)
- Local OpenAI-compatible API server
- Document text extraction, public web search, and clickable links in assistant replies and voice transcripts
- Online image generation and editing through Pollinations
- Hugging Face search and download for GGUF models and helpers, with a queue and Wi-Fi-only option
- Voice calls with on-device listening and speaking, optional voice cloning (English) and a worker phone
- Model-directed Chat tools for web search, bounded arithmetic, attachments, image generation and text-to-speech
- Toolbox: roles, prompts, profiles, export/import, backup, compare, benchmark

## Install

Choose a GitHub APK for Android. The AAB is for Google Play distribution. Desktop packages are available in earlier releases. [Downloads](../../releases)

Standalone APKs can check for GitHub updates. The Play AAB disables the built-in updater.

In **Models**, filter **Main models** or **Helpers**. Open a model and choose **Find model helpers** to inspect its original repository. Downloaded vision helpers can be linked to a matching installed model. Reload the main model after the helper download completes. File-role detection uses names, and each helper shows its runtime and compatibility requirements.
GitHub preview APKs may use a temporary signing key. Android requires a matching signing certificate for an in-place update. [Signing setup](SECURITY.md#persistent-github-apk-updates)

## Chat tools and attachments

Ask Chat to create an image with Pollinations or enter a description in **Models → Images**. The Images panel works without a loaded chat model. Internet access is required. Keyless image generation uses Sana. To edit an uploaded image, add a Pollinations key under **Models → Images**. The app looks for a free editor compatible with the input image.

Ask for a narration by topic or ask Chat to turn its previous answer into a WAV file. Install a voice in **Models → Voice** or assign a compatible worker.

Chat replies can stream ordinary text. Models can request tools through a validated protocol. Tool steps show the work in progress and expand to show inputs and results. **Chat tools & permissions** controls approval for supported tools. Android uses the system picker for documents, media and model imports.


## Skills and context

Open **Settings → Skills** to create a skill or import `SKILL.md` / a ZIP containing one skill folder, including `references`, `scripts` and `assets`. The format follows [Agent Skills](https://agentskills.io/specification). Imports validate metadata, reject links and unsafe archive paths, and never run scripts automatically. Enable or disable each skill locally. Tap **@** in the chat composer to pick a skill or a current-workspace file, or type `@skill:code-review` / `@file:"docs/notes.md"`.

Selected attachment and skill documents are divided into pages that the model can retrieve with `read_context` and `search_context`. Chat saves attachments and generated media in its workspace. Long histories and optional excerpts are fitted to the active model context. [Inference and dependency audit](docs/ANDROID_ADAPTIVE_INFERENCE.md)


## Build

GitHub Actions runs analysis and tests on pull requests. Pushes to `main` and manual Android release runs build and verify the APKs and Play AAB. Each installer is a separate release asset with a checksum. For a local Android build, use Flutter 3.38.x, JDK 17, the Android SDK and NDK.

```bash
git submodule update --init --recursive
flutter pub get
flutter build apk --release
```

Release signing: see [`SECURITY.md`](SECURITY.md#release-signing).

## License

MIT — see [`LICENSE`](LICENSE). Bundled third-party components and their licenses are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
