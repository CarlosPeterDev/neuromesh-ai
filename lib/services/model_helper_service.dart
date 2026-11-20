import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../models/ai_model.dart';
import '../utils/model_file_role.dart';
import 'agent_service.dart';
import 'hf_service.dart';
import 'installed_vision_helper.dart';

class ModelHelperService {
  static String searchQuery(AiModel model) {
    final artifact = model.artifact;
    final name = model.fileRole.isHelper
        ? artifact?.baseNames.firstOrNull
        : artifact?.names.firstOrNull;
    if (model.fileRole.isHelper && name != null && _family(name).isNotEmpty) {
      return _familyName(name);
    }
    final family = _familyName(model.filename);
    if (_family(family).isNotEmpty) return family;
    return name == null ? '' : _familyName(name);
  }

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
    if (_repositories(model).intersection(helper.baseRepositories).isNotEmpty) {
      return true;
    }
    final family = _families([model.filename, ...?model.artifact?.names]);
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
    final possibleMain = _families([model.filename, ...?model.artifact?.names]);
    final possibleHelper =
        _families([helper.filename, ...?helper.artifact?.names]);
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
      (model.fileRole.isHelper
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

void registerModelHelperTools(AgentService agent) {
  AiModel modelFor(Map<String, dynamic> args) {
    final name = args['model']?.toString() ?? '';
    return Get.find<ModelController>().availableModels.firstWhere(
        (m) => m.filename == name || m.name == name,
        orElse: () => throw const FormatException(
            'Use the exact installed model filename from models_status.'));
  }

  agent.addTool(AgentTool(
    'find_model_helpers',
    'Find vision and FastMTP helpers for an installed model, or find a main model for a helper. Same-repository candidates still need compatibility review. FastMTP requires a patched runtime and cannot be attached here.',
    '{"model":"exact filename","repository":"optional owner/name"}',
    (args) async {
      final model = modelFor(args);
      final controller = Get.find<ModelController>();
      final matches = await ModelHelperService.installedCompanions(
        selected: model,
        isHelper: model.fileKind == ModelFileKind.helper,
        installed: controller.availableModels
            .where((item) => controller.isDownloaded(item.filename))
            .toList(),
        identify: controller.identifyInstalledVisionHelper,
      );
      final installed = matches.installed.map((item) => item.filename).toList();
      final hf = HfService();
      try {
        final repo = args['repository']?.toString() ??
            matches.source?.repository ??
            ModelHelperService.companionRepository(model);
        if (repo == null) {
          final query = ModelHelperService.searchQuery(model);
          final repos = query.isEmpty
              ? <HfRepo>[]
              : await hf.searchModels(query,
                  limit: 8, images: model.runtime == AiModel.runtimeSd);
          return jsonEncode({
            'installedCompanions': installed,
            'repositories': repos.map((r) => r.id).toList(),
            'next':
                'Choose the original model repository, then call this tool again with repository.'
          });
        }
        final files = await ModelHelperService.files(hf, model, repo);
        return jsonEncode({
          'repository': repo,
          'installedCompanions': installed,
          'verifiedHelperPath': matches.source?.path,
          'files': files
              .map((f) => {
                    'path': f.path,
                    'bytes': f.size,
                    'role': f.role.label,
                    'instructions': f.role.help,
                    'canAttachVision':
                        ModelHelperService.canAttach(model, repo, files, f),
                  })
              .toList()
        });
      } finally {
        hf.dispose();
      }
    },
  ));
  agent.addTool(AgentTool(
    'attach_model_helper',
    'Attach and download a vision projector from the model repository. Reload the main model afterward. This does not turn text-only architectures into vision models.',
    '{"model":"exact filename","repository":"owner/name","helper":"repository file path"}',
    (args) async {
      final model = modelFor(args);
      final repo = args['repository']?.toString() ?? '';
      final hf = HfService();
      try {
        final files = await ModelHelperService.files(hf, model, repo);
        final helper = files.firstWhere((f) => f.path == args['helper']);
        await ModelHelperService.attach(model, repo, files, helper);
        return 'Vision helper linked. Check download progress in Models, then reload ${model.filename}. The runtime checks compatibility during loading.';
      } finally {
        hf.dispose();
      }
    },
    needsConfirm: true,
  ));
}
