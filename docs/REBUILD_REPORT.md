# NeuroMesh architecture repair — implementation and evidence

This is an implemented repair branch, **not a production-ready release**. Baseline: `bc0acc8`. The remaining Android device verification gaps below are material. No release was published.

1. **Root causes.** `ChatController` preselected web/image/TTS actions from words before inference. `AgentService` also had direct file/TTS shortcuts, automatic research, keyword nudges and plain-answer file saving. Cloud chat did not run the agent loop. Parameter signatures were prose without validation. Android chat formatting guessed from filenames instead of applying GGUF metadata. SAF writes lacked read-back verification and nested parent creation skipped its final component. Obsolete diffusion code remained after its downloader was disabled. The old microphone control became Send, and voice calling stayed outside the composer. See [pre-edit audit](ARCHITECTURE_REPAIR.md).

2. **Modified components.** Chat submission/history, the agent loop and tool dispatch, native/cloud inference transport, SAF Kotlin/Dart bridge, speech synthesis, provider image validation, composer/actions, navigation/settings/model UI, diagnostics, backup preferences, relay foreground-service setup, native dependencies, CI and tests. The complete changed-file inventory follows below. Working GGUF/LiteRT, model/helper management, speech recognition/playback and distributed text/voice code remain; physical distributed inference was not verified here.

3. **Removed OpenCode.** Deleted the hub page, desktop adapter/interface/stub/export, documentation and its dedicated tests. Removed its bottom navigation entry and guarded the four remaining tab indices. Removed the OpenCode-only authenticated model bridge from the API server and bridge-only tests; retained the normal local API server. No OpenCode installer/downloader was present in the checked-out baseline. Unmerged OpenCode PRs were not changed or closed.

4. **Removed obsolete image UI/runtime.** Removed the On-device performance Image generation destination and search entry. Removed local diffusion services/FFI/isolate, WebGPU test screen/asset, plugin/submodule, native/CoreML dependency, preferences/backup fields, dormant batch controls, obsolete progress notifications and desktop diffusion build stage. Models → Images retains the real Pollinations key configuration. Extracted the relay's shared foreground-service dependency into `relay_background_service.dart` so removing image notifications does not remove relay process support.

5. **Agent controller.** Each enabled chat turn reaches the LLM before optional tool execution. Local and cloud chat use the same bounded loop. The loop accepts direct answers or validated tagged calls; native Android GGUF, OpenAI-compatible, Google and Anthropic tool responses are normalized into that protocol. Android uses actual embedded-template tool metadata and llama.cpp common/chat parsers; other local backends retain the validated structured adapter. Google preserves opaque thought signatures across tool turns. Internal history markers prevent ordinary quoted tool examples from becoming executable native history. Model-authored plans, IDs/dependencies, up to eight calls per batch, structured untrusted results, progress traces, completed output links, step/model/total limits, safe read retries, cancellation and repeated-call stopping are implemented. Pending approval cannot start an action after cancellation or a superseding task. Tool-result JSON and its matching call remain intact during context fitting; context/inference failures preserve completed output links. Batches execute serially to avoid conflicting workspace mutations. Failed prerequisites prevent dependent execution. Malformed output gets at most two repair attempts. Tool timeouts can leave an already-started operation finishing; the controller explicitly reports that uncertainty and never retries mutations automatically.

6. **Registry.** Central metadata exposes identifiers, descriptions, JSON input/output schemas, permissions, availability, dependencies and execution handlers. Built-in legacy signatures are translated to JSON Schema; MCP keeps its actual input schema. Validation rejects missing/unknown fields and invalid JSON types before approvals or handlers. Unsupported schema assertions disable the tool instead of weakening validation. Workspace listings do not follow symlinks, and copy/archive outputs reject existing destinations. Android network status, refreshed persisted read/write shared-folder grants, registered services, installed voice models/system engine and image-edit credentials affect discovery. Execution rechecks the actual tool set and policy. The old raw HTTP `callTool` policy bypass is removed. Tools cover workspace/shared files, verified export/share, real WAV synthesis, online Pollinations images, web retrieval, memory, schedules and existing optional sandbox/MCP capabilities when available.

