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
