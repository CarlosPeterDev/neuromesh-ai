import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../services/download_service.dart';
import '../services/installed_vision_helper.dart';
import '../utils/llama_archs.dart';
import '../utils/model_file_role.dart';
import '../utils/model_fit.dart';
import '../services/gguf_metadata.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';
import '../services/hive_service.dart';
import '../services/app_log_service.dart';
import '../services/device_info_service.dart';
import '../services/device_bridge.dart';
import '../services/model_load_diagnostics.dart';
import '../services/model_artifact_metadata.dart';
import '../services/model_helper_service.dart';
import '../views/diagnostics_view.dart';
import '../models/ai_model.dart';
import '../ffi/sd_ffi_bindings.dart';
import '../core/constants.dart';
import '../core/ui.dart';
import '../services/cluster_service.dart';
import 'settings_controller.dart';

enum _ModelLoadAction { cancel, unloadAndContinue, continueLoad }

/// A model file found by scanning a folder the user picked.
class FolderModelFile {
  final String uri;
  final String name;
  final int size;
  const FolderModelFile(
      {required this.uri, required this.name, required this.size});
}

class ModelController extends GetxController {
  final DownloadService _download = Get.find<DownloadService>();
  final LocalImageService _localImage = Get.find<LocalImageService>();
  final InferenceService _inference = Get.find<InferenceService>();
  final HiveService _hive = Get.find<HiveService>();
  final SettingsController _settings = Get.find<SettingsController>();

  static const _customModelsKey = 'custom_url_models';
  static const _androidImportChannel =
      MethodChannel('com.aichat.ai_chat/model_import');

  Map<String, DownloadProgress> get activeDownloads =>
      _download.activeDownloads;

  final availableModels = <AiModel>[].obs;
  final downloadedFiles = <String>[].obs;

  /// Vision projector (mmproj) files on disk. They're hidden from the model
  /// list but tell us whether a vision model can read images yet.
  final visionFiles = <String>{}.obs;
  final _installedVisionHelpers = InstalledVisionHelpers();
  final _artifactReader = ModelArtifactReader();
  final _artifacts = <String, ModelArtifact>{};
  final _visionSources = <String, AiModel>{};
  final isImporting = false.obs;
  final isPreparingModel = false.obs;
  final customModels = <AiModel>[].obs;
  final fileSizes = <String, int>{}.obs;
  final modelScope = 'local'.obs;
  final externalDownloadKind = Rxn<ModelFileKind>();
  final libraryFitFilter = Rxn<ModelFit>();
  final libraryKindFilter = Rxn<ModelFileKind>();
  final localFilter = ''.obs;
  final importFileName = ''.obs;
  final importStatus = ''.obs;
  final importCopiedBytes = 0.obs;
  final importTotalBytes = 0.obs;
  final importBytesPerSecond = 0.0.obs;
  final sortSmallestFirst = true.obs;
  final externalDownloadId = Rx<int?>(null);

  void toggleSort() {
    sortSmallestFirst.value = !sortSmallestFirst.value;
  }

  /// Apple Neural Engine (Core ML) models are only usable on Apple devices.
  static bool get supportsAppleNpu => Platform.isIOS || Platform.isMacOS;

  static const localFilters = [
    'general',
    'image',
    'uncensored',
    'vision',
    'npu'
  ];

