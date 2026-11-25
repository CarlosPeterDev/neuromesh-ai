import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/controllers/model_controller.dart';
import 'package:neuromesh_ai/controllers/settings_controller.dart';
import 'package:neuromesh_ai/models/ai_model.dart';
import 'package:neuromesh_ai/services/download_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/inference_service.dart';
import 'package:neuromesh_ai/services/local_image_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final deleteHelper in [false, true]) {
    test(
        'deleting the ${deleteHelper ? 'helper keeps the base' : 'base keeps the helper'}',
        () async {
      final dir = await Directory.systemTemp.createTemp('model-delete');
      Hive.init(dir.path);
      addTearDown(() async {
        Get.reset();
        await Hive.close();
        await dir.delete(recursive: true);
      });
      final hive = Get.put(await HiveService().init());
      Get.put(SettingsController());
      Get.put(LocalImageService());
      const base = 'model.gguf';
      const helper = 'mmproj-model.gguf';
      final baseFile = await File('${dir.path}/$base').writeAsString('base');
      final helperFile =
          await File('${dir.path}/$helper').writeAsString('helper');
      final inference =
          Get.put<InferenceService>(_LoadedInference(helperFile.path))
              as _LoadedInference;
      Get.put<DownloadService>(_LocalModels(dir.path));
      final controller = ModelController();
      controller.availableModels.add(AiModel(
        name: 'Example',
        filename: base,
        url: '',
        size: '',
        description: '',
        template: 'chatml',
        isVision: true,
        mmprojFilename: helper,
      ));
      await hive.setSetting('model_helper_links', {
        base: {'filename': helper, 'url': ''},
      });

      await controller.deleteModel(deleteHelper ? helper : base);

      expect(await baseFile.exists(), deleteHelper);
      expect(await helperFile.exists(), !deleteHelper);
      expect(inference.unloads, 1);
      expect(hive.getSetting<Map>('model_helper_links')?[base],
          {'filename': helper, 'url': ''});
    });
  }
}

class _LocalModels extends DownloadService {
  _LocalModels(this.root);
  final String root;

  @override
  Future<String> get modelsDir async => root;
}

class _LoadedInference extends InferenceService {
  _LoadedInference(this.projector) {
    loadedModelName.value = 'model.gguf';
  }
  final String projector;
  int unloads = 0;

  @override
  String? get loadedProjectorPath => unloads == 0 ? projector : null;

  @override
  Future<void> unloadModel() async {
    unloads++;
    loadedModelName.value = '';
  }
}