7. **Executed examples.** Deterministic integration tests scripted a model to create an astronomy text file, read that file into WAV synthesis, generate Moon/Saturn/Orion images with three distinct prompts, select web search and return all outputs. Workspace files, WAV decoding and PNG decoding were real; the model, synthesis samples, provider and web service were mocks. A separate mock-SAF test exported the actual text bytes and returned a document URI. Dependency-failure, denial, cancellation, invalid arguments, unavailable tools and limits were tested. These do not establish live compound-task planning quality. A separate real Qwen3 GGUF test selected a native calculator call, supplied validated arguments, consumed the actual arithmetic result through native tool roles/IDs, and produced a grounded final answer. A direct greeting produced no tool call. This narrow live test does not establish general small-model reliability. A real anonymous Pollinations request separately returned the included 768×768 JPEG. A live Qwen probe selected three distinct Moon/Saturn/Orion image calls without keyword routing. Executing those prompts through the actual provider service saved and SHA-verified Moon; Saturn/Orion were rejected with 429 and, on the next attempt, 503. No three-image live completion is claimed. Explicit short Retry-After limits now receive a bounded cancellable retry; 503 errors remain truthful failures.

8. **Think mode.** Android now uses bundled llama.cpp common/chat and the embedded GGUF Jinja template with `enable_thinking`; filename-selected Qwen direct formatting is removed. Native metadata reports thinking and tool-schema capabilities. Prefilled reasoning delimiters are surfaced for parsing, without inserting thought text. A real Qwen3-0.6B Q8_0 host test used the same GGUF in both modes: distinct prompts, correct answer in both, reasoning closed in enabled mode and absent in disabled mode. Model SHA-256: `9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031`. This does **not** verify the Android JNI/UI path, Qwen3.5 or PocketPal parity. Incompatible templates are not promised reasoning support. The toggle persists through SettingsController/Hive and shows a compatibility notice.

9. **Composer.** Think is inside the composer with bright active/subdued inactive states. Microphone remains separate and present with text. Empty input shows Voice Mode; text/attachments show Send in its place; generation shows Stop. The existing `adjustResize` behavior remains. Widget tests exercise 320×640, 640×320, 800×1200 and 1200×800 sizes, typing/clearing and independent controls. Real keyboards, device rotation and navigation require device checks.

10. **Tests actually run.** Flutter analysis completed with zero errors/warnings; informational lint findings remain. Full Flutter suite: **229 passed, 4 optional tests skipped**, including native transport, discovery expansion, cancellation during approval, context preservation, compound orchestration, files, composer and removal coverage. Python build-configuration checks: **3 passed**. Bundled `llama-common` host build passed. Real-GGUF thinking and native calculator round-trip inference passed. Android NDK ARM64 JNI syntax checking passed with nine deprecation warnings. The actual ARM64 common library also built with the application's global hidden-visibility flags, and all six checked JNI-required chat symbols were exported. Pollinations catalog/OpenAPI and anonymous generation were exercised live; the returned JPEG decoded at 768×768. The image test invocation passed six tests including this real response artifact; other responses were mocked. Logs are under [verification](verification/). Android integration tests are compiled by analysis but were **not executed**.

11. **Remaining issues/unverified work.** Actual Android SAF providers, revoked permissions, Android TTS engine output, audio playback, JNI thinking/native tools, phone/tablet keyboard behavior and physical clustering need device verification. Anonymous image generation is provider-rate-limited and sometimes returned 503 during the live multi-image probe; availability is external and not guaranteed. Image editing/key authentication and real cloud native transports were not live tested; their transport tests use mocks. Full live compound-task planning remains unverified. Small local models may emit invalid structured calls; validation and bounded repair stop actions safely but cannot guarantee planning quality. Android tests need a pre-granted test folder, installed offline TTS voice and compatible GGUF. SAF test folders are deliberately left empty rather than deleting a directory outside the file-only deletion API. Local Gradle exhausted the 8 GB workspace while transforming dependencies, so full packaging uses CI. No emulator/device is attached. These limitations prevent declaring the assignment fully verified or production ready.

