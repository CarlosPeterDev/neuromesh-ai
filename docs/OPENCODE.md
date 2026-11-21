# OpenCode preview

## Android 2.0 Agent Hub

The APK and Play AAB keep normal local chat and model downloads available on first launch. They contain no OpenCode executable, Alpine filesystem, terminal emulator, PRoot launcher, or runtime delivery module. Android **Agents** connects to an existing authenticated OpenCode 1.19.6 server. NeuroMesh sends no installer commands, writes no server configuration, and performs no executable downloads. The independently managed host owns installation, updates, runtime storage, and terminal access.

1. On your OpenCode host, set `OPENCODE_SERVER_PASSWORD` and run `opencode serve --hostname 127.0.0.1 --port 4096`. The default username is `opencode`. Adjust the address and username in Agents if your host uses different values. A server on a different device requires a trusted HTTPS endpoint with no redirects.
2. Open **Agents → OpenCode** and enter the server address and credentials. The app requires authentication and checks the server version and connected providers. The app keeps the credentials in memory for the connection.
3. Select a model from the server. Open a saved session or start a new chat. Responses and tool status stream over the server API. Use **Stop** to ask the server to cancel a turn. New sessions default to denying tool use. **Allow workspace reads in new chats** opts into read-only access with a compatible model. Existing sessions follow their own server permissions, so review them on the host. Terminal remains the host's OpenCode terminal.
4. For a server already running separately on the same phone, load a model in NeuroMesh and use **Link loaded phone model**. Put the copied configuration into a separate OpenCode profile, set its `NEUROMESH_BRIDGE_KEY` in the server environment, and start or restart that OpenCode server. Select the NeuroMesh provider in Agents. The bridge binds to a device-only loopback address, expires when stopped, and serves the currently loaded model without redownloading anything. A server on a different device cannot use this loopback bridge. Physical device and cluster routing still need verification.

