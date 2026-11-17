import 'package:get/get.dart';

import 'hive_service.dart';

/// Starred models, kept in Hive. Keys look like `hf:author/repo` for
/// Hugging Face repos and `local:file.gguf` for models on the phone.
class FavoritesService extends GetxService {
  static const _kKey = 'favorite_models';

  final items = <String>{}.obs;

  @override
  void onInit() {
    super.onInit();
    final raw = Get.find<HiveService>().getSetting<dynamic>(_kKey);
    if (raw is List) {
      items.addAll(raw.map((e) => e.toString()));
    }
  }

  bool isFav(String key) => items.contains(key);

  Future<void> toggle(String key) async {
    if (!items.remove(key)) items.add(key);
    items.refresh();
    await Get.find<HiveService>().setSetting(_kKey, items.toList());
  }

  static String hfKey(String repoId) => 'hf:$repoId';
  static String localKey(String filename) => 'local:$filename';
}
