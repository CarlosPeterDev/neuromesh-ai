import 'dart:async';

import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../models/ai_model.dart';
import 'download_service.dart';
import 'hive_service.dart';

/// Runs model downloads one after another so a slow connection isn't split
/// across several multi-GB files at once.
class DownloadQueue extends GetxService {
  final queue = <AiModel>[].obs;
  final current = Rxn<AiModel>();
  bool _pumping = false;

  static const _key = 'model_download_queue';
  HiveService get _hive => Get.find<HiveService>();

  @override
  void onInit() {
    super.onInit();
    final saved = _hive.getSetting<List>(_key) ?? const [];
    queue.assignAll(saved
        .whereType<Map>()
        .map((item) => AiModel.fromMap(Map<String, String>.from(item))));
    if (queue.isNotEmpty) unawaited(_pump());
  }

  Future<void> _save() => _hive.setSetting(_key, [
        if (!_abortCurrent && current.value != null) current.value!.toMap(),
        for (final model in queue) model.toMap(),
      ]);

  void add(AiModel m) {
    if (queue.any((q) => q.filename == m.filename) ||
        current.value?.filename == m.filename) {
      return;
    }
    queue.add(m);
    unawaited(_save());
    unawaited(_pump());
  }

  void remove(AiModel m) {
    queue.removeWhere((q) => q.filename == m.filename);
    unawaited(_save());
  }

  bool _abortCurrent = false;

  /// Stops the download that is running now; the next queued one then starts.
  void cancelCurrent() {
    final cur = current.value;
    if (cur == null) return;
    _abortCurrent = true;
    Get.find<ModelController>().pauseDownload(cur.filename);
    unawaited(_save());
  }

  /// Cancels the running download and empties the queue.
  void cancelAll() {
    queue.clear();
    cancelCurrent();
    unawaited(_save());
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      final mc = Get.find<ModelController>();
      await Get.find<DownloadService>().reconcileActiveDownloads();
      await mc.refreshDownloaded();
      while (queue.isNotEmpty) {
        final next = queue.first;
        queue.removeAt(0);
        current.value = next;
        await _save();
        if (!_abortCurrent && !mc.isDownloaded(next.filename)) {
          if (!mc.isDownloadingModel(next.filename))
            await mc.downloadModel(next);
          // Native downloads return as soon as they start; wait for the end.
          final started = DateTime.now();
          while (mc.isDownloadingModel(next.filename) && !_abortCurrent) {
            await Future<void>.delayed(const Duration(seconds: 2));
            if (DateTime.now().difference(started).inHours >= 6) break;
          }
          await mc.refreshDownloaded();
        }
        current.value = null;
        _abortCurrent = false;
        await _save();
      }
    } finally {
      _abortCurrent = false;
      current.value = null;
      _pumping = false;
    }
  }
}
