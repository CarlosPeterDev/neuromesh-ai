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
Builds without production signing secrets are **development builds** and are labeled as pre-releases. They are not production-ready.

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
