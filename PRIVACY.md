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
- Optional features you turn on: a cloud provider with your own API key, model-selected web search (the search provider receives the tool query), Pollinations image creation and editing (the service receives the prompt and any image you approve for editing), the local API server (reachable on your local network only while you run it), and Phone cluster over your Wi-Fi. If you assign a worker phone, that phone receives the text, audio or image prompt needed for that workload over your local network.
- Opening a public GitHub issue draft with the description you write when you choose "Send feedback".
- When you tap "Send report", the app sends your description and diagnostic preview over HTTPS. The configured support relay delivers the report to the support team. The preview can include app version, device and memory information, model-load details, and recent app logs if you choose to include them.

## Permissions
- Microphone: voice calls and voice typing.
- Notifications and foreground service: long downloads and generation.
- Storage/Files: only through the system file picker when you import or export.

## What we collect
In builds configured with Firebase Crashlytics, crash and error diagnostics may be sent to Firebase, including app and device details, model context and recent error logs. Support report ZIPs exclude chat and model files.

## Children
The app is not directed at children under 13.

## Contact
Open an issue at https://github.com/carlospeter582011-prog/neuromesh-ai/issues
