# Privacy Policy — NeuroMesh AI

_Last updated: 2026-11-18_

NeuroMesh AI runs language models on your device. This policy describes what the app does with your data.

## What stays on your device
- Chats, settings, prompts, documents you add, voice models and downloaded AI models are stored only on your device.
- Speech recognition and text-to-speech use models that run on your device. Audio from voice calls is processed locally and is not uploaded.
- Backups and exports are created only when you ask, and are shared only where you send them. API keys are excluded from backups.

## Network use
The app uses the network only when you ask it to:
- Searching and downloading models from Hugging Face (huggingface.co) and voice models from GitHub.
- Optional features you turn on: a cloud provider with your own API key, MCP servers you add, the agent's "fetch web page" tool (asks first unless you choose Always allow), the local API server (reachable on your local network only while you run it), and Phone cluster over your Wi-Fi.
- Opening a public GitHub issue draft with the description you write when you choose "Send feedback".
- When you choose "Report an error", you can review a diagnostic ZIP containing the app version, device type, available memory and storage, and recent model-load details. You can optionally add recent warnings and errors. Logs may contain personal text, so review the preview before sharing. When you choose "Share ZIP", the app hands the file to your system share sheet and you choose the recipient.

## Permissions
- Microphone: voice calls and voice typing.
- Notifications and foreground service: long downloads and generation.
- Storage/Files: only through the system file picker when you import or export.

## What we collect
In builds configured with Firebase Crashlytics, crash and error diagnostics may be sent to Firebase, including app and device details, model context and recent error logs. Exported reports are shared through the recipient you choose. The manual diagnostic ZIP excludes chat and model files.

## Children
The app is not directed at children under 13.

## Contact
Open an issue at https://github.com/carlospeter582011-prog/neuromesh-ai/issues
