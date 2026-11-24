import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../models/ai_model.dart';
import '../utils/model_file_role.dart';
import 'hf_service.dart';
import 'installed_vision_helper.dart';

class ModelHelperService {
  static String searchQuery(AiModel model) {
    final artifact = model.artifact;
    final name = model.fileRole == ModelFileRole.projector
        ? _projectName(artifact) ?? _unambiguousBaseName(artifact)
        : model.fileRole.isHelper
            ? _unambiguousBaseName(artifact)
            : artifact?.names.firstOrNull;
    if (model.fileRole.isHelper && name != null && _family(name).isNotEmpty) {
      return _familyName(name).replaceAll(RegExp(r'\s+'), '-');
    }
    final family = _familyName(model.filename);
    if (_family(family).isNotEmpty) return family;
    return name == null ? '' : _familyName(name);
  }

  static String? _projectName(ModelArtifact? artifact) =>
      artifact?.names.where((name) => _family(name).isNotEmpty).firstOrNull;

  static String? _unambiguousBaseName(ModelArtifact? artifact) =>
      artifact?.baseNames.singleOrNull;

  static String _familyName(String filename) => filename
      .replaceFirst(
          RegExp(r'\.(gguf|safetensors|litertlm|onnx)$', caseSensitive: false),
          '')
      .replaceFirst(RegExp(r'\s*\(\d+\)$'), '')
      .replaceFirst(
          RegExp(r'[-_. ]patch-all[-_. ]\d+$', caseSensitive: false), '')
      .replaceAll(
          RegExp(
              r'(?:^|[-_. ])(?:mmproj|lora|adapter_model|vae|controlnet|clip_[lg]|t5xxl|imatrix)(?=$|[-_. ])',
              caseSensitive: false),
          ' ')
      .replaceFirst(
          RegExp(
              r'(?:^|[-_. ])(?:fast[-_]?mtp[-_]\d+k|i?q\d[a-z0-9_]*|bf16|fp?16|f32)$',
              caseSensitive: false),
          '')
      .replaceAll(RegExp(r'^[-_. ]+|[-_. ]+$'), '')
      .trim();

  static String _family(String name) {
    final value = visionModelFamily(_familyName(name));
    if (const {
          'model',
          'models',
          'helper',
          'adapter',
          'weights',
          'checkpoint',
          'draft',
          'vision',
          'projector',
          'diffusion'
        }.contains(value) ||
        RegExp(r'^(?:[a-f0-9]{12,}|\d+|micro\d+)$').hasMatch(value)) {
      return '';
    }
    return value;
  }

  static Set<String> _families(Iterable<String> names) =>
      names.map(_family).where((family) => family.isNotEmpty).toSet();

  static Set<String> _repositories(AiModel model) => {
        if (huggingFaceRepository(model.url) case final String repo) repo,
        ...?model.artifact?.repositories,
      };

  static bool matchesBaseMetadata(AiModel model, ModelArtifact? helper) {
    if (helper == null) return false;
    final family = _families([
      model.filename,
      if (model.artifact?.names.firstOrNull case final String name) name,
    ]);
    if (helper.role == ModelFileRole.projector) {
      final project = _projectName(helper);
      if (project != null) return family.contains(_family(project));
      if (helper.baseNames.length > 1 || helper.baseRepositories.length > 1) {
        return false;
      }
    }
    if (_repositories(model).intersection(helper.baseRepositories).isNotEmpty) {
      return true;
    }
    return family.intersection(_families(helper.baseNames)).isNotEmpty;
  }

  static bool suggestsPair(AiModel model, AiModel helper,
      {VisionHelperSource? verifiedHelper}) {
    if (model.fileKind != ModelFileKind.model ||
        !helper.fileRole.isHelper ||
        (helper.fileRole == ModelFileRole.projector &&
            model.runtime != AiModel.runtimeLlama)) return false;
    if (model.mmprojFilename == helper.filename) return true;
    if (verifiedHelper != null) {
      return _families([model.filename, ...?model.artifact?.names])
          .contains(verifiedHelper.family);
    }
    if (matchesBaseMetadata(model, helper.artifact)) return true;
    if (_repositories(model).intersection(_repositories(helper)).isNotEmpty) {
      return true;
    }
    final possibleMain = _families([
      model.filename,
      if (model.artifact?.names.firstOrNull case final String name) name,
    ]);
    final possibleHelper = _families([
      helper.filename,
      if (helper.artifact?.names.firstOrNull case final String name) name,
    ]);
    return possibleMain.intersection(possibleHelper).isNotEmpty;
  }