  List<AiModel> get displayedModels {
    // Loading a model doesn't move it: the list keeps its normal order and
    // the loaded model is marked in place.
    final models = [...availableModels];
    models.sort((a, b) {
      final aDownloaded = isDownloaded(a.filename);
      final bDownloaded = isDownloaded(b.filename);
      if (aDownloaded != bDownloaded) return aDownloaded ? -1 : 1;

      if (sortSmallestFirst.value) {
        final aBytes = _knownModelBytes(a);
        final bBytes = _knownModelBytes(b);
        if (aBytes > 0 && bBytes > 0 && aBytes != bBytes) {
          return aBytes.compareTo(bBytes);
        }
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return models;
  }

  List<AiModel> get filteredDisplayedModels {
    final filter =
        localFilter.value.isEmpty ? defaultLocalFilter : localFilter.value;
    final filtered = displayedModels.where((model) {
      switch (filter) {
        case 'uncensored':
          return isUncensoredModel(model);
        case 'vision':
          return isVisionModel(model);
        case 'image':
          return isImageModel(model);
        case 'npu':
          return isNpuModel(model);
        case 'general':
        default:
          return isGeneralModel(model);
      }
    }).toList();
    // The filter's recommended pick goes first; the rest keep their order
    // (List.sort isn't stable, so partition instead).
    return [
      ...filtered.where((m) => m.recommendedFor.contains(filter)),
      ...filtered.where((m) => !m.recommendedFor.contains(filter)),
    ];
  }

  String get defaultLocalFilter => 'general';

  double get importProgress => importTotalBytes.value <= 0
      ? 0.0
      : (importCopiedBytes.value / importTotalBytes.value)
          .clamp(0.0, 1.0)
          .toDouble();

  int get downloadedCount => downloadedFiles.length;

  String get activeLocalModelName => _inference.loadedModelName.value;

  @override
  void onInit() {
    super.onInit();
    _loadCustomModels();
    availableModels.value = AppConstants.availableModels
        .map((m) => AiModel.fromMap(m))
        // Core ML (Apple NPU) models only run on iOS/macOS.
        .map(_withHelper)
        .where((m) => supportsAppleNpu || !isNpuModel(m))
        .toList()
      ..addAll(customModels.where((model) =>
          model.filename != AppConstants.artemisStarter['filename']));
    refreshDownloaded();
  }

  void _loadCustomModels() {
    final raw =
        _hive.getSetting<List>(_customModelsKey, defaultValue: []) ?? [];
    customModels.value = raw
        .whereType<Map>()
        .map((m) => AiModel.fromMap(Map<String, String>.from(m)))
        .toList();
  }

  Future<void> _saveCustomModels() async {
    await _hive.setSetting(
      _customModelsKey,
      customModels.map((m) => m.toMap()).toList(),
    );
  }

  Future<void> refreshDownloaded() async {
    await _deletePartialImports();
    final allFiles = await _download.getDownloadedModels();
    final files = allFiles;
    for (final file in files) {
      fileSizes[file] = await _download.getModelSize(file);
      if (!kIsWeb) {
        final artifact = await _artifactReader.read(await _download.modelPath(file));
        if (artifact == null) {
          _artifacts.remove(file);
        } else {
          _artifacts[file] = artifact;
        }
      }
    }
    _artifacts.removeWhere((file, _) => !files.contains(file));
    visionFiles
      ..clear()
      ..addAll(files.where(_isVisionProjectorFile));
    downloadedFiles.value = files;

    // Add any downloaded files that are not in availableModels
    final existingFilenames = availableModels.map((m) {
      if (m.filename.toLowerCase().endsWith('.zip')) {
        return m.filename.substring(0, m.filename.length - 4);
      }
      return m.filename;
    }).toSet();
    for (final file in files) {
      if (!existingFilenames.contains(file)) {
        // An imported copy of a catalogue vision model (any capitalisation,
        // e.g. the original Hugging Face name) keeps the catalogue's vision
        // file, so images work after one in-app download.
        final known = _catalogVisionMatch(file);
        if (known != null) {
          availableModels.add(known.copyWith(
            filename: file,
            url: '',
            size: _formatModelSize(file),
            description: 'Imported · can read images with its vision file',
            isImported: true,
          ));
          continue;
        }
        final lower = file.toLowerCase();
        final runtime = AiModel.runtimeFromFilename(file);
        final isLiteRt = runtime == AiModel.runtimeLiteRt;
        final isVision = isLiteRt && AiModel.hasVisionMarker(lower);

        availableModels.add(AiModel(
          name: file,
          filename: file,
          url: '',
          size: _formatModelSize(file),
          description: 'Imported from local storage',
          template: isLiteRt ? 'litert' : 'chatml',
          runtime: runtime,
          isImported: true,
          isVision: isVision,
        ));
      }
    }

    final helperPaths = {
      for (final helper in visionFiles) helper: await _download.modelPath(helper),
    };
    for (final model in availableModels.toList()) {
      if (!files.contains(model.filename)) continue;
      final described = model.copyWith(artifact: _artifacts[model.filename] ?? const ModelArtifact());
      final resolved = await _resolveVisionHelper(described, paths: helperPaths);
      final index = availableModels.indexWhere((m) => m.filename == model.filename);
      if (index >= 0 && identical(availableModels[index], model)) {
        availableModels[index] = resolved;
      }
    }

    // Remove any imported models that are no longer downloaded
    availableModels.removeWhere(
        (model) => model.isImported && !files.contains(model.filename));

    _visionSources.removeWhere((filename, _) => !files.contains(filename));

    if (localFilter.value.isEmpty) {
      localFilter.value = defaultLocalFilter;
    }
  }

  AiModel _withHelper(AiModel model) {
    final links = _hive.getSetting<Map>('model_helper_links');
    final link = links?[model.filename];
    if (link is! Map || link['filename'] is! String || link['url'] is! String) {
      return model;
    }
    return model.copyWith(
        mmprojFilename: link['filename'] as String,
        mmprojUrl: link['url'] as String,
        isVision: true);
  }

  Future<String?> installedFileFingerprint(String filename) async {
    if (kIsWeb || !isDownloaded(filename)) return null;
    return _installedVisionHelpers.fingerprint(await _download.modelPath(filename));
  }

  Future<VisionHelperSource?> identifyInstalledVisionHelper(
      String filename) async {
    if (kIsWeb ||
        !_isVisionProjectorFile(filename) ||
        !isDownloaded(filename)) return null;
    return _installedVisionHelpers.identify(await _download.modelPath(filename));
  }

  Future<AiModel> _resolveVisionHelper(AiModel model,
      {Map<String, String>? paths}) async {
    if (kIsWeb) return model;
    final source = _withHelper((_visionSources[model.filename] ?? model)
        .copyWith(artifact: _artifacts[model.filename] ?? const ModelArtifact()));
    final helpers = paths ?? {
      for (final file in (await _download.getDownloadedModels())
          .where(_isVisionProjectorFile))
        file: await _download.modelPath(file),
    };
    final match = await _installedVisionHelpers.find(source, helpers,
        matchesMetadata: (filename) => ModelHelperService.matchesBaseMetadata(
            source, _artifacts[filename]));
    if (match == null || match == source.mmprojFilename) return source;
    _visionSources.putIfAbsent(model.filename, () => source);
    return source.copyWith(mmprojFilename: match, mmprojUrl: '', isVision: true);
  }

  Future<void> attachVisionHelper(
      AiModel model, String filename, String url) async {
    if (!_isVisionProjectorFile(filename) ||
        model.fileRole.isHelper ||
        model.runtime != AiModel.runtimeLlama) {
      throw const FormatException('Choose a main GGUF model and a vision projector.');
    }
    final links = Map<dynamic, dynamic>.from(
        _hive.getSetting<Map>('model_helper_links') ?? {});
    links[model.filename] = {'filename': filename, 'url': url};
    await _hive.setSetting('model_helper_links', links);
    final index = availableModels.indexWhere((m) => m.filename == model.filename);
    if (index >= 0) {
      availableModels[index] = _withHelper(_visionSources[model.filename] ?? model);
    }
  }

  bool isDownloaded(String filename) {
    if (filename.toLowerCase().endsWith('.zip')) {
      return downloadedFiles
          .contains(filename.substring(0, filename.length - 4));
    }
    return downloadedFiles.contains(filename);
  }

  ModelFileRole fileRole(String filename) =>
      _artifacts[filename]?.role ?? modelFileRole(filename);

  bool _isVisionProjectorFile(String filename) =>
      fileRole(filename) == ModelFileRole.projector;

  /// Find the catalogue entry by filename, or by the exact Artemis family
  /// when a user has imported a different quantization.
  AiModel? _catalogVisionMatch(String file) {
    final lower = file.toLowerCase();
    for (final m in AppConstants.availableModels) {
      if ((m['mmproj_filename'] ?? '').isEmpty) continue;
      final urlName = Uri.tryParse(m['url'] ?? '')?.pathSegments.last ?? '';
      if ((m['filename'] ?? '').toLowerCase() == lower ||
          urlName.toLowerCase() == lower) {
        return AiModel.fromMap(m);
      }
    }
    final artemis = AiModel.fromMap(AppConstants.artemisStarter);
    if (lower.endsWith('.gguf') &&
        visionModelFamily(file) == visionModelFamily(artemis.filename)) {
      return artemis;
    }
    return null;
  }

  /// The model's vision file is on disk, so images can be used once loaded.
  bool isVisionFileReady(AiModel model) =>
      model.hasVisionProjector && visionFiles.contains(model.mmprojFilename);

  /// Size of a model's vision file from the catalogue ("986 MB"), if known.
  String visionFileSizeLabel(AiModel model) {
    for (final m in AppConstants.availableModels) {
      if (m['mmproj_filename'] != model.mmprojFilename) continue;
      final match = RegExp(r'\+\s*([\d.]+\s*(?:MB|GB))', caseSensitive: false)
          .firstMatch(m['size'] ?? '');
      return match?.group(1) ?? '';
    }
    return '';
  }

  /// Downloads just the vision file for a model that's already on disk.
  Future<void> downloadVisionFile(AiModel model) async {
    model = await _resolveVisionHelper(model);
    if (model.hasVisionProjector && model.mmprojUrl.isEmpty &&
        await _download.isModelDownloaded(model.mmprojFilename)) {
      await refreshDownloaded();
      return;
    }
    if (!model.hasVisionProjector || model.mmprojUrl.isEmpty) return;
    if (await _download.isModelDownloaded(model.mmprojFilename) ||
        isDownloadingModel(model.mmprojFilename)) return;
    await _downloadVisionFile(model);
  }

  bool _isAuxiliaryImageFile(String filename) {
    final lower = filename.toLowerCase();
    // GGUF vision projectors ride along with their model; never list or
    // load them as models of their own.
    if (lower.endsWith('.gguf') && lower.contains('mmproj')) return true;
    return lower == 'taesd.safetensors' ||
        lower.startsWith('taesd-') ||
        lower.startsWith('taesd_') ||
        lower == 'diffusion_pytorch_model.safetensors' ||
        lower.endsWith('.vae.safetensors') ||
        lower.startsWith('vae-') ||
        lower.startsWith('vae_');
  }

  bool _isIncompleteCatalogFile(AiModel model, int fileBytes) {
    if (model.url.trim().isEmpty || model.isImported || fileBytes <= 0) {
      return false;
    }
    final expectedBytes = _declaredModelBytes(model);
    if (expectedBytes <= 0) return false;
    // Relax threshold to 85% to comfortably accommodate HuggingFace decimal-scaled catalog sizes
    // and rounded metadata sizes (e.g. 770.3MB listed as 0.8GB) while still blocking failed downloads.
    return fileBytes < (expectedBytes * 0.85).round();
  }

  bool get isDownloading => _download.isDownloadingAny;

  String get lastLoadedModelName =>
      _hive.getSetting<String>(AppConstants.keyLocalModelName) ?? '';

  Future<void> reloadLastModel() => loadModel(
        lastLoadedModelName,
        includeHelpers:
            _hive.getSetting<bool>(AppConstants.keyLocalModelIncludesHelpers) ?? true,
      );

  bool get canLoadLastModel =>
      lastLoadedModelName.isNotEmpty && isDownloaded(lastLoadedModelName);

  DownloadProgress? getDownloadProgress(String filename) =>
      _download.activeDownloads[filename];

  bool isDownloadingModel(String filename) =>
      _download.activeDownloads.containsKey(filename);

  void setLocalFilter(String filter) {
    if (filter == 'npu' && !supportsAppleNpu) return;
    if (localFilters.contains(filter)) {
      localFilter.value = filter;
    }
  }

  /// Can read images: LiteRT vision models, or GGUF models that come with a
  /// vision projector (mmproj) file.
  bool isVisionModel(AiModel model) {
    if (model.hasVisionProjector) return true;
    if (!isLiteRtModel(model)) return false;
    final lower =
        '${model.name} ${model.filename} ${model.description}'.toLowerCase();
    return model.isVision || AiModel.hasVisionMarker(lower);
  }

  Future<void> downloadImageBundle(
      String name, List<({String url, String file, int size})> files) async {
    _showOnlineImageNotice();
  }

  void _showOnlineImageNotice() {
    showToast('Online image generation',
        'Create or edit images in Chat with Pollinations. Internet required.',
        tone: ToastTone.info);
  }

  bool isUncensoredModel(AiModel model) {
    return AppConstants.isUncensoredModelName(
      '${model.name} ${model.filename} ${model.description}',
    );
  }

  bool isImageModel(AiModel model) {
    final lower = model.filename.toLowerCase();
    return model.runtime == AiModel.runtimeSd ||
        lower.endsWith('.safetensors') ||
        lower.endsWith('.sdbundle') ||
        lower.endsWith('.coreml') ||
        lower.endsWith('.mlpackage') ||
        lower.endsWith('.mlmodelc') ||
        model.template == 'sd';
  }

  bool isLiteRtModel(AiModel model) {
    return model.runtime == AiModel.runtimeLiteRt ||
        model.filename.toLowerCase().endsWith('.litertlm');
  }

  bool isLlamaModel(AiModel model) {
    return model.runtime == AiModel.runtimeLlama ||
        model.filename.toLowerCase().endsWith('.gguf');
  }

  bool isGeneralModel(AiModel model) =>
      !isVisionModel(model) &&
      !isUncensoredModel(model) &&
      !isImageModel(model) &&
      !isNpuModel(model);

  bool isNpuModel(AiModel model) {
    final lower = model.filename.toLowerCase();
    return lower.endsWith('.mlmodelc') ||
        lower.endsWith('.mlpackage') ||
        lower.contains('coreml');
  }

  String modelSizeLabel(AiModel model) {
    final bytes = fileSizes[model.filename] ?? 0;
    if (bytes > 0) return DownloadService.formatBytes(bytes);
    return model.size;
  }

  /// Size in bytes of a model (downloaded file, or the catalogue size).
  int modelBytes(AiModel model) => _knownModelBytes(model);

  int _knownModelBytes(AiModel model) {
    final detected = fileSizes[model.filename] ?? 0;
    if (detected > 0) return detected;
    return _declaredModelBytes(model);
  }

  int _declaredModelBytes(AiModel model) {
    final match = RegExp(r'([\d.]+)\s*(GB|MB)', caseSensitive: false)
        .firstMatch(model.size);
    if (match == null) return 0;
    final value = double.tryParse(match.group(1) ?? '') ?? 0;
    final unit = (match.group(2) ?? '').toUpperCase();
    // Catalog sizes follow Hugging Face (decimal: 1 GB = 10^9 bytes).
    // Reading them as binary inflated every expectation by ~7% and flagged
    // complete downloads as incomplete.
    if (unit == 'GB') return (value * 1000 * 1000 * 1000).round();
    if (unit == 'MB') return (value * 1000 * 1000).round();
    return 0;
  }

  String _formatModelSize(String filename) {
    final bytes = fileSizes[filename] ?? 0;
    if (bytes <= 0) return 'Local File';
    return DownloadService.formatBytes(bytes);
  }

  Future<void> downloadModel(AiModel model) async {
    if (isImageModel(model)) {
      _showOnlineImageNotice();
      return;
    }
    if (externalDownloadId.value != null &&
        importFileName.value == model.filename) {
      showToast('Already downloading',
          'This model is downloading to your Downloads folder. Wait for it to finish first.',
          tone: ToastTone.warning);
      return;
    }
    try {
      if (Get.isRegistered<DeviceBridge>()) {
        final status = await Get.find<DeviceBridge>().status();
        final free = status['storageFree'];
        final bytes = _declaredModelBytes(model);
        if (free is num && free > 0 && bytes > 0 && bytes >= free) {
          showToast('Not enough storage',
              'This model needs about ${model.size}. Free up space and retry.',
              tone: ToastTone.warning);
          return;
        }
      }
      // Vision models need their projector too; fetch both together.
      if (model.hasVisionProjector &&
          model.mmprojUrl.isNotEmpty &&
          !await _download.isModelDownloaded(model.mmprojFilename) &&
          !_download.activeDownloads.containsKey(model.mmprojFilename)) {
        unawaited(downloadVisionFile(model));
      }
      if (huggingFaceRepository(model.url) != null &&
          !AppConstants.availableModels.any((m) => m['filename'] == model.filename)) {
        customModels.removeWhere((m) => m.filename == model.filename);
        customModels.add(model);
        await _saveCustomModels();
        availableModels.removeWhere((m) => m.filename == model.filename);
        availableModels.add(_withHelper(model));
      }
      await _download.downloadModel(
        url: model.url,
        filename: model.filename,
      );
      await refreshDownloaded();
    } catch (e) {
      Get.find<AppLogService>().error('Model download failed', details: e);
      showToast('Download Failed', '$e', tone: ToastTone.error);
    }
  }

  /// Copies a downloaded model (and its vision file, if any) from app
  /// storage to the phone's public Downloads folder.
  Future<void> saveToDownloads(AiModel model) async {
    final files = [
      model.filename,
      if (model.hasVisionProjector && isVisionFileReady(model))
        model.mmprojFilename,
    ];
    final saved = <String>[];
    for (final name in files) {
      if (activeDownloads.containsKey('save:$name')) continue;
      try {
        final path = await _download.modelPath(name);
        final result = await _androidImportChannel.invokeMethod<String>(
            'saveToDownloads', {'path': path, 'name': name});
        if (result != null) saved.add(result);
      } on PlatformException catch (e) {
        Get.find<AppLogService>().error('Save to Downloads failed', details: e);
        showToast('Not saved', e.message ?? 'Could not save $name.',
            tone: ToastTone.error);
        return;
      }
    }
    if (saved.isNotEmpty) {
      showToast(
        'Saved to Downloads',
        saved.length == 1
            ? '${saved.first} is in your Downloads folder.'
            : '${saved.length} files (model + vision file) are in your Downloads folder.',
        tone: ToastTone.success,
      );
    }
  }

  /// Background download of a GGUF vision model's projector file.
  Future<void> _downloadVisionFile(AiModel model) async {
    try {
      await _download.downloadModel(
          url: model.mmprojUrl, filename: model.mmprojFilename);
    } catch (e) {
      Get.find<AppLogService>()
          .error('Vision file download failed', details: e);
    }
  }

  bool get supportsDownloadsFolder => !kIsWeb && Platform.isAndroid;

  Future<void> downloadModelToDownloads(AiModel model, {ModelFileKind? kind}) async {
    if (isImageModel(model)) {
      _showOnlineImageNotice();
      return;
    }
    if (model.url.trim().isEmpty) {
      showToast('Download Unavailable', 'This model has no download URL.',
          tone: ToastTone.warning);
      return;
    }

    if (!supportsDownloadsFolder) {
      showToast(
        'Android Only',
        'Use the app download button or import a local model on this platform.',
        tone: ToastTone.info,
      );
      return;
    }

    // Both downloads report progress under the same filename; running them
    // together mixes up their progress.
    if (isDownloadingModel(model.filename)) {
      showToast('Already downloading',
          'Wait for the in-app download of this model to finish first.',
          tone: ToastTone.warning);
      return;
    }

    try {
      externalDownloadKind.value = kind ?? model.fileKind;
      isImporting.value = true;
      importFileName.value = model.filename;
      importStatus.value = 'Starting download...';
      importCopiedBytes.value = 0;
      importTotalBytes.value = 0;
      importBytesPerSecond.value = 0;

      final result =
          await _androidImportChannel.invokeMapMethod<String, dynamic>(
        'downloadToDownloads',
        {'url': model.url, 'filename': model.filename},
      );
      externalDownloadId.value = result?['downloadId'] as int?;
      final filename = result?['filename'] as String? ?? model.filename;
      showToast(
        'Download Started',
        '$filename is downloading to your Downloads folder.',
        tone: ToastTone.info,
      );
    } on PlatformException catch (e) {
      isImporting.value = false;
      externalDownloadId.value = null;
      Get.find<AppLogService>().error(
        'Download to Downloads failed',
        details: '${e.code}: ${e.message}',
      );
      showToast('Download Failed', e.message ?? e.code, tone: ToastTone.error);
    } catch (e) {
      isImporting.value = false;
      externalDownloadId.value = null;
      Get.find<AppLogService>()
          .error('Download to Downloads failed', details: e);
      showToast('Download Failed', '$e', tone: ToastTone.error);
    }
  }

  Future<void> cancelExternalDownload() async {
    final id = externalDownloadId.value;
    if (id != null) {
      try {
        await _androidImportChannel
            .invokeMethod('cancelDownloadToDownloads', {'downloadId': id});
      } catch (e) {
        Get.find<AppLogService>().error('Cancel download failed', details: e);
      }
      externalDownloadId.value = null;
      isImporting.value = false;
      importStatus.value = 'Download cancelled';
    }
  }

  bool canPauseDownload(String filename) =>
      !(externalDownloadId.value != null && importFileName.value == filename) &&
      _download.canPauseDownload(filename);

  void pauseDownload(String filename) {
    _download.pauseDownload(filename);
  }

  /// Removes a custom model entry added from a URL in an earlier version,
  /// cancelling any download and deleting any partial or complete file.
  Future<void> removeCustomModel(AiModel model) async {
    if (!await _tryDeleteModel(model.filename)) return;
    customModels.removeWhere((m) => m.filename == model.filename);
    availableModels
        .removeWhere((m) => m.isCustom && m.filename == model.filename);
    await _saveCustomModels();
    await refreshDownloaded();
  }

  Future<void> deleteModel(String filename) async {
    if (await _tryDeleteModel(filename)) await refreshDownloaded();
  }

  Future<bool> _tryDeleteModel(String filename) async {
    if (_modelOperationInProgress || _localImage.isGenerating.value) {
      showToast('Model in use', 'Wait for the current model operation to finish.',
          tone: ToastTone.warning);
      return false;
    }
    isPreparingModel.value = true;
    try {
      if (_download.activeDownloads.containsKey(filename)) {
        _download.pauseDownload(filename);
      }
      final activeProjector = _inference.loadedProjectorPath;
      final isActiveProjector = activeProjector != null &&
          activeProjector == await _download.modelPath(filename);
      if (_inference.loadedModelName.value == filename || isActiveProjector) {
        await _inference.unloadModel();
        if (_inference.loadedModelName.value == filename ||
            (isActiveProjector &&
                _inference.loadedProjectorPath == activeProjector)) {
          showToast('Model in use',
              'Wait for the current model operation to finish.',
              tone: ToastTone.warning);
          return false;
        }
      }
      if (_localImage.loadedModelName.value == filename) {
        await _localImage.unloadModel();
        if (_localImage.isModelLoaded.value) return false;
      }
      await _download.deleteModel(filename);
      return true;
    } catch (error) {
      Get.find<AppLogService>().error('Could not delete model',
          details: diagnosticText('$error'));
      showToast('Could not delete model', 'Check the log for details.',
          tone: ToastTone.error);
      return false;
    } finally {
      isPreparingModel.value = false;
    }
  }

  bool get _modelOperationInProgress =>
      isPreparingModel.value ||
      _inference.isLoadingModel.value ||
      _localImage.isLoadingModel.value;

  Future<void> loadModel(String filename,
      {bool safeRetry = false, bool includeHelpers = true}) async {
    if (_modelOperationInProgress) {
      showToast('Model loading', 'Wait for the current model load.',
          tone: ToastTone.warning);
      return;
    }
    final selected = availableModels.firstWhereOrNull((m) => m.filename == filename);
    if ((selected != null && isImageModel(selected)) ||
        RegExp(r'\.(safetensors|sdbundle|coreml|mlpackage|mlmodelc)(?:\.zip)?$',
                caseSensitive: false).hasMatch(filename)) {
      _showOnlineImageNotice();
      return;
    }
    if (fileRole(filename).isHelper || _isAuxiliaryImageFile(filename)) {
      showToast('Helper file', fileRole(filename).help,
          tone: ToastTone.info);
      return;
    }

    isPreparingModel.value = true;
    final report = ModelLoadDiagnostics()
      ..set('file', filename)
      ..set('includeHelpers', includeHelpers)
      ..stage('file check');
    try {
      await _loadModel(filename, report, safeRetry: safeRetry, includeHelpers: includeHelpers);
    } catch (error, stack) {
      report
        ..set('exceptionType', error.runtimeType.toString())
        ..set('dartStack', stack.toString().split('\n').take(16).join('\n'));
      if (error is PlatformException) report.set('platformErrorCode', error.code);
      if (error is FileSystemException) {
        report.set('osErrorCode', error.osError?.errorCode);
      }
      await _reportLoadFailure(filename, report, diagnosticText('$error'));
    } finally {
      await report.finish();
      isPreparingModel.value = false;
    }
  }

  Future<void> _loadModel(String filename, ModelLoadDiagnostics report, {required bool safeRetry, required bool includeHelpers}) async {
    final listedModel =
        availableModels.firstWhereOrNull((m) => m.filename == filename);
    final model = listedModel == null || !includeHelpers
        ? listedModel
        : await _resolveVisionHelper(listedModel);
    final name = model?.name ?? filename;
    final parameters = ModelLoadDiagnostics.parameterLabel('$name $filename');
    final lower = filename.toLowerCase();
    final isLiteRt = lower.endsWith('.litertlm') ||
        model?.runtime == AiModel.runtimeLiteRt;
    final isImage = isImageModel(model ??
        AiModel(name: filename, filename: filename, url: '', size: '',
            description: '', template: ''));
    report
      ..set('model', name)
      ..set('runtime', isImage ? 'image' : isLiteRt ? 'LiteRT-LM' : 'llama.cpp')
      ..set('parametersFromName', parameters ?? 'unknown')
      ..set('quantizationFromFilename', RegExp(
          r'(?:^|[^a-z0-9])((?:i?q[2-8](?:_[a-z0-9]+)*)|fp8|f16|bf16|f32)(?=$|[^a-z0-9])',
          caseSensitive: false).firstMatch(lower)?.group(1)?.toUpperCase())
      ..set('imageForceCpu', isImage ? _settings.imageGenForceCpu.value : null)
      ..set('contextRequested', isImage ? null : _settings.contextSize.value)
      ..set('performanceMode', isImage
          ? _settings.imageGenBackend.value.displayName
          : _settings.liteRtPerformanceMode.value);
    final path = await _download.modelPath(filename);
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) {
      return _reportLoadFailure(filename, report,
          'The model file was not found. Download it or import it again.');
    }
    if (type != FileSystemEntityType.file && !isImage) {
      return _reportLoadFailure(filename, report,
          'Expected a model file. Select a GGUF or LiteRT-LM file.');
    }
    final fileBytes = type == FileSystemEntityType.file
        ? await File(path).length()
        : 0;
    if (type == FileSystemEntityType.file) {
      report.set('fileBytes', fileBytes);
      fileSizes[filename] = fileBytes;
      if (fileBytes == 0) {
        return _reportLoadFailure(filename, report,
            'The model file is empty. Download it again.');
      }
      if (model != null && _isIncompleteCatalogFile(model, fileBytes)) {
        final actual = DownloadService.formatBytes(fileBytes);
        return _reportLoadFailure(filename, report,
            'The model download is incomplete ($actual, expected about ${model.size}). '
            'Download it again.');
      }
    }
    if (lower.endsWith('.gguf') && !await hasGgufSignature(path)) {
      return _reportLoadFailure(filename, report,
          'Invalid GGUF header. Download all matching model files again.');
    }
    if (lower.endsWith('.safetensors') &&
        !await _hasValidSafetensorsHeader(path)) {
      return _reportLoadFailure(filename, report,
          'Invalid safetensors header. Download the image model again.');
    }
    if (isLiteRt && !await _hasLikelyValidLiteRtFile(path)) {
      return _reportLoadFailure(filename, report,
          'Invalid LiteRT-LM file. Download the model again.');
    }
    report.stage('read model metadata');
    final gguf = lower.endsWith('.gguf') ? await readGgufInfo(path) : null;
    if (gguf != null) {
      report
        ..set('ggufArchitecture', gguf.architecture)
        ..set('ggufName', gguf.name)
        ..set('ggufSizeLabel', gguf.sizeLabel)
        ..set('ggufFileType', gguf.fileType)
        ..set('ggufParameterCount', gguf.parameterCount)
        ..set('ggufTensorCount', gguf.tensorCount)
        ..set('ggufSplitCount', gguf.splitCount)
        ..set('ggufLayers', gguf.layers)
        ..set('ggufTrainingContext', gguf.trainedContext)
        ..set('ggufEstimatedBytesAtRequestedContext',
            gguf.estimateBytes(_settings.contextSize.value));
    }
    if (!isImage &&
        lower.endsWith('.gguf') &&
        (isFastMtpDraft(filename) || isFastMtpDraft(gguf?.name ?? ''))) {
      const reason = 'This GGUF is a FastMTP draft companion and cannot run as a chat model.';
      report
        ..stage('validate GGUF model role')
        ..set('ggufRole', 'fastmtp_draft');
      return _reportLoadFailure(
        filename,
        report,
        reason,
        diagnosis: (
          likely: reason,
          details: 'Select a complete text GGUF from the model repository. '
              'If the full model exceeds this device’s available RAM, select a smaller model.',
        ),
      );
    }
    report.stage('load confirmation');
    // The phone cluster splits GGUF models only (llama.cpp); a LiteRT model
    // always runs on this phone, so say so instead of silently ignoring the
    // workers.
    if (isLiteRt &&
        Get.isRegistered<ClusterService>() &&
        !await Get.find<ClusterService>().confirmLiteRtRunsHere(filename)) {
      return;
    }
    final loadAction = await _confirmModelLoadSafety(
      filename: filename,
      fileBytes: fileBytes,
      isLiteRt: isLiteRt,
      gguf: gguf,
    );
    if (loadAction == _ModelLoadAction.cancel) return;
    if (isLiteRt && !await _confirmLiteRtGpuWarning()) return;
    if (loadAction == _ModelLoadAction.unloadAndContinue) {
      await report.checkpoint('unload previous model');
      await _unloadModels();
    }

    {
      // GGUF vision: pass the projector if it's on disk; otherwise fetch it
      // and load text-only for now.
      String? mmprojPath;
      var visionNote = '';
      final hasOptionalHelper = model != null && model.hasVisionProjector && !isLiteRt;
      if (hasOptionalHelper && !includeHelpers) {
        visionNote = ' Loaded for text chat.';
      } else if (hasOptionalHelper) {
        if (await _download.isModelDownloaded(model.mmprojFilename)) {
          mmprojPath = await _download.modelPath(model.mmprojFilename);
        } else {
          visionNote = model.mmprojUrl.isEmpty
              ? ' The linked vision file is unavailable. Import it and reload.'
              : ' Vision file is still downloading. Reload when it finishes.';
          if (model.mmprojUrl.isNotEmpty &&
              !_download.activeDownloads.containsKey(model.mmprojFilename)) {
            unawaited(downloadVisionFile(model));
          }
        }
      }
      report
        ..set('visionProjectorAvailable', mmprojPath != null)
        ..set('visionProjectorExpected', hasOptionalHelper && includeHelpers)
        ..set('visionProjector', model?.hasVisionProjector == true
            ? model!.mmprojFilename
            : null);
      final result = await _inference.loadModel(
        path,
        safeRetry: safeRetry,
        diagnostics: report,
        modelName: filename,
        modelRuntime: model?.runtime,
        enableLiteRtVision: model != null && isLiteRt && isVisionModel(model),
        mmprojPath: mmprojPath,
      );
      if (_inference.isModelLoaded.value &&
          _inference.loadedModelName.value == filename &&
          !result.startsWith('ERROR:')) {
        final fallbackToText = result.toLowerCase().contains('text-only');
        _inference.isVisionLoaded.value = isLiteRt
            ? (!fallbackToText && model != null && isVisionModel(model))
            : _inference.ggufVisionLoaded;
        try {
          await _hive.setSetting(AppConstants.keyLocalModelIncludesHelpers, includeHelpers);
          await _settings.setInferenceMode('local');
        } catch (error) {
          Get.find<AppLogService>().warning('Could not save inference mode',
              details: diagnosticText('$error'));
        }
        showToast('Model loaded', '$result$visionNote',
            tone: visionNote.isEmpty ? ToastTone.success : ToastTone.info);
      } else {
        final diag = await _diagnoseLoad(filename, path, result, gguf: gguf);
        await _reportLoadFailure(filename, report, result, diagnosis: diag);
      }
    }
  }

  Future<void> _reportLoadFailure(
    String filename,
    ModelLoadDiagnostics report,
    String error, {
    ({String? likely, String details})? diagnosis,
  }) async {
    final details = diagnosticText(diagnosis?.details ?? error);
    report.set('likelyCause', diagnosis?.likely ?? _getFriendlyErrorMessage(error));
    await report.finish(error: error, details: diagnosis == null ? null : details);
    final safeError = diagnosticText(error);
    Get.find<AppLogService>().error('Model load failed', details: safeError);
    _showLoadFailedSheet(filename, safeError,
        includeHelpers: report.includeHelpers,
        diagnosis: (likely: diagnosis?.likely, details: details));
  }

  /// Looks at the file, the model's header and the phone to explain WHY a
  /// model did not load. [likely] is the most probable cause in plain words;
  /// [details] lists everything that was checked.
  Future<({String? likely, String details})> _diagnoseLoad(
      String filename, String path, String error,
      {required GgufInfo? gguf}) async {
    final d = StringBuffer();
    String? likely;
    void line(String s) => d.writeln(s);
    try {
      final f = File(path);
      final exists = await f.exists();
      final bytes = exists ? await f.length() : 0;
      line('File: $filename');
      line('Exists: $exists, size: ${DownloadService.formatBytes(bytes)}');
      if (!exists || bytes == 0) {
        likely = 'The model file is missing or empty. Download it again.';
      }
      if (exists && bytes > 0 && filename.toLowerCase().endsWith('.gguf')) {
        final raf = await f.open();
        List<int> head;
        try {
          head = await raf.read(8);
        } finally {
          await raf.close();
        }
        final magic = String.fromCharCodes(head.take(4));
        line('Header magic: ${magic == 'GGUF' ? 'GGUF (valid)' : 'NOT GGUF ("$magic")'}');
        if (magic != 'GGUF') {
          likely ??= 'This file is not a valid GGUF model (wrong header). The download is probably corrupt or it is an HTML error page: delete it and download again.';
        } else {
          final info = gguf;
          if (info == null) {
            line('Header details: could not be read (file may be cut short).');
            // Metadata used for estimates is optional for some architectures.
          } else {
            line('Architecture: ${info.architecture}${info.name != null ? ' (${info.name})' : ''}');
            line('Layers: ${info.layers}, trained context: ${info.trainedContext}');
            if (!isSupportedLlamaArch(info.architecture)) {
              likely ??= 'This app\'s llama.cpp engine does not support the "${info.architecture}" architecture yet, so this model cannot run here. Pick another model.';
            }
            final ctx = _hive.getSetting<int>(AppConstants.keyContextSize,
                    defaultValue: AppConstants.defaultContextSize) ??
                AppConstants.defaultContextSize;
            final need = info.estimateBytes(ctx);
            line('Context size setting: $ctx tokens');
            line('Estimated memory needed: ${DownloadService.formatBytes(need)}');
            if (Get.isRegistered<DeviceInfoService>()) {
              final dev = Get.find<DeviceInfoService>();
              final total = dev.totalRamGB.value;
              final avail = dev.availableRamGB.value;
              line('Phone RAM: ${total.toStringAsFixed(1)} GB total, ${avail.toStringAsFixed(1)} GB free now');
              if ((error.toLowerCase().contains('memory') ||
                      error.toLowerCase().contains('alloc')) &&
                  avail > 0 && need / (1024 * 1024 * 1024) > avail) {
                likely ??= 'Not enough free memory: it needs about ${(need / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB but only ${avail.toStringAsFixed(1)} GB is free. Close other apps, lower the context size in Settings, or choose a smaller quantisation.';
              }
            }
          }
        }
      }
    } catch (e) {
      line('Diagnosis itself failed: $e');
    }
    final low = error.toLowerCase();
    if (likely == null) {
      if (low.contains('out of memory') || low.contains('oom') || low.contains('alloc')) {
        likely = 'The phone ran out of memory while loading. Lower the context size, close other apps, or use a smaller model.';
      } else if (low.contains('vulkan') || low.contains('gpu')) {
        likely = 'The GPU backend failed. Turn on CPU Safe mode in Performance settings and try again.';
      } else if (low.contains('unknown model architecture') || low.contains('unsupported')) {
        likely = 'This model type is not supported by the engine in this app version.';
      } else if (low.contains('mmproj') || low.contains('vision')) {
        likely = 'The vision projector file did not load. Re-download the matching mmproj file.';
      }
    }
    line('');
    line('Engine said: $error');
    return (likely: likely, details: d.toString().trimRight());
  }

  Future<bool> _hasValidSafetensorsHeader(String path) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      final length = await file.length();
      if (length < 16) return false;
      raf = await file.open();
      final bytes = await raf.read(16);
      if (bytes.length < 16) return false;

      var headerLength = 0;
      for (var i = 0; i < 8; i++) {
        headerLength += bytes[i] << (8 * i);
      }

      if (headerLength <= 2 || headerLength > length - 8) return false;
      if (headerLength > 64 * 1024 * 1024) return false;
      return bytes[8] == 0x7B;
    } catch (_) {
      return false;
    } finally {
      await raf?.close();
    }
  }

