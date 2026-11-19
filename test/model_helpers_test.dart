import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:neuromesh_ai/models/ai_model.dart';
import 'package:neuromesh_ai/services/hf_service.dart';
import 'package:neuromesh_ai/services/model_helper_service.dart';
import 'package:neuromesh_ai/utils/model_file_role.dart';

void main() {
  test('helper file classification preserves complete MTP models', () {
    expect(modelFileRole('Family-7B-MTP-Q4_K_M.gguf'), ModelFileRole.model);
    expect(modelFileRole('mmproj-family-f16.gguf'), ModelFileRole.projector);
    expect(modelFileRole('family-FastMTP-64K.gguf'), ModelFileRole.draft);
    expect(modelFileRole('family-draft.gguf'), ModelFileRole.model);
    expect(modelFileRole('family-lora.safetensors'), ModelFileRole.adapter);
    expect(modelFileRole('family-vae.safetensors'), ModelFileRole.imageAddon);
    expect(modelFileRole('vae/diffusion_pytorch_model.safetensors'),
        ModelFileRole.imageAddon);
    expect(modelFileRole('adapter_model.safetensors'), ModelFileRole.adapter);
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
        isFalse);
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
    expect(huggingFaceRepository('https://huggingface.co.evil/owner/family'),
        isNull);
    expect(
        huggingFaceRepository(
            'https://huggingface.co/owner/family/resolve/main/x'),
        'owner/family');
  });
}