  static Future<({List<AiModel> installed, VisionHelperSource? source})>
      installedCompanions({
    required AiModel selected,
    required bool isHelper,
    required Iterable<AiModel> installed,
    required Future<VisionHelperSource?> Function(String) identify,
  }) async {
    final source = isHelper && selected.fileRole == ModelFileRole.projector
        ? await identify(selected.filename)
        : null;
    final candidates = <AiModel>[];
    for (final candidate in installed) {
      final main = isHelper ? candidate : selected;
      final helper = isHelper ? selected : candidate;
      if (main.fileKind != ModelFileKind.model || !helper.fileRole.isHelper) {
        continue;
      }
      final verified = isHelper
          ? source
          : helper.fileRole == ModelFileRole.projector &&
                  _families([main.filename, ...?main.artifact?.names])
                      .contains(InstalledVisionHelpers.artemisFamily)
              ? await identify(helper.filename)
              : null;
      if (suggestsPair(main, helper, verifiedHelper: verified)) {
        candidates.add(candidate);
      }
    }
    return (installed: candidates, source: source);
  }

  static String? companionRepository(AiModel model) =>
      huggingFaceRepository(model.url) ??
      model.artifact?.repositories.singleOrNull ??
      (model.fileRole.isHelper &&
              (model.fileRole != ModelFileRole.projector ||
                  _projectName(model.artifact) == null)
          ? model.artifact?.baseRepositories.singleOrNull
          : null) ??
      huggingFaceRepository(model.mmprojUrl);

  static Future<HfGgufFile?> matchPublishedFile({
    required AiModel model,
    required int size,
    required Iterable<HfGgufFile> files,
    required Future<String?> Function(String filename) fingerprint,
  }) async {
    if (size <= 0) return null;
    final candidates = files
        .where((file) =>
            file.size == size &&
            file.sha256 != null &&
            file.kind == model.fileKind)
        .toList();
    if (candidates.isEmpty) return null;
    final digest = await fingerprint(model.filename);
    if (digest == null) return null;
    final matches = candidates.where((file) => file.sha256 == digest);
    return matches
            .where((file) => file.filename == model.filename)
            .firstOrNull ??
        matches.firstOrNull;
  }

  static Future<List<HfGgufFile>> files(
      HfService hf, AiModel model, String repository) async {
    if (huggingFaceRepository('https://huggingface.co/$repository') !=
        repository) {
      throw const FormatException(
          'Enter a Hugging Face repository as owner/name.');
    }
    if (model.runtime == AiModel.runtimeSd)
      return hf.listImageParts(repository);
    return hf.listGgufFiles(repository, includeHelpers: true);
  }

  static bool canAttach(AiModel model, String repository,
      List<HfGgufFile> files, HfGgufFile helper,
      {String? verifiedModelPath}) {
    final source = huggingFaceRepository(model.url);
    return model.runtime == AiModel.runtimeLlama &&
        !model.fileRole.isHelper &&
        helper.role == ModelFileRole.projector &&
        (source == null || source == repository) &&
        files.any((file) =>
            (verifiedModelPath == null
                ? file.filename == model.filename
                : file.path == verifiedModelPath) &&
            file.role == ModelFileRole.model) &&
        helper.path.split('/').every(
            (p) => p.isNotEmpty && p != '..' && p != '.' && !p.contains('\\'));
  }

  static Future<void> attach(AiModel model, String repository,
      List<HfGgufFile> files, HfGgufFile helper,
      {String? verifiedModelPath}) async {
    if (!canAttach(model, repository, files, helper,
        verifiedModelPath: verifiedModelPath)) {
      throw const FormatException(
          'Choose a projector from a repository that also contains this exact main model file.');
    }
    final key = sha256.convert(utf8.encode('$repository/${helper.path}'));
    final filename = 'mmproj-${key.toString().substring(0, 16)}.gguf';
    final controller = Get.find<ModelController>();
    await controller.attachVisionHelper(
        model, filename, HfService.downloadUrl(repository, helper.path));
    final updated = controller.availableModels
        .firstWhere((m) => m.filename == model.filename);
    await controller.downloadVisionFile(updated);
  }
}