12. **Build/release status.** Separate APK/AAB production, signatures, package smoke tests, individual Release assets, digest checks and Latest selection remain in the workflow. Removed only obsolete diffusion packaging. A real-GGUF host thinking/native-tool job gates publication. Preview run `44919250711` passed native-host and Linux/Windows packages but failed Android linking: global hidden visibility hid `llama-common` chat symbols. This follow-up overrides visibility for that library and links the shared C++ runtime; the ARM64 library/export check passed locally. A fresh full preview is required for the final commit. The local APK attempt failed on disk capacity; no local APK/AAB was produced. No production release, merge or Latest update was performed. Keep [draft PR #62](https://github.com/CarlosPeterDev/neuromesh-ai/pull/62) in draft until critical Android verification passes.

## Device check commands

Use a dedicated test installation. Obtain the SAF grant through the app's folder picker first; an arbitrary URI is not permission.

```sh
flutter test integration_test/android_capabilities_test.dart -d DEVICE \
  --dart-define=NEUROMESH_TEST_TREE_URI=content://YOUR_PREGRANTED_TEST_TREE \
  --dart-define=NEUROMESH_TEST_GGUF_PATH=/device/path/compatible-model.gguf
scripts/check_model_thinking.sh /host/path/compatible-model.gguf
```

## Changed-file inventory

```text
M	.github/workflows/android-release.yml
D	.gitmodules
M	README.md
M	THIRD_PARTY_NOTICES.md
M	android/app/src/main/kotlin/com/neuromesh/ai/DeviceBridge.kt
D	assets/webgpu_engine.html
D	docs/OPENCODE.md
M	ios/Podfile.lock
M	ios/Runner.xcodeproj/project.pbxproj
M	ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
M	ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved
M	ios/Runner/AppDelegate.swift
M	lib/controllers/chat_controller.dart
M	lib/controllers/home_controller.dart
M	lib/controllers/model_controller.dart
M	lib/controllers/settings_controller.dart
M	lib/core/constants.dart
D	lib/ffi/sd_ffi_bindings.dart
D	lib/ffi/sd_ffi_bindings_web.dart
M	lib/main.dart
D	lib/services/agent_adapter.dart
M	lib/services/agent_extra_tools.dart
M	lib/services/agent_service.dart
M	lib/services/agent_tools.dart
M	lib/services/cloud_service.dart
M	lib/services/cluster_backup.dart
M	lib/services/crash_reporting_service.dart
M	lib/services/diagnostics_service.dart
D	lib/services/image_generation_notification_service.dart
D	lib/services/image_generation_notification_service_native.dart
D	lib/services/image_generation_notification_service_web.dart
M	lib/services/inference_android.dart
M	lib/services/inference_service.dart
M	lib/services/inference_stub.dart
D	lib/services/local_image_service.dart
D	lib/services/local_image_service_native.dart
D	lib/services/local_image_service_web.dart
M	lib/services/openai_server_service_io.dart
D	lib/services/opencode_adapter.dart
D	lib/services/opencode_adapter_io.dart
D	lib/services/opencode_adapter_stub.dart
M	lib/services/pollinations_image_service.dart
M	lib/services/relay_service.dart
D	lib/services/sd_isolate_processor.dart
M	lib/services/user_files.dart
M	lib/services/voice_service.dart
D	lib/views/agent_hub_view.dart
M	lib/views/chat_tools.dart
M	lib/views/chat_view.dart
M	lib/views/home_view.dart
M	lib/views/model_view.dart
M	lib/views/settings_view.dart
M	lib/views/voice_views.dart
D	lib/views/web_image_gen_test_view.dart
M	lib/widgets/home_empty_state.dart
M	local_plugins/llama_flutter_android/android/CMakeLists.txt
M	local_plugins/llama_flutter_android/android/src/main/cpp/jni_wrapper.cpp
M	local_plugins/llama_flutter_android/android/src/main/kotlin/com/neuromesh/llama_flutter_android/LlamaFlutterAndroidPlugin.kt
D	local_plugins/sd_flutter_android/.gitignore
D	local_plugins/sd_flutter_android/.metadata
D	local_plugins/sd_flutter_android/CHANGELOG.md
D	local_plugins/sd_flutter_android/LICENSE
D	local_plugins/sd_flutter_android/README.md
D	local_plugins/sd_flutter_android/analysis_options.yaml
D	local_plugins/sd_flutter_android/android/.gitignore
D	local_plugins/sd_flutter_android/android/CMakeLists.txt
D	local_plugins/sd_flutter_android/android/build.gradle
D	local_plugins/sd_flutter_android/android/cmake/FindOpenCL.cmake
D	local_plugins/sd_flutter_android/android/cmake/FindVulkan.cmake
D	local_plugins/sd_flutter_android/android/settings.gradle
D	local_plugins/sd_flutter_android/android/src/main/AndroidManifest.xml
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_d3d10.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_d3d11.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_dx9_media_sharing.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_dx9_media_sharing_intel.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_egl.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_ext.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_ext_intel.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_function_types.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_gl.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_gl_ext.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_half.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_icd.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_layer.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_platform.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_va_api_media_sharing_intel.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/cl_version.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/opencl_headers/CL/opencl.h
D	local_plugins/sd_flutter_android/android/src/main/cpp/sd_jni_wrapper.cpp
D	local_plugins/sd_flutter_android/android/src/main/cpp/stable-diffusion.cpp
D	local_plugins/sd_flutter_android/android/src/main/jniLibs/arm64-v8a/libomp.so
D	local_plugins/sd_flutter_android/android/src/main/jniLibs/arm64-v8a/libsd_jni.so
D	local_plugins/sd_flutter_android/android/src/main/jniLibs/arm64-v8a/libsd_jni_opencl.so
D	local_plugins/sd_flutter_android/android/src/main/jniLibs/arm64-v8a/libsd_jni_vulkan.so
D	local_plugins/sd_flutter_android/android/src/main/kotlin/com/example/sd_flutter_android/SdFlutterAndroidPlugin.kt
D	local_plugins/sd_flutter_android/android/src/test/kotlin/com/example/sd_flutter_android/SdFlutterAndroidPluginTest.kt
D	local_plugins/sd_flutter_android/desktop/CMakeLists.txt
D	local_plugins/sd_flutter_android/desktop/smoke.cpp
D	local_plugins/sd_flutter_android/example/android/gradle/wrapper/gradle-wrapper.jar
D	local_plugins/sd_flutter_android/example/android/gradlew
D	local_plugins/sd_flutter_android/example/android/gradlew.bat
D	local_plugins/sd_flutter_android/ios/.gitignore
D	local_plugins/sd_flutter_android/ios/Assets/.gitkeep
D	local_plugins/sd_flutter_android/ios/Classes/SdFlutterAndroidPlugin.swift
D	local_plugins/sd_flutter_android/ios/Classes/SdIosWrapper.h
D	local_plugins/sd_flutter_android/ios/Classes/SdIosWrapper.mm
D	local_plugins/sd_flutter_android/ios/Resources/PrivacyInfo.xcprivacy
D	local_plugins/sd_flutter_android/ios/sd_flutter_android.podspec
D	local_plugins/sd_flutter_android/lib/sd_flutter_android.dart
D	local_plugins/sd_flutter_android/lib/sd_flutter_android_method_channel.dart
D	local_plugins/sd_flutter_android/lib/sd_flutter_android_platform_interface.dart
D	local_plugins/sd_flutter_android/pubspec.yaml
D	local_plugins/sd_flutter_android/scripts/build_gpu_backends_wsl.sh
D	local_plugins/sd_flutter_android/scripts/fix_ndk_symlinks.py
D	local_plugins/sd_flutter_android/test/sd_flutter_android_method_channel_test.dart
D	local_plugins/sd_flutter_android/test/sd_flutter_android_test.dart
M	pubspec.lock
M	pubspec.yaml
M	test/agent_test.dart
M	test/chat_submission_test.dart
M	test/memory_policy_test.dart
M	test/openai_server_service_test.dart
D	test/opencode_adapter_test.dart
D	test/opencode_live_smoke_test.dart
M	test/pollinations_image_service_test.dart
# Added files
docs/ARCHITECTURE_REPAIR.md
docs/verification/pollinations-live.jpg
integration_test/android_capabilities_test.dart
lib/services/relay_background_service.dart
lib/services/tool_registry.dart
lib/widgets/composer_actions.dart
local_plugins/llama_flutter_android/android/src/main/cpp/llama.cpp/vendor/cpp-httplib/CMakeLists.txt
local_plugins/llama_flutter_android/android/src/main/cpp/llama.cpp/vendor/cpp-httplib/LICENSE
local_plugins/llama_flutter_android/android/src/main/cpp/llama.cpp/vendor/cpp-httplib/httplib.h
scripts/check_model_thinking.sh
test/agent_integration_test.dart
test/architecture_removal_test.dart
test/composer_actions_test.dart
test/native_tool_transport_test.dart
tool/verify_model_thinking.cpp
local_plugins/llama_flutter_android/android/src/main/cpp/native_tool_protocol.h
```
