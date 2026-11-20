import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../models/ai_model.dart';
import '../utils/model_file_role.dart';
import 'agent_service.dart';
import 'hf_service.dart';

class ModelHelperService {
  static String searchQuery(AiModel model) => _familyName(model.filename);

  static String _familyName(String filename) => filename
      .replaceFirst(
          RegExp(r'\.(gguf|safetensors|litertlm)$', caseSensitive: false), '')
      .replaceAll(
          RegExp(
              r'(?:^|[-_. ])(?:mmproj|lora|adapter_model|vae|controlnet|clip_[lg]|t5xxl)(?=$|[-_. ])',
              caseSensitive: false),
          ' ')
      .replaceFirst(
          RegExp(r'[-_. ](?:fast[-_]?mtp[-_]\d+k|i?q\d.*|bf16|f16|f32)$',
              caseSensitive: false),
          '')
      .replaceAll(RegExp(r'^[-_. ]+|[-_. ]+$'), '')
      .trim();

  static bool suggestsPair(AiModel model, AiModel helper) {
    if (model.runtime != AiModel.runtimeLlama ||
        modelFileRole(model.filename).isHelper ||
        modelFileRole(helper.filename) != ModelFileRole.projector) return false;
    if (model.mmprojFilename == helper.filename) return true;
    final modelRepo = huggingFaceRepository(model.url);
    final helperRepo = huggingFaceRepository(helper.url);
    if (modelRepo != null && helperRepo != null) return modelRepo == helperRepo;
    final modelFamily = _familyName(model.filename).toLowerCase();
    final helperFamily = _familyName(helper.filename).toLowerCase();
    return helperFamily.isNotEmpty && modelFamily == helperFamily;
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
      List<HfGgufFile> files, HfGgufFile helper) {
    final source = huggingFaceRepository(model.url);
    return model.runtime == AiModel.runtimeLlama &&
        !modelFileRole(model.filename).isHelper &&
        helper.role == ModelFileRole.projector &&
        (source == null || source == repository) &&
        files.any((file) =>
            file.filename == model.filename &&
            file.role == ModelFileRole.model) &&
        helper.path.split('/').every(
            (p) => p.isNotEmpty && p != '..' && p != '.' && !p.contains('\\'));
  }

  static Future<void> attach(AiModel model, String repository,
      List<HfGgufFile> files, HfGgufFile helper) async {
    if (!canAttach(model, repository, files, helper)) {
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
      final hf = HfService();
      try {
        final repo =
            args['repository']?.toString() ?? huggingFaceRepository(model.url);
        if (repo == null) {
          final repos = await hf.searchModels(
              ModelHelperService.searchQuery(model),
              limit: 8,
              images: model.runtime == AiModel.runtimeSd);
          return jsonEncode({
            'repositories': repos.map((r) => r.id).toList(),
            'next':
                'Choose the original model repository, then call this tool again with repository.'
          });
        }
        final files = await ModelHelperService.files(hf, model, repo);
        return jsonEncode({
          'repository': repo,
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