The app supports English and Arabic labels for the Android Agent Hub. It never removes or changes legacy runtime files, existing NeuroMesh models, settings, or OpenCode sessions. The Linux Toolbox is only available to legacy builds where its launcher is already present. [OpenCode server guide](https://opencode.ai/docs/server/) · [Pinned server API source](https://github.com/anomalyco/opencode/tree/v1.19.6/packages/opencode/src/server/routes/instance/httpapi) · [Play packaging assessment](PLAY_STORE.md)

## Desktop setup

On Linux, install [OpenCode v1.19.6](https://github.com/anomalyco/opencode/releases/tag/v1.19.6) and have Xfce Terminal or xterm available in a graphical desktop session. Load a local GGUF in **Models**, then open **Agents → Check installation → Connect model and open Terminal**. The Agent Hub shows the resolved executable, version, and selected model. Use **Disconnect model** to stop the bridge immediately, or close the terminal to end the session and remove its temporary files. Windows and macOS expose installation discovery for native executables. Terminal launch for those platforms remains pending.

The preview streams text replies in OpenCode's own terminal interface. It opens a temporary workspace, denies model tool calls, and uses a fresh OpenCode profile for each launch. Terminal history is temporary. Project access, OpenCode conversations in NeuroMesh Chat, integrated installation and updates, and external providers remain future work.

## Architecture

- The Flutter Agent Hub calls an `AgentAdapter`. The adapter owns executable discovery, version validation, terminal launch, and connection lifetime. It passes arguments directly to the operating system. The initial version gate is intentionally the exact CLI release tested.
- `OpenAiServerService.forAgentModel` uses an ephemeral IPv4 loopback port and a random bearer key passed in the child environment. It exposes `GET /v1/models` and `POST /v1/chat/completions`. It serves the selected loaded model, checks its load revision, and shares the existing inference path. A model reload requires reconnecting. This route carries text only and advertises tool calling as unavailable. Cluster inference is inherited when the loaded engine uses it. Multi-device operation through this bridge still needs a live test.
- The adapter sets OpenCode's documented `OPENCODE_CONFIG_CONTENT` override and points XDG paths into a temporary directory. It supplies a local-only provider configuration and checks it with `opencode models neuromesh --pure` before opening the terminal. OpenCode's Linux managed configuration has higher precedence, so the adapter stops when it detects a managed config file. The adapter writes its session data inside the temporary profile, so disconnect serves as rollback. Disconnect revokes access and the terminal's exit removes the profile.
- Model requests are sent to NeuroMesh on the same machine. The adapter disables OpenCode model catalog refresh, autoupdates, and session sharing. OpenCode may perform its own dependency initialization. This profile does not provide operating-system network or process isolation.
- A future Chat adapter should use the agent's documented session API and run permissions through the native approval UI. Enable coding tools only after testing structured tool calls, approvals, and cancellation against the specific model and runtime.

[OpenCode configuration order](https://opencode.ai/docs/config/) · [Custom providers](https://opencode.ai/docs/providers/#custom-provider) · [CLI environment settings](https://opencode.ai/docs/cli/#environment-variables)

## Upstream and distribution audit

| Reference | Relevant findings |
| --- | --- |
| [PrivateLM at `8a5f3b0`](https://github.com/orailnoor/cross-platform-llm-client/tree/8a5f3b0c0ca8c2108b76ac9619fe5faf6a6a098e) | MIT Flutter upstream. Local inference and phone clustering inform the existing NeuroMesh architecture. Extend NeuroMesh's own runtime and release workflow. |
| [OpenCode v1.19.6](https://github.com/anomalyco/opencode/tree/v1.19.6) | MIT CLI. Its provider configuration takes an OpenAI-compatible endpoint. This milestone calls an existing user-installed CLI and adds no third-party source, binaries, or package dependencies to NeuroMesh. |
| [OpenCode Mobile at `13ec57a9`](https://github.com/Eslamasabry/opencode-mobile-next/tree/13ec57a919d54c9463df79159dc57e2819b1e547) | MIT app. It uses a native ARM64 phone engine, Linux installation, and remote connections. Its bundled terminal emulator and Rust runtime have separate notices. Its documented Android distribution is independently installed. |
| [AndCode at `244a7e0`](https://github.com/yuga-hashimoto/and-code/tree/244a7e0) | MIT app with separately licensed PRoot and Termux-derived libraries, optional rootfs installation, and approval workflows. Its notices identify GPL and LGPL requirements and corresponding-source gaps for specific builds. |
| [Codex](https://github.com/openai/codex/blob/main/LICENSE) and [Claude Code](https://code.claude.com/docs/en/legal-and-compliance) | Codex's repository uses Apache-2.0. Claude Code distribution is governed by Anthropic's terms. Audit the actual shipped artifact and its transitive notices before bundling either agent. |

Existing bundled dependencies include Apache-2.0 Sherpa ONNX, GPLv3 Piper Phonemize, and Syncfusion PDF under its community or commercial license. Native libraries, complete corresponding source, and commercial license eligibility require a distribution audit. The release workflow packages Android, Windows and Linux. macOS has a scaffold and still needs native packaging and verification.

## Verification

Run the Flutter suite for discovery, config validation and cleanup, authenticated loopback routing, streaming, disconnect, and existing local and cluster regression coverage. The opt-in `test/opencode_live_smoke_test.dart` needs a dedicated X11 display, `xdotool`, Xfce Terminal, OpenCode v1.19.6 on `PATH`, and the llama-server binary and libraries in a discovery location for the Flutter test executable. Set `NEUROMESH_TEST_OPENCODE_MODEL` to a verified GGUF to run the live test. The test types into a terminal window on that display.

A Debian 13 x86-64 run passed with Xfce Terminal on Xvfb, the official OpenCode v1.19.6 CLI, llama.cpp b12543, and the published [Artemis Q4_K_M model](https://huggingface.co/turintech/Qwen3.5-0.8B-Artemis-GGUF). The network namespace contained only loopback. The terminal prompt requested the word “seven” and the bridge streamed it from the real GGUF engine. The OpenCode, llama.cpp, and GGUF downloads matched their published SHA-256 digests.
