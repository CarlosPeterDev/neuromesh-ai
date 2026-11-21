import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:get/get.dart';

import 'hive_service.dart';
import '../core/constants.dart';
import 'device_info_service.dart';
import 'app_log_service.dart';
import 'model_load_diagnostics.dart';
import 'cluster_service.dart';
import 'stop_sequence_filter.dart';
import '../utils/auto_context.dart';

// Conditionally import llama_flutter_android — only on Android
import 'inference_android.dart' if (dart.library.html) 'inference_stub.dart'
    as platform;

/// Cross-platform inference service.
/// - Android / iOS: uses llama_flutter_android for local GGUF models
/// - Android: uses flutter_litert_lm for LiteRT-LM models
/// - Web: cloud-only mode (local inference coming soon)
class InferenceService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  // ── Observable State ──
  final isModelLoaded = false.obs;
  final isGenerating = false.obs;
  final isLoadingModel = false.obs;
  final isVisionLoaded = false.obs;
  final loadingModelName = ''.obs;
  final loadedModelName = ''.obs;
  int get modelRevision => _modelRevision;
  int _modelRevision = 0;
  final tokenCount = 0.obs;
  final tokensPerSecond = 0.0.obs;
  final contextTokensUsed = 0.obs;
  final contextTokensTotal = 0.obs;
  final modelLoadProgress = 0.0.obs;
  final generationSource = ''.obs;
  final streamingText = ''.obs;
  final gpuName = ''.obs;
  final gpuLayersUsed = 0.obs;
  int _generationId = 0;

  /// Incremented whenever a generation is stopped early (by the user, a
  /// newer generation, or a disconnecting server client). Callers compare it
  /// before/after generate() to detect that their result was cut short.
  int get stopCount => _stopCount;
  int _stopCount = 0;
  final isGpuAccelerated = false.obs;
  final loadedModelRuntime = ''.obs;
  final supportsThinking = false.obs;
  final supportsToolSchema = false.obs;
  final loadedBackend = ''.obs;

  /// Whether the current platform supports local inference.
  bool get supportsLocalInference => platform.supportsLocalInference;

  // Platform-specific engine
  platform.InferenceEngine? _engine;
  String _sessionNativeRuntime = '';
  bool _unloadingModel = false;
  String? _loadedProjector;
  static final _clusterRetry = Object();

  String get sessionNativeRuntime => _sessionNativeRuntime;

  /// The loaded GGUF model has a working vision projector (images allowed).
  bool get ggufVisionLoaded => _engine?.ggufVisionLoaded ?? false;

  Future<String> loadModel(
    String modelPath, {
    String? modelName,
    String? modelRuntime,
    bool enableLiteRtVision = false,
    String? mmprojPath,
    ModelLoadDiagnostics? diagnostics,
    bool recoveringCluster = false,
    bool safeRetry = false,
  }) async {
    if (!supportsLocalInference) {
      return 'ERROR: Local inference is not available on this platform. Use Cloud mode.';
    }
    if (isLoadingModel.value || _unloadingModel) {
      return 'ERROR: Wait for the current model operation to finish.';
    }
    isLoadingModel.value = true;
    loadingModelName.value = modelName ?? modelPath.split('/').last;
    modelLoadProgress.value = 0.0;

    try {
      if (platform.isRunning32Bit) {
        final lower = modelPath.toLowerCase();
        if (_runtimeFor(modelPath, modelRuntime) == 'litert') {
          return 'ERROR: LiteRT models need 64-bit Android. This phone runs '
              '32-bit Android; use a small GGUF model (under 1.5 GB) instead.';
        }
        // A 32-bit process can't map a model this large next to everything else.
        if (lower.endsWith('.gguf') &&
            await _fileBytes(modelPath) > 1536 * 1024 * 1024) {
          return 'ERROR: This model is too large for 32-bit Android. Choose a '
              'GGUF model under 1.5 GB (for example a 1B Q4 model).';
        }
      }

      if (modelPath.toLowerCase().endsWith('.safetensors')) {
        return 'ERROR: Ask Chat to create the image online with Pollinations.';
      }

      final runtime = _runtimeFor(modelPath, modelRuntime);
      final isLiteRt = runtime == 'litert';
      final liteRtMode = _hive.getSetting<String>(
            AppConstants.keyLiteRtPerformanceMode,
            defaultValue: AppConstants.defaultLiteRtPerformanceMode,
          ) ??
          AppConstants.defaultLiteRtPerformanceMode;
      // The Performance setting alone decides: CPU safe never uses the GPU;
      // Auto fast and GPU fast always try it. A crash doesn't pause the GPU
      // for later loads (Auto fast still falls back to CPU if a GPU load
      // itself fails).
      final cpuOnly = safeRetry || liteRtMode == 'cpu_safe';
      final forceLiteRtCpu = isLiteRt && cpuOnly;
      final shouldTryLiteRtGpu = isLiteRt && !cpuOnly;
      final allowGgufGpu = !isLiteRt && !cpuOnly;
      await diagnostics?.checkpoint('release previous text engine');
      await _releaseEngine();

      _engine = platform.InferenceEngine();

      final contextSize = _hive.getSetting<int>(
            AppConstants.keyContextSize,
            defaultValue: AppConstants.defaultContextSize,
          ) ??
          AppConstants.defaultContextSize;

      var finalContextSize = safeRetry
          ? contextSize.clamp(512, 1024)
          : isLiteRt
              ? contextSize.clamp(512, 4096)
              : contextSize;
      final autoContext =
          _hive.getSetting<bool>('auto_context', defaultValue: true) == true;
      final lastLoadedContext =
          _hive.getSetting<int>('last_loaded_context_size') ?? 0;
      final contextChanged = isLiteRt && lastLoadedContext != finalContextSize;

      diagnostics
        ?..set('contextActual', finalContextSize)
        ..set('performanceMode', liteRtMode)
        ..set('autoContextEnabled',
            _hive.getSetting<bool>('auto_context', defaultValue: true))
        ..set('deviceTier', _getDeviceTier());
      await diagnostics?.checkpoint(
        isLiteRt ? 'prepare LiteRT-LM' : 'prepare llama.cpp / phone cluster',
      );
      final deviceTier = _getDeviceTier();
      final isTensorSoC = _getIsTensorSoC();

      // Phone cluster: GGUF layers spread across worker phones. This phone
      // then runs its share on the CPU.
      var clusterWorkers = 0;
      if (!isLiteRt && Get.isRegistered<ClusterService>()) {
        final plan = await Get.find<ClusterService>().applyForNextLoad(
          modelPath,
          context: finalContextSize,
          autoContext: autoContext,
          safeRetry: safeRetry,
        );
        clusterWorkers = plan.workers;
        finalContextSize = plan.context;
      }
      // Single-device auto mode can only shrink the requested window.
      if (!isLiteRt &&
          clusterWorkers == 0 &&
          autoContext &&
          Get.isRegistered<DeviceInfoService>()) {
        try {
          final dev = Get.find<DeviceInfoService>();
          await dev.refreshMemoryInfo();
          final auto = autoContextSize(
            requested: finalContextSize,
            availableGb: dev.availableRamGB.value,
            modelBytes: await _fileBytes(modelPath),
          );
          if (auto < finalContextSize) {
            Get.find<AppLogService>().info(
              'Auto context: $finalContextSize -> $auto (available RAM ${dev.availableRamGB.value.toStringAsFixed(1)} GB)',
            );
            finalContextSize = auto;
          }
        } catch (_) {}
      }

      diagnostics?.set('contextActual', finalContextSize);

      final requestedModelName = modelName ?? modelPath.split('/').last;
      diagnostics?.set('clusterWorkers', clusterWorkers);
      final result = await _loadModelOnEngine(
        modelPath: modelPath,
        modelRuntime: modelRuntime,
        diagnostics: diagnostics,
        contextSize: finalContextSize,
        deviceTier: deviceTier,
        isTensorSoC: isTensorSoC,
        liteRtPerformanceMode: liteRtMode,
        forceLiteRtCpu: forceLiteRtCpu,
        clearLiteRtCache: contextChanged,
        tryLiteRtGpu: shouldTryLiteRtGpu,
        enableLiteRtVision: enableLiteRtVision,
        allowGgufGpu: allowGgufGpu && clusterWorkers == 0,
        mmprojPath: mmprojPath,
      );

      if (!result.success) {
        diagnostics
          ?..set('engineBackend',
              result.backend.isEmpty ? 'unknown' : result.backend)
          ..set('progressPercent', (modelLoadProgress.value * 100).round());
        await _releaseEngine();
        return result.message;
      }

      modelLoadProgress.value = 1.0;
      _loadedProjector = mmprojPath;
      _modelRevision++;
      loadedModelName.value = requestedModelName;
      loadedModelRuntime.value = result.runtime;
      supportsThinking.value = result.supportsThinking;
      supportsToolSchema.value = result.supportsToolSchema;
      if (result.runtime == 'llama' || result.runtime == 'litert') {
        _sessionNativeRuntime = result.runtime;
      }
      loadedBackend.value = result.backend;
      gpuName.value = result.gpuName;
      gpuLayersUsed.value = result.gpuLayers;
      isGpuAccelerated.value = result.backend == 'gpu' || result.gpuLayers > 0;
      contextTokensUsed.value = 0;
      contextTokensTotal.value = finalContextSize;

      // Settings or split statistics can fail after a usable model has loaded.
      // Keep the engine available in that case.
      try {
        await _hive.setSetting(AppConstants.keyLocalModelPath, modelPath);
        await _hive.setSetting(
          AppConstants.keyLocalModelName,
          loadedModelName.value,
        );
        await _hive.setSetting(
          AppConstants.keyLocalModelRuntime,
          loadedModelRuntime.value,
        );
        await _hive.setSetting(
          AppConstants.keyLocalModelBackend,
          loadedBackend.value,
        );
        if (isLiteRt) {
          await _hive.setSetting('last_loaded_context_size', finalContextSize);
        }
      } catch (error) {
        Get.find<AppLogService>().warning(
          'Could not save active model settings',
          details: diagnosticText('$error'),
        );
      }

      isModelLoaded.value = true;
      if (clusterWorkers > 0) {
        try {
          final cluster = Get.find<ClusterService>();
          await cluster.refreshSplit(modelPath);
          return "Model loaded across ${cluster.splitSummary ?? '${clusterWorkers + 1} phones'}.";
        } catch (error) {
          Get.find<AppLogService>().warning(
            'Could not read the cluster split',
            details: diagnosticText('$error'),
          );
        }
      }
      return result.message;
    } catch (error) {
      await _releaseEngine();
      final detail = diagnosticText('$error');
      Get.find<AppLogService>().error(
        'Failed to load local model',
        details: detail,
      );
      return 'ERROR: Failed to load model — $detail';
    } finally {
      isLoadingModel.value = false;
      loadingModelName.value = '';
      if (!isModelLoaded.value) modelLoadProgress.value = 0.0;
    }
  }

  Future<void> unloadModel() async {
    if (isLoadingModel.value || _unloadingModel) return;
    _unloadingModel = true;
    try {
      await _releaseEngine();
    } finally {
      _unloadingModel = false;
    }
  }

  Future<void> _releaseEngine() async {
    final engine = _engine;
    _engine = null;
    isModelLoaded.value = false;
    isVisionLoaded.value = false;
    _loadedProjector = null;
    loadedModelName.value = '';
    loadedModelRuntime.value = '';
    supportsThinking.value = false;
    supportsToolSchema.value = false;
    loadedBackend.value = '';
    gpuLayersUsed.value = 0;
    isGpuAccelerated.value = false;
    gpuName.value = '';
    contextTokensUsed.value = 0;
    contextTokensTotal.value = 0;
    _sessionNativeRuntime = '';
    if (Get.isRegistered<ClusterService>()) {
      Get.find<ClusterService>().clearSplit();
    }
    if (engine != null) {
      // dispose() stops native inference; invalidate Dart callbacks first.
      await stopGeneration();
      try {
        await engine.dispose();
      } catch (error) {
        Get.find<AppLogService>().warning(
          'Could not release inference engine',
          details: diagnosticText('$error'),
        );
      }
    }
  }

  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    void Function(String token)? onToken,
  }) async {
    final engine = _engine;
    if (!supportsLocalInference || engine == null || !isModelLoaded.value) {
      return 'ERROR: No model loaded. Go to Models tab to download and load one.';
    }

    if (isGenerating.value) {
      // Wait for previous generation
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!isGenerating.value) break;
      }
      if (isGenerating.value) {
        await stopGeneration();
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    if (!identical(engine, _engine) || !isModelLoaded.value) {
      return 'ERROR: The active model changed while waiting to generate.';
    }

    // Identifies this generation so a stopped one that finishes late can't
    // reset the state of the generation that replaced it.
    final generationId = ++_generationId;
    bool isCurrent() => generationId == _generationId;

    isGenerating.value = true;
    tokenCount.value = 0;
    tokensPerSecond.value = 0.0;
    generationSource.value = source;
    streamingText.value = '';

    final startTime = DateTime.now();
    DateTime? firstVisibleTokenAt;
    Timer? tokenFlushTimer;
    final tokenFlushBuffer = StringBuffer();

    void flushTokenBuffer() {
      if (tokenFlushBuffer.isEmpty) return;
      final text = tokenFlushBuffer.toString();
      tokenFlushBuffer.clear();
      onToken?.call(text);
    }

    final stopFilter = StopSequenceFilter(stopSequences);
    var stopSequenceHit = false;

    Future<String?> recoverCluster() async {
      if (Zone.current[_clusterRetry] == true ||
          !isCurrent() ||
          firstVisibleTokenAt != null ||
          !Get.isRegistered<ClusterService>()) return null;
      final cluster = Get.find<ClusterService>();
      final path = _hive.getSetting<String>(AppConstants.keyLocalModelPath);
      if (path == null ||
          !await cluster.activeWorkerDisconnected() ||
          !isCurrent()) {
        return null;
      }
      final name = loadedModelName.value;
      final projector = _loadedProjector;
      // Releasing the current engine invalidates this generation once.
      final expectedStops = stopCount + 1;
      Get.find<AppLogService>()
          .warning('Cluster worker disconnected; attempting to reload model');
      final loaded = await loadModel(path,
          modelName: name, mmprojPath: projector, recoveringCluster: true);
      if (loaded.startsWith('ERROR:')) {
        return 'ERROR: A cluster worker disconnected and this model could not be reloaded. $loaded';
      }
      if (stopCount != expectedStops || isGenerating.value) return null;
      return runZoned(
        () => generate(
          prompt: prompt,
          systemPrompt: systemPrompt,
          conversationHistory: conversationHistory,
          source: source,
          imagePath: imagePath,
          audioPath: audioPath,
          maxTokens: maxTokens,
          stopSequences: stopSequences,
          onToken: onToken,
        ),
        zoneValues: {_clusterRetry: true},
      );
    }

    final visionAttempt = imagePath == null
        ? null
        : <String, Object>{
            'startedUtc': startTime.toUtc().toIso8601String(),
            'model': loadedModelName.value,
            'context': contextTokensTotal.value,
            'stage': 'Reading image',
          };
    Future<void> recordVision(String stage) async {
      if (visionAttempt == null || !isCurrent()) return;
      try {
        await _hive.setSetting('last_vision_attempt', {
          ...visionAttempt,
          'stage': stage,
          'elapsedMs': DateTime.now().difference(startTime).inMilliseconds,
        });
      } catch (_) {
        // Diagnostics must not prevent inference on a full disk.
      }
    }

    try {
      if (visionAttempt != null) {
        await recordVision('Preparing image and waiting for first token');
      }
      if (!isCurrent()) return '';
      final temperature = _hive.getSetting<double>(
            AppConstants.keyTemperature,
            defaultValue: AppConstants.defaultTemperature,
          ) ??
          AppConstants.defaultTemperature;

      final settingMaxTokens = _hive.getSetting<int>(
            AppConstants.keyMaxTokens,
            defaultValue: AppConstants.defaultMaxTokens,
          ) ??
          AppConstants.defaultMaxTokens;
      final effectiveMaxTokens = (maxTokens != null && maxTokens > 0)
          ? (maxTokens < settingMaxTokens ? maxTokens : settingMaxTokens)
          : settingMaxTokens;

      final result = await engine.generate(
        prompt: prompt,
        conversationHistory: conversationHistory,
        systemPrompt: systemPrompt ?? AppConstants.systemPrompt,
        modelName: loadedModelName.value,
        maxTokens: effectiveMaxTokens,
        temperature: temperature,
        imagePath: imagePath,
        audioPath: audioPath,
        source: source,
        normalThinking: source == 'chat' &&
            (_hive.getSetting<bool>('local_normal_thinking') ?? false),
        onToken: (rawToken) {
          if (!isCurrent()) return;
          var token = rawToken;
          if (stopFilter.isActive) {
            token = stopFilter.add(rawToken);
            if (stopFilter.stopped && !stopSequenceHit) {
              stopSequenceHit = true;
              // Halt the engine directly: this is a normal finish, not a
              // user/server interruption, so stopCount must not change.
              unawaited(
                _engine?.stop().catchError((_) {}) ?? Future<void>.value(),
              );
            }
            if (token.isEmpty) return;
          }
          firstVisibleTokenAt ??= DateTime.now();
          tokenCount.value++;
          streamingText.value += token;
          final speedStart = firstVisibleTokenAt ?? startTime;
          final elapsedSeconds =
              DateTime.now().difference(speedStart).inMilliseconds / 1000.0;
          if (elapsedSeconds > 0) {
            tokensPerSecond.value = tokenCount.value / elapsedSeconds;
          }
          if (loadedModelRuntime.value == 'litert') {
            tokenFlushBuffer.write(token);
            tokenFlushTimer ??= Timer(const Duration(milliseconds: 60), () {
              tokenFlushTimer = null;
              flushTokenBuffer();
            });
          } else {
            onToken?.call(token);
          }
        },
      );
      tokenFlushTimer?.cancel();
      if (!isCurrent()) return result;
      if (visionAttempt != null) {
        await recordVision(result.startsWith('ERROR:') || result.trim().isEmpty
            ? 'Image request did not complete'
            : 'Image reply completed');
        if (!isCurrent()) return result;
      }
      if (result.startsWith('ERROR:') || result.trim().isEmpty) {
        final recovered = await recoverCluster();
        if (recovered != null) return recovered;
        if (!isCurrent()) return result;
      }
      if (stopFilter.isActive) {
        final tail = stopFilter.flush();
        if (tail.isNotEmpty) {
          streamingText.value += tail;
          tokenFlushBuffer.write(tail);
        }
      }
      flushTokenBuffer();
      final finalText = stopSequenceHit ? stopFilter.text : result;

      await refreshContextInfo();
      if (isCurrent()) {
        isGenerating.value = false;
        generationSource.value = '';
      }

      // Detect Tensor SoC + Gemma Q4_K_M corruption: model outputs only
      // special tokens and terminates immediately with empty result.
      if (result.trim().isEmpty &&
          tokenCount.value < 5 &&
          loadedModelName.value.toLowerCase().contains('gemma')) {
        final isTensor = _getIsTensorSoC();
        if (isTensor) {
          return '⚠️ This Gemma model is incompatible with your Pixel\'s Google Tensor chip. '
              'The Q4_K_M quantization format has a known bug on Tensor SoC that produces empty responses.\n\n'
              'Try one of these fixes:\n'
              '1. Download a Q4_0 or Q5_K_M version of the same model\n'
              '2. Use a different model (Qwen, Phi, or Llama-3)\n'
              '3. Switch to Cloud mode in Settings';
        }
      }

      return finalText;
    } catch (e) {
      tokenFlushTimer?.cancel();
      if (visionAttempt != null) {
        await recordVision('Image request raised an inference error');
      }
      final recovered = await recoverCluster();
      if (recovered != null) return recovered;
      if (isCurrent()) {
        isGenerating.value = false;
        generationSource.value = '';
        streamingText.value = '';
        flushTokenBuffer();
      }
      Get.find<AppLogService>().error('Local generation failed', details: e);
      return 'ERROR: $e';
    }
  }

  Future<void> stopGeneration() async {
    _generationId++;
    _stopCount++;
    isGenerating.value = false;
    tokenCount.value = 0;
    generationSource.value = '';
    streamingText.value = '';
    final engine = _engine;
    if (engine != null) {
      unawaited(engine.stop().timeout(const Duration(seconds: 1)).catchError(
            (_) {},
          ));
    }
  }

  /// Reset the native conversation context. Call this whenever the user
  /// switches to a different chat session so old context doesn't leak.
  Future<void> resetConversation() async {
    final engine = _engine;
    if (engine != null) {
      await engine.resetConversation();
    }
  }

  Future<void> refreshContextInfo() async {
    if (!supportsLocalInference || _engine == null || !isModelLoaded.value) {
      return;
    }

    final info = await _engine!.getContextInfo();
    if (info == null) return;

    contextTokensUsed.value = info.tokensUsed;
    contextTokensTotal.value = info.contextSize;
  }

  String _getDeviceTier() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.deviceTier.value;
    } catch (_) {
      return 'mid';
    }
  }

  bool _getIsTensorSoC() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.isTensorSoC.value;
    } catch (_) {
      return false;
    }
  }

  Future<platform.LoadResult> _loadModelOnEngine({
    required String modelPath,
    required String? modelRuntime,
    required int contextSize,
    required String deviceTier,
    bool isTensorSoC = false,
    required String liteRtPerformanceMode,
    required bool forceLiteRtCpu,
    required bool clearLiteRtCache,
    required bool tryLiteRtGpu,
    required bool enableLiteRtVision,
    bool allowGgufGpu = false,
    String? mmprojPath,
    ModelLoadDiagnostics? diagnostics,
  }) async {
    // Auto fast: if a LiteRT GPU load fails, retry this load on the CPU.
    // Nothing is remembered — the next load tries the GPU again.
    final fallbackToCpu = tryLiteRtGpu && liteRtPerformanceMode == 'auto_fast';
    Future<platform.LoadResult> run({required bool cpuRetry}) async {
      try {
        if (cpuRetry) modelLoadProgress.value = 0.0;
        await diagnostics?.checkpoint(
          cpuRetry
              ? 'retry LiteRT-LM on CPU'
              : tryLiteRtGpu
                  ? 'initialize LiteRT-LM GPU backend'
                  : allowGgufGpu
                      ? 'initialize llama.cpp (GPU eligible)'
                      : 'initialize local backend',
        );
        return await _engine!.loadModel(
          modelPath: modelPath,
          modelRuntime: modelRuntime,
          contextSize: contextSize,
          deviceTier: deviceTier,
          isTensorSoC: isTensorSoC,
          liteRtPerformanceMode: liteRtPerformanceMode,
          forceLiteRtCpu: cpuRetry || forceLiteRtCpu,
          clearLiteRtCache: cpuRetry || clearLiteRtCache,
          enableLiteRtVision: enableLiteRtVision,
          allowGgufGpu: allowGgufGpu,
          mmprojPath: mmprojPath,
          onProgress: (progress) {
            final fraction = _normalizeProgress(progress);
            if (fraction > modelLoadProgress.value) {
              modelLoadProgress.value = fraction;
            }
          },
          onLoadStage: (stage, error) async {
            if (stage.startsWith('retry')) modelLoadProgress.value = 0;
            diagnostics?.set('firstBackendError', error);
            await diagnostics?.checkpoint(stage);
          },
        );
      } catch (error, stack) {
        diagnostics
          ?..set('engineExceptionType', error.runtimeType.toString())
          ..set('engineDartStack',
              stack.toString().split('\n').take(16).join('\n'));
        if (error is PlatformException) {
          diagnostics?.set('enginePlatformErrorCode', error.code);
        }
        return platform.LoadResult(
          success: false,
          message: 'ERROR: Failed to load model - ${diagnosticText('$error')}',
        );
      }
    }

    final result = await run(cpuRetry: false);
    if (result.success || !fallbackToCpu) return result;
    diagnostics?.set('firstBackendError', result.message);
    return run(cpuRetry: true);
  }

  Future<int> _fileBytes(String path) async {
    try {
      return await platform.fileLength(path);
    } catch (_) {
      return 0;
    }
  }

  double _normalizeProgress(double progress) {
    if (progress.isNaN || progress.isInfinite) return 0.0;
    final normalized = progress > 1 ? progress / 100 : progress;
    return normalized.clamp(0.0, 1.0).toDouble();
  }

  String _runtimeFor(String modelPath, String? modelRuntime) {
    final runtime = modelRuntime?.toLowerCase();
    if (runtime == 'litert' || runtime == 'llama') return runtime!;
    return modelPath.toLowerCase().endsWith('.litertlm') ? 'litert' : 'llama';
  }
}
