import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/models/ai_model.dart';
import 'package:neuromesh_ai/services/installed_vision_helper.dart';
import 'package:neuromesh_ai/services/hf_service.dart';
import 'package:neuromesh_ai/services/model_helper_service.dart';
import 'package:neuromesh_ai/utils/model_file_role.dart';

void main() {
  test('helper file classification preserves complete MTP models', () {
    expect(
        modelFileRole('imatrix_micro3.gguf'), ModelFileRole.quantizationData);
    expect(
        modelFileRole('qwen-imatrix-F16.gguf'), ModelFileRole.quantizationData);
    expect(modelFileRole('Qwen-Q4_K_M.gguf'), ModelFileRole.model);
    expect(modelFileRole('Family-7B-MTP-Q4_K_M.gguf'), ModelFileRole.model);
    expect(modelFileRole('mmproj-family-f16.gguf'), ModelFileRole.projector);
    expect(modelFileRole('family-FastMTP-64K.gguf'), ModelFileRole.draft);
    expect(modelFileRole('family-draft.gguf'), ModelFileRole.model);
    expect(modelFileRole('family-lora.safetensors'), ModelFileRole.adapter);
    expect(modelFileRole('family-vae.safetensors'), ModelFileRole.imageAddon);
    expect(modelFileRole('vae/diffusion_pytorch_model.safetensors'),
        ModelFileRole.imageAddon);
    expect(modelFileRole('adapter_model.safetensors'), ModelFileRole.adapter);
    expect(modelFileRole('Huihui-Qwen3.8-27B-abliterated-patch-all-5.gguf'),
        ModelFileRole.patch);
    expect(modelFileKind('Qwen3.5-0.8B-Artemis-imatrix.gguf'),
        ModelFileKind.helper);
  });

  test(
      'imported projector suggestions use the model family and original source',
      () {
    AiModel model(String file, [String url = '']) => AiModel(
        name: file,
        filename: file,
        url: url,
        size: '',
        description: '',
        template: 'chatml');
    final main = model('Family-VL-7B-Q4_K_M.gguf');
    final helper = model('mmproj-Family-VL-7B-f16.gguf');
    expect(ModelHelperService.searchQuery(helper), 'Family-VL-7B');
    expect(ModelHelperService.suggestsPair(main, helper), isTrue);
    expect(ModelHelperService.suggestsPair(main, model('mmproj-f16.gguf')),
        isFalse);
    expect(
        ModelHelperService.suggestsPair(main, model('Family-VL-7B-lora.gguf')),
        isTrue);
  });

  test('verified Artemis helpers find installed companions in either direction',
      () async {
    final artemis = AiModel.fromMap(AppConstants.artemisStarter);
    final model = artemis.copyWith(
        filename: 'Qwen3.5-0.8B-Artemis-Q5_K_M.gguf',
        url: '',
        mmprojFilename: '',
        mmprojUrl: '');
    final other = model.copyWith(filename: 'Qwen3.5-4B-Q4_K_M.gguf');
    final helper = model.copyWith(filename: 'mmproj-BF16 (1).gguf');
    final unidentified = model.copyWith(filename: 'mmproj-F16.gguf');
    final VisionHelperSource identity = (
      repository: 'turintech/Qwen3.5-0.8B-Artemis-GGUF',
      path: 'mmproj-BF16.gguf',
      family: InstalledVisionHelpers.artemisFamily,
    );
    Future<VisionHelperSource?> identify(String filename) async =>
        filename == helper.filename ? identity : null;
    final inventory = [model, other, helper, unidentified];

    final reverse = await ModelHelperService.installedCompanions(
        selected: helper,
        isHelper: true,
        installed: inventory,
        identify: identify);
    expect(reverse.installed, [model]);
    expect(reverse.source, identity);

    final forward = await ModelHelperService.installedCompanions(
        selected: model,
        isHelper: false,
        installed: inventory,
        identify: identify);
    expect(forward.installed, [helper]);

    final otherHelper = await ModelHelperService.installedCompanions(
        selected: unidentified,
        isHelper: true,
        installed: inventory,
        identify: identify);
    expect(otherHelper.source, isNull);
    expect(otherHelper.installed, isEmpty);
  });

  test('metadata links adapters and other helpers to their named base', () {
    final base = AiModel.fromMap({
      'name': 'Base',
      'filename': 'text-q4.gguf',
      'url': 'https://huggingface.co/example/my-base/resolve/main/text-q4.gguf',
    }).copyWith(artifact: const ModelArtifact(names: {'Example Base 7B'}));
    final adapter = base.copyWith(
        filename: 'custom.safetensors',
        url: '',
        artifact: const ModelArtifact(
            role: ModelFileRole.adapter,
            baseRepositories: {'example/my-base'}));
    final vision = adapter.copyWith(
        filename: 'vision.gguf',
        artifact: const ModelArtifact(
            role: ModelFileRole.projector, baseNames: {'Example Base 7B'}));
    expect(adapter.fileKind, ModelFileKind.helper);
    expect(ModelHelperService.suggestsPair(base, adapter), isTrue);
    expect(ModelHelperService.suggestsPair(base, vision), isTrue);
    expect(ModelHelperService.companionRepository(adapter), 'example/my-base');
    expect(
        ModelHelperService.suggestsPair(
            base.copyWith(
                filename: 'Other model.gguf',
                url: '',
                artifact: const ModelArtifact()),
            adapter),
        isFalse);
  });

  test('composite projectors match the finished model, excluding components',
      () {
    AiModel lookup(String filename,
            {String url = '', ModelArtifact? artifact}) =>
        AiModel.fromMap({'filename': filename, 'url': url})
            .copyWith(artifact: artifact);
    final target = lookup('SmolVLM-256M-Instruct-Q8_0.gguf');
    final otherSize = lookup('SmolVLM-500M-Instruct-Q8_0.gguf',
        artifact:
            const ModelArtifact(names: {'SmolVLM 500M Instruct', 'SmolVLM'}));
    final textComponent = lookup('SmolLM2-135M-Instruct.gguf',
        url: 'https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct');
    final projector = lookup('local-projection.gguf',
        artifact: const ModelArtifact(
          role: ModelFileRole.projector,
          names: {'SmolVLM 256M Instruct', 'SmolVLM'},
          baseNames: {'SmolLM2 135M Instruct', 'Siglip Base Patch16 512'},
          baseRepositories: {
            'HuggingFaceTB/SmolLM2-135M-Instruct',
            'google/siglip-base-patch16-512',
          },
        ));
    expect(ModelHelperService.searchQuery(projector), 'SmolVLM-256M-Instruct');
    expect(ModelHelperService.companionRepository(projector), isNull);
    expect(ModelHelperService.suggestsPair(target, projector), isTrue);
    expect(ModelHelperService.suggestsPair(otherSize, projector), isFalse);
    expect(ModelHelperService.suggestsPair(textComponent, projector), isFalse);
    expect(
        ModelHelperService.matchesBaseMetadata(
            textComponent, projector.artifact),
        isFalse);
  });

  test('matches renamed files against repository checksums with a size gate',
      () async {
    final model = AiModel.fromMap({'filename': 'mmproj-F16 (1).gguf'});
    const correct =
        HfGgufFile(path: 'parts/mmproj-F16.gguf', size: 203, sha256: 'good');
    const wrong =
        HfGgufFile(path: 'mmproj-BF16.gguf', size: 203, sha256: 'wrong');
    var fingerprints = 0;
    Future<String?> fingerprint(String filename) async {
      expect(filename, model.filename);
      fingerprints++;
      return 'good';
    }

    expect(
        await ModelHelperService.matchPublishedFile(
            model: model,
            size: 204,
            files: [correct, wrong],
            fingerprint: fingerprint),
        isNull);
    expect(fingerprints, 0);
    expect(
        await ModelHelperService.matchPublishedFile(
            model: model,
            size: 203,
            files: [wrong, correct],
            fingerprint: fingerprint),
        correct);
    expect(fingerprints, 1);
  });

  test('repository exposes unknown files without treating them as models',
      () async {
    final hf = HfService(
        client: MockClient((_) async => http.Response(
            jsonEncode([
              {'type': 'file', 'path': 'model-Q4.gguf', 'size': 100},
              {'type': 'file', 'path': 'mmproj-f16.gguf', 'size': 20},
              {'type': 'file', 'path': 'model-00001-of-00002.gguf', 'size': 50},
              {'type': 'file', 'path': 'tokenizer.json', 'size': 10},
            ]),
            200)));
    addTearDown(hf.dispose);
    final files = await hf.listRepositoryFiles('owner/family');
    expect(files.map((file) => file.kind), [
      ModelFileKind.model,
      ModelFileKind.helper,
      ModelFileKind.model,
      ModelFileKind.unknown,
    ]);
    expect(HfService.canDownloadSingleFile(files[2]), isFalse);
    expect(HfService.canDownloadSingleFile(files[3]), isFalse);
    expect(await hf.listGgufFiles('owner/family'), hasLength(1));
    expect(modelFileKind('my-image.sdbundle'), ModelFileKind.model);
  });

  test('image text encoders and chat weights get context-specific file labels',
      () {
    const file = HfGgufFile(path: 'Qwen3-4B-Q4.gguf', size: 100);
    expect(file.kindInRepository(images: false), ModelFileKind.model);
    expect(file.kindInRepository(images: true), ModelFileKind.helper);
  });

  test('helper enumeration is optional for existing HF callers', () async {
    final hf = HfService(
        client: MockClient((_) async => http.Response(
            jsonEncode([
              {'type': 'file', 'path': 'family-Q4.gguf', 'size': 123},
              {'type': 'file', 'path': 'mmproj-f16.gguf', 'size': 12},
              {'type': 'file', 'path': 'family-FastMTP-32K.gguf', 'size': 14},
            ]),
            200)));
    addTearDown(hf.dispose);
    expect(await hf.listGgufFiles('owner/family'), hasLength(1));
    expect(await hf.listGgufFiles('owner/family', includeHelpers: true),
        hasLength(3));
  });

  test('a projector association requires its base file and original repository',
      () {
    final model = AiModel(
        name: 'Family',
        filename: 'family-Q4.gguf',
        url: 'https://huggingface.co/owner/family/resolve/main/family-Q4.gguf',
        size: '',
        description: '',
        template: 'chatml');
    const main = HfGgufFile(path: 'family-Q4.gguf', size: 123);
    const helper = HfGgufFile(path: 'mmproj-f16.gguf', size: 12);
    const draft = HfGgufFile(path: 'family-draft.gguf', size: 10);
    expect(
        ModelHelperService.canAttach(
            model, 'owner/family', [main, helper], helper),
        isTrue);
    expect(
        ModelHelperService.canAttach(
            model, 'other/family', [main, helper], helper),
        isFalse);
    expect(
        ModelHelperService.canAttach(model, 'owner/family', [helper], helper),
        isFalse);
    expect(
        ModelHelperService.canAttach(
            model, 'owner/family', [main, draft], draft),
        isFalse);
    final renamed = model.copyWith(filename: 'my-model.gguf', url: '');
    expect(
        ModelHelperService.canAttach(
            renamed, 'owner/family', [main, helper], helper,
            verifiedModelPath: main.path),
        isTrue);
    expect(
        ModelHelperService.canAttach(
            renamed, 'owner/family', [main, helper], helper),
        isFalse);
    expect(huggingFaceRepository('https://huggingface.co.evil/owner/family'),
        isNull);
    expect(
        huggingFaceRepository(
            'https://huggingface.co/owner/family/resolve/main/x'),
        'owner/family');
  });
}
