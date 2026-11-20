import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/models/ai_model.dart';
import 'package:neuromesh_ai/services/installed_vision_helper.dart';
import 'package:neuromesh_ai/services/model_helper_service.dart';
import 'package:neuromesh_ai/utils/model_file_role.dart';

void main() {
  late Directory directory;
  final model = AiModel.fromMap(AppConstants.artemisStarter);

  setUp(() async => directory = await Directory.systemTemp.createTemp());
  tearDown(() => directory.delete(recursive: true));

  Future<String> fixture(String name, {bool valid = true}) async {
    final file = File('${directory.path}/$name');
    await file.writeAsBytes([
      ...(valid ? 'GGUF' : 'ZIP!').codeUnits,
      ...List.filled(20, 0),
    ]);
    return file.path;
  }

  test('finds imported projectors named for the exact model family', () async {
    const name = 'mmproj_Qwen3.5_0.8B_Artemis-BF16.gguf';
    final candidates = {
      name: await fixture(name),
      'mmproj-BF16.gguf': await fixture('mmproj-BF16.gguf'),
      'mmproj-Qwen3.5-4B-Artemis-BF16.gguf':
          await fixture('mmproj-Qwen3.5-4B-Artemis-BF16.gguf'),
    };
    expect(await InstalledVisionHelpers().find(model, candidates), name);
  });

  test('prefers an explicit installed link; skips ambiguous names and bad data',
      () async {
    const first = 'mmproj-Qwen3.5-0.8B-Artemis-F16.gguf';
    const second = 'Qwen3.5-0.8B-Artemis-mmproj-BF16.gguf';
    final candidates = {
      first: await fixture(first),
      second: await fixture(second),
    };
    final finder = InstalledVisionHelpers();
    expect(await finder.find(model, candidates), isNull);
    expect(
        await finder.find(model.copyWith(mmprojFilename: second), candidates),
        second);
    candidates[second] = await fixture(second, valid: false);
    expect(await finder.find(model, candidates), first);
    candidates.remove(first);
    expect(await finder.find(model, candidates), isNull);
  });

  test('recognizes the publisher’s genuine BF16 projector under an import name',
      () async {
    final path = Platform.environment['NEUROMESH_TEST_ARTEMIS_PROJECTOR'];
    if (path == null) return;
    const filename = 'mmproj-BF16.gguf';
    final finder = InstalledVisionHelpers();
    expect(await finder.find(model, {filename: path}), filename);
    final renamed = model.copyWith(
        filename: 'custom-weights.gguf',
        artifact: const ModelArtifact(names: {'Qwen3.5 0.8B Artemis'}));
    expect(await finder.find(renamed, {filename: path}), filename);
    final identity = await finder.identify(path);
    expect(identity?.repository, 'turintech/Qwen3.5-0.8B-Artemis-GGUF');
    expect(identity?.path, filename);
    final helper = model.copyWith(filename: 'mmproj-BF16 (1).gguf', url: '');
    final result = await ModelHelperService.installedCompanions(
      selected: helper,
      isHelper: true,
      installed: const [],
      identify: (_) => finder.identify(path),
    );
    expect(result.source, identity);
    expect(result.installed, isEmpty);
    final unrelated =
        model.copyWith(filename: 'Qwen3.5-4B-Q4_K_M.gguf', mmprojFilename: '');
    expect(await InstalledVisionHelpers().find(unrelated, {filename: path}),
        isNull);
  }, skip: Platform.environment['NEUROMESH_TEST_ARTEMIS_PROJECTOR'] == null);
}