  Future<bool> _hasLikelyValidLiteRtFile(String path) async {
    RandomAccessFile? raf;
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final length = await file.length();
      if (length < 10 * 1024 * 1024) return false;

      raf = await file.open();
      final bytes = await raf.read(16);
      if (bytes.length < 8) return false;

      // Verify LiteRT-LM magic identifier 'LITERTLM' at bytes 0-7
      final hasLmLiteRt = bytes[0] == 0x4C && // 'L'
          bytes[1] == 0x49 && // 'I'
          bytes[2] == 0x54 && // 'T'
          bytes[3] == 0x45 && // 'E'
          bytes[4] == 0x52 && // 'R'
          bytes[5] == 0x54 && // 'T'
          bytes[6] == 0x4C && // 'L'
          bytes[7] == 0x4D; // 'M'

      if (hasLmLiteRt) {
        return true;
      }

      // Note: We intentionally DO NOT allow standard TFLite models starting with 'TFL3' at offset 4
      // if they lack the 'LITERTLM' container header, because the native LiteRT-LM engine
      // strictly expects the .litertlm conversational bundle structure and will crash with a
      // SIGABRT native assert check failure if it is not present.
      return false;
    } catch (_) {
      return false;
    } finally {
      await raf?.close();
    }
  }

  Future<_ModelLoadAction> _confirmModelLoadSafety({
    required String filename,
    required int fileBytes,
    required bool isLiteRt,
    required GgufInfo? gguf,
  }) async {
    // Phone cluster: the model is split across phones, so this phone's free
    // memory alone says little. ClusterService checks the whole cluster's
    // memory (and offers this-phone-only when it fits) right before loading.
    if (!isLiteRt &&
        filename.toLowerCase().endsWith('.gguf') &&
        Get.isRegistered<ClusterService>() &&
        Get.find<ClusterService>().role == ClusterRole.master &&
        Get.find<ClusterService>().workers.isNotEmpty) {
      return _ModelLoadAction.continueLoad;
    }

    final availableRamGb = await _refreshAvailableRamGb();

    // Whatever is loaded now (text or image) gets unloaded first, so count
    // its memory as free when judging whether the new model fits.
    final loadedName = _inference.isModelLoaded.value
        ? _inference.loadedModelName.value
        : _localImage.isModelLoaded.value
            ? _localImage.loadedModelName.value
            : '';
    final hasLoadedModel = loadedName.isNotEmpty;
    final isSameModelLoaded = hasLoadedModel && loadedName == filename;
    final loadedBytes = hasLoadedModel ? (fileSizes[loadedName] ?? 0) : 0;

    final measuredBytes = (availableRamGb * 1024 * 1024 * 1024).round();
    final availableBytes =
        measuredBytes > 0 ? measuredBytes + loadedBytes : measuredBytes;
    final modelLabel = fileBytes > 0
        ? DownloadService.formatWholeMb(fileBytes)
        : 'Unknown size';
    final ramLabel = availableBytes > 0
        ? '${hasLoadedModel && loadedBytes > 0 ? '~' : ''}'
            '${DownloadService.formatWholeMb(availableBytes)}'
        : 'Unknown';
    final lower = filename.toLowerCase();

    // For GGUF, estimate real usage from the file's header: weights plus the
    // KV cache for the configured context, which file size alone ignores.
    final contextTokens = _settings.contextSize.value;
    final estimatedBytes = gguf?.estimateBytes(contextTokens);
    final fits = estimatedBytes == null ||
        availableBytes <= 0 ||
        estimatedBytes <= availableBytes;
    final fittingContext = (gguf != null && !fits && availableBytes > 0)
        ? gguf.maxContextFitting(availableBytes)
        : null;

    final hasMeasuredMemory = availableBytes > 0 && fileBytes > 0;
    final isCriticallyLow = hasMeasuredMemory &&
        (estimatedBytes != null
            ? estimatedBytes > availableBytes
            : (availableBytes < fileBytes ||
                _isLowMemoryBytes(availableBytes)));
    final isLargeForRam =
        availableBytes > 0 && fileBytes > 0 && availableBytes < fileBytes * 2;
    final isLowRam = availableBytes > 0 && _isLowMemoryBytes(availableBytes);
    final String warning;
    if (gguf != null && !isSupportedLlamaArch(gguf.architecture)) {
      warning = 'This model uses the "${gguf.architecture}" architecture, '
          'which this app\'s llama.cpp can\'t run, so loading will fail. '
          'Pick a different model.';
    } else if (gguf != null && !fits) {
      warning = fittingContext != null
          ? 'This probably won\'t fit in free memory at a context of '
              '$contextTokens tokens. A context of $fittingContext tokens '
              'should fit.'
          : 'This model is probably too large for the free memory on this '
              'phone, even with a small context. Try a smaller model.';
    } else if (isCriticallyLow) {
      warning =
          'Available RAM is lower than recommended. This can crash the app if Android cannot reserve enough memory.';
    } else if (isLargeForRam || isLowRam || isLiteRt) {
      warning =
          'This can crash the app if Android cannot reserve enough memory for the model.';
    } else {
      warning = 'Loading local models can use more memory than the file size.';
    }
    final runtimeLabel = isLiteRt
        ? 'LiteRT-LM'
        : lower.endsWith('.gguf')
            ? 'GGUF'
            : lower.endsWith('.safetensors')
                ? 'Image model'
                : 'Local model';

    final warningSerious = (gguf != null && !fits) ||
        isCriticallyLow ||
        isLargeForRam ||
        isLowRam ||
        isLiteRt;

    final sheetContext = Get.context;
    if (sheetContext == null || !sheetContext.mounted) {
      return _ModelLoadAction.cancel;
    }
    final result = await showAppSheet<_ModelLoadAction>(
      sheetContext,
      title: isSameModelLoaded
          ? 'Reload model?'
          : hasLoadedModel
              ? 'Switch model?'
              : isCriticallyLow
                  ? 'Restart recommended'
                  : 'Load model?',
      subtitle: filename,
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        void pop(_ModelLoadAction action) {
          if (ctx.mounted) Navigator.pop(ctx, action);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppGroup(children: [
              _detailRow(ctx, 'Runtime', runtimeLabel),
              _detailRow(
                  ctx,
                  hasLoadedModel ? 'Available after unload' : 'Available RAM',
                  ramLabel),
              _detailRow(ctx, 'Model size', modelLabel),
              if (gguf != null && estimatedBytes != null)
                _detailRow(
                  ctx,
                  'Estimated memory',
                  DownloadService.formatWholeMb(estimatedBytes),
                  note: 'Context '
                      '${DownloadService.formatWholeMb(gguf.kvCacheBytes(contextTokens))} '
                      'for $contextTokens tokens',
                ),
            ]),
            if (hasLoadedModel) ...[
              const SizedBox(height: 12),
              AppNotice(
                isSameModelLoaded
                    ? 'This model is already loaded. It will be unloaded and '
                        'loaded again.'
                    : '$loadedName is loaded. It will be unloaded first.',
                icon: Icons.memory_rounded,
              ),
            ],
            const SizedBox(height: 12),
            AppNotice(
              warning,
              icon: warningSerious
                  ? Icons.warning_amber_rounded
                  : Icons.info_outline_rounded,
              color: warningSerious ? t.orange : null,
            ),
            const SizedBox(height: 20),
            // A model is already loaded: the only choice is to swap it out.
            if (hasLoadedModel)
              Row(children: [
                Expanded(
                  child: TonalButton.neutral(
                    ctx,
                    label: 'Cancel',
                    onTap: () => pop(_ModelLoadAction.cancel),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: 'Unload & continue',
                    onPressed: () => pop(_ModelLoadAction.unloadAndContinue),
                  ),
                ),
              ])
            else ...[
              PrimaryButton(
                label: 'Continue',
                onPressed: () async {
                  await _refreshAvailableRamGb();
                  pop(_ModelLoadAction.continueLoad);
                },
              ),
              if (fittingContext != null) ...[
                const SizedBox(height: 10),
                TonalButton.neutral(
                  ctx,
                  label: 'Load with $fittingContext tokens',
                  onTap: () async {
                    await _settings.setContextSize(fittingContext);
                    pop(_ModelLoadAction.continueLoad);
                  },
                ),
              ],
              if (isCriticallyLow) ...[
                const SizedBox(height: 10),
                TonalButton.neutral(
                  ctx,
                  label: 'Restart app',
                  onTap: () async {
                    pop(_ModelLoadAction.cancel);
                    try {
                      await _androidImportChannel.invokeMethod('restartApp');
                    } catch (_) {
                      SystemNavigator.pop();
                    }
                  },
                ),
              ],
              const SizedBox(height: 10),
              TonalButton.neutral(
                ctx,
                label: 'Cancel',
                onTap: () => pop(_ModelLoadAction.cancel),
              ),
            ],
          ],
        );
      },
    );
    return result ?? _ModelLoadAction.cancel;
  }

  Future<bool> _confirmLiteRtGpuWarning() async {
    final mode = _settings.liteRtPerformanceMode.value;
    if (mode == 'cpu_safe') return true;

    final accepted = _hive.getSetting<bool>(
          AppConstants.keyLiteRtGpuWarningAccepted,
          defaultValue: false,
        ) ??
        false;
    if (accepted) return true;

    final modeLabel = mode == 'gpu_fast' ? 'GPU Fast' : 'Auto Fast';
    final context = Get.context;
    final confirmed = context == null
        ? false
        : await confirmSheet(
            context,
            title: '$modeLabel LiteRT speed',
            message:
                'GPU can make LiteRT models much faster, closer to Edge Gallery speed. '
                'On some phones GPU/OpenCL can crash the app while loading. '
                'If that happens, Auto Fast will use CPU on the next load.',
            confirmLabel: 'Continue',
          );

    if (confirmed == true) {
      await _hive.setSetting(AppConstants.keyLiteRtGpuWarningAccepted, true);
      return true;
    }
    return false;
  }

  bool _isLowMemoryBytes(int bytes) => bytes < 768 * 1024 * 1024;

  Future<double> _refreshAvailableRamGb() async {
    try {
      final device = Get.find<DeviceInfoService>();
      await device.refreshMemoryInfo();
      return device.availableRamGB.value;
    } catch (_) {
      return 0;
    }
  }

  Future<void> unloadModel() async {
    if (_modelOperationInProgress) return;
    await _unloadModels();
  }

  Future<void> _unloadModels() async {
    await _inference.unloadModel();
    await _localImage.unloadModel();
  }

  Future<List<AiModel>> importModelsFromStorage() async {
    if (isImporting.value) return [];
    if (Platform.isAndroid) {
      List<FolderModelFile>? files;
      isImporting.value = true;
      importStatus.value = 'Select model and helper files…';
      try {
        final result = await _androidImportChannel
            .invokeMapMethod<String, dynamic>('pickModelFiles');
        files = _pickedModelFiles(result);
      } on PlatformException catch (error) {
        showToast('Import failed', error.message ?? error.code,
            tone: ToastTone.error);
      } finally {
        isImporting.value = false;
        importStatus.value = '';
      }
      return files == null ? <AiModel>[] : await importFolderFiles(files);
    }

    final imported = <String>[];
    final failed = <String>[];
    isImporting.value = true;
    importStatus.value = 'Select model and helper files…';
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: false,
      );
      for (final picked in result?.files ?? const <PlatformFile>[]) {
        final name = picked.name;
        if (!_modelImportName(name) ||
            picked.path == null ||
            picked.size <= 0) {
          failed.add(name);
          continue;
        }
        final destination = File(await _download.modelPath(name));
        if (await destination.exists() && !await _confirmReplace(name))
          continue;
        final partial = File('${destination.path}.part');
        importFileName.value = name;
        importStatus.value = 'Copying to app storage…';
        importCopiedBytes.value = 0;
        importTotalBytes.value = picked.size;
        importBytesPerSecond.value = 0;
        try {
          await _copyWithProgress(File(picked.path!).openRead(), partial);
          if (await partial.length() != picked.size) {
            throw const FileSystemException(
                'Selected file size changed while copying.');
          }
          await partial.rename(destination.path);
          fileSizes[name] = picked.size;
          imported.add(name);
        } catch (error) {
          if (await partial.exists()) await partial.delete();
          failed.add(name);
          Get.find<AppLogService>()
              .error('Model import failed', details: error);
        }
      }
      return await _finishBatchImport(imported, failed);
    } catch (error) {
      showToast('Import failed', '$error', tone: ToastTone.error);
      return [];
    } finally {
      _clearImportProgress();
    }
  }

  bool _modelImportName(String name) =>
      RegExp(r'^[^/\\]+\.(?:gguf|litertlm|safetensors)$', caseSensitive: false)
          .hasMatch(name);

  List<FolderModelFile>? _pickedModelFiles(Map<String, dynamic>? result) {
    if (result == null || result['cancelled'] == true) return null;
    return (result['files'] as List? ?? []).map((item) {
      final file = item as Map;
      return FolderModelFile(
        uri: file['uri'] as String,
        name: file['name'] as String,
        size: (file['size'] as num).toInt(),
      );
    }).toList();
  }

  /// Folder import is Android only (storage access framework tree picker).
  bool get supportsFolderImport => Platform.isAndroid;

  /// Opens the system folder picker and lists the model files inside.
  /// Returns null when the user cancels.
  Future<List<FolderModelFile>?> pickModelFolder() async {
    try {
      final result = await _androidImportChannel
          .invokeMapMethod<String, dynamic>('pickModelFolder');
      return _pickedModelFiles(result);
    } on PlatformException catch (e) {
      Get.find<AppLogService>()
          .error('Folder scan failed', details: '${e.code}: ${e.message}');
      showToast('Couldn\'t read folder', e.message ?? e.code,
          tone: ToastTone.error);
      return null;
    }
  }

  /// Copies the chosen files into app storage one after another, with the
  /// same progress card as a single import.
  Future<List<AiModel>> importFolderFiles(List<FolderModelFile> files) async {
    if (files.isEmpty) return [];
    if (isImporting.value) {
      showToast('Import in Progress', 'Wait for the current import to finish.',
          tone: ToastTone.warning);
      return [];
    }
    final imported = <String>[];
    final failed = <String>[];
    isImporting.value = true;
    try {
      final modelsDir = await _download.modelsDir;
      for (final file in files) {
        if (!_modelImportName(file.name) || file.size <= 0) {
          failed.add(file.name);
          continue;
        }
        importFileName.value = file.name;
        importStatus.value = 'Copying to app storage...';
        importCopiedBytes.value = 0;
        importTotalBytes.value = file.size;
        importBytesPerSecond.value = 0;
        try {
          final args = {'uri': file.uri, 'modelsDir': modelsDir};
          var result = await _androidImportChannel
              .invokeMapMethod<String, dynamic>('importModelUri', args);
          if (result?['exists'] == true) {
            final name = result?['filename'] as String? ?? file.name;
            if (!await _confirmReplace(name)) continue;
            result = await _androidImportChannel
                .invokeMapMethod<String, dynamic>(
                    'importModelUri', {...args, 'replace': true});
          }
          final name = result?['filename'] as String? ?? file.name;
          fileSizes[name] = (result?['bytes'] as num?)?.toInt() ?? file.size;
          imported.add(name);
        } on PlatformException catch (e) {
          failed.add(file.name);
          Get.find<AppLogService>().error('Folder import failed',
              details: '${file.name} · ${e.code}: ${e.message}');
        }
      }
      return await _finishBatchImport(imported, failed);
    } finally {
      _clearImportProgress();
    }
  }

  Future<List<AiModel>> _finishBatchImport(
      List<String> imported, List<String> failed) async {
    if (imported.isNotEmpty) {
      await refreshDownloaded();
      modelScope.value = 'local';
    }
    if (failed.isNotEmpty) {
      showToast('Import finished',
          '${imported.length} imported · couldn’t import ${failed.join(', ')}',
          tone: ToastTone.warning);
    } else if (imported.isNotEmpty) {
      showToast('Import complete', '${imported.length} file(s) imported.',
          tone: ToastTone.success);
    }
    return availableModels
        .where((model) => imported.contains(model.filename))
        .toList();
  }

  void _clearImportProgress() {
    isImporting.value = false;
    importFileName.value = '';
    importStatus.value = '';
    importCopiedBytes.value = 0;
    importTotalBytes.value = 0;
    importBytesPerSecond.value = 0;
  }

  Future<void> _copyWithProgress(
    Stream<List<int>> source,
    File destination,
  ) async {
    final startedAt = DateTime.now();
    final sink = destination.openWrite();
    try {
      await for (final chunk in source) {
        sink.add(chunk);
        importCopiedBytes.value += chunk.length;
        final elapsed =
            DateTime.now().difference(startedAt).inMilliseconds / 1000;
        if (elapsed > 0) {
          importBytesPerSecond.value = importCopiedBytes.value / elapsed;
        }
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      if (await destination.exists()) {
        await destination.delete();
      }
      rethrow;
    }
  }

  Future<bool> _confirmReplace(String filename) async {
    final context = Get.context;
    if (context == null) return false;
    return confirmSheet(
      context,
      title: 'Model already exists',
      message:
          'A model file named "$filename" is already imported in your local app storage. Would you like to replace it?',
      confirmLabel: 'Replace file',
    );
  }

  /// Removes `.part` files left behind by imports or download finalisation
  /// that crashed. Several writers use `.part` concurrently (Android import,
  /// download finalise, desktop/iOS import), and this runs on every refresh,
  /// so only delete files that no active job owns and that haven't been
  /// written to recently; deleting a live one corrupts that download.
  Future<void> _deletePartialImports() async {
    const staleAfter = Duration(minutes: 10);
    try {
      final dir = Directory(await _download.modelsDir);
      if (!await dir.exists()) return;
      final busy = {
        ..._download.activeDownloads.keys,
        if (isImporting.value) importFileName.value,
      };
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        final lower = name.toLowerCase();
        // A '.download' partial whose finished file already exists is a
        // leftover from an interrupted download that was later restarted.
        if (lower.endsWith('.download')) {
          final target = name.substring(0, name.length - '.download'.length);
          if (busy.contains(target)) continue;
          if (await File('${dir.path}/$target').exists()) await entity.delete();
          continue;
        }
        if (!lower.endsWith('.part')) continue;
        final target = name.substring(0, name.length - '.part'.length);
        if (busy.contains(target)) continue;
        final age = DateTime.now().difference(await entity.lastModified());
        if (age < staleAfter) continue;
        await entity.delete();
      }
    } catch (_) {}
  }

  /// Phone cluster errors (from ClusterService or the native cluster setup)
  /// already say what to do; anything else gets the generic tips.
  static bool _isClusterError(String rawError) {
    final lower = rawError.toLowerCase();
    return lower.contains('phone cluster') ||
        lower.contains('worker') ||
        lower.contains('cluster:') ||
        lower.contains('too big for these');
  }

  String _getFriendlyErrorMessage(String rawError) {
    final lower = rawError.toLowerCase();
    if (_isClusterError(rawError)) {
      // "ERROR: Failed to load model — Exception: <message>"
      final at = rawError.lastIndexOf('Exception: ');
      return at >= 0 ? rawError.substring(at + 'Exception: '.length) : rawError;
    }
    if (lower.contains('not found') || lower.contains('is empty') || lower.contains('expected a model file') ||
        lower.contains('download is incomplete') ||
        lower.contains('invalid gguf header') || lower.contains('invalid safetensors') || lower.contains('invalid litert')) {
      return rawError;
    }
    if (lower.contains('unknown model architecture') ||
        lower.contains('unsupported model architecture')) {
      return 'This GGUF uses a model architecture that is not supported by the bundled llama.cpp runtime. Update the app runtime or try a GGUF exported for a supported architecture.';
    }
    if (lower.contains('missing key') ||
        lower.contains('failed to load gguf split')) {
      return 'This appears to be a split GGUF model, but one or more required model files are missing. Import every split into the same folder before loading it.';
    }
    if (lower.contains('failed to load model from buffer') ||
        lower.contains('invalid_argument') ||
        lower.contains('invalid gguf') ||
        lower.contains('missing or unreadable') ||
        lower.contains('incomplete') ||
        lower.contains('corrupt')) {
      return 'The model file appears to be incomplete or corrupted. This usually happens when the download is interrupted or the file is invalid.';
    }
    if (lower.contains('out of memory') ||
        lower.contains('allocate') ||
        lower.contains('oom') ||
        lower.contains('cannot allocate')) {
      return 'Your device ran out of memory (RAM) trying to load this model. Mobile devices have strict memory limits; try using a smaller or more highly quantized model (e.g., 1B or 3B parameters, q4_k_m quantized).';
    }
    if (lower.contains('opencl') ||
        lower.contains('vulkan') ||
        lower.contains('opengl') ||
        lower.contains('gpu') ||
        lower.contains('cl_') ||
        lower.contains('driver')) {
      return 'A hardware or GPU driver error occurred while initializing the model. Try disabling GPU acceleration or switching to CPU-only inference in Settings.';
    }
    return 'The native AI engine encountered an unexpected error while loading the model. Please check the technical details below for more information.';
  }

  void _showLoadFailedSheet(String filename, String result,
      {bool includeHelpers = true, ({String? likely, String details})? diagnosis}) {
    final friendlyMsg = diagnosis?.likely ?? _getFriendlyErrorMessage(result);
    final context = Get.context;
    if (context == null || !context.mounted) {
      showToast('Model load failed', friendlyMsg,
          tone: ToastTone.error, duration: const Duration(seconds: 6));
      return;
    }
    final showLiteRtTip = result.toLowerCase().contains('litert') ||
        filename.toLowerCase().endsWith('.litertlm');
    final isCluster = _isClusterError(result);
    bool showDetails = false;
    showAppSheet<void>(
      context,
      title: isCluster ? 'Phone cluster couldn\'t load' : 'Model load failed',
      subtitle: friendlyMsg,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final t = AppTokens.of(ctx);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isCluster) ...[
                _buildTipRow(ctx, Icons.hub_outlined,
                    'On each worker, open NeuroMesh AI > Phone cluster and check that Worker is on and shows its QR code.'),
                _buildTipRow(ctx, Icons.wifi_rounded,
                    'Keep every device on the same Wi-Fi. iPads must keep NeuroMesh AI open.'),
              ],
              if (showLiteRtTip)
                _buildTipRow(ctx, Icons.tune_rounded,
                    'Double check if this LiteRT-LM file matches your architecture.'),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: () => setState(() => showDetails = !showDetails),
                  borderRadius: BorderRadius.circular(8),
                  splashFactory: NoSplash.splashFactory,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          showDetails
                              ? 'Hide technical details'
                              : 'Show technical details',
                          style: t.label.copyWith(color: t.text),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          showDetails
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          size: 18,
                          color: t.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: showDetails
                    ? Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Container(
                          constraints: const BoxConstraints(maxHeight: 260),
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: t.fill,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              diagnosis == null ? result : diagnosis.details,
                              style:
                                  t.mono.copyWith(fontSize: 11.5, height: 1.45),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              const SizedBox(height: 20),
              if ((filename.toLowerCase().endsWith('.gguf') ||
                  filename.toLowerCase().endsWith('.litertlm')) &&
                  !isFastMtpDraft(filename) &&
                  !friendlyMsg.contains('draft companion') &&
                  !friendlyMsg.contains('incomplete') &&
                  !friendlyMsg.contains('Invalid'))
                OutlinedButton.icon(
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Retry with CPU and smaller context'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    loadModel(filename, safeRetry: true, includeHelpers: includeHelpers);
                  },
                ),
              FilledButton.icon(
                icon: const Icon(Icons.bug_report_outlined),
                label: const Text('Report an error'),
                onPressed: () {
                  Navigator.pop(ctx);
                  Get.to(() => const DiagnosticsView());
                },
              ),
              TonalButton.neutral(ctx,
                  label: 'Close', onTap: () => Navigator.pop(ctx)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTipRow(BuildContext context, IconData icon, String text) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: t.muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: t.caption.copyWith(color: t.text.withValues(alpha: 0.85)),
            ),
          ),
        ],
      ),
    );
  }

  /// Label / value line used in the load-model sheet.
  Widget _detailRow(BuildContext context, String label, String value,
      {String? note}) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.body.copyWith(fontSize: 14, color: t.muted)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value,
                    textAlign: TextAlign.end,
                    style: t.body
                        .copyWith(fontSize: 14, fontWeight: FontWeight.w500)),
                if (note != null) ...[
                  const SizedBox(height: 2),
                  Text(note, textAlign: TextAlign.end, style: t.small),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
