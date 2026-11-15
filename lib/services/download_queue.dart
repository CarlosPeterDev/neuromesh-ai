import 'dart:async';

import 'package:get/get.dart';

import '../controllers/model_controller.dart';
import '../models/ai_model.dart';

/// Runs model downloads one after another so a slow connection isn't split
/// across several multi-GB files at once.
class DownloadQueue extends GetxService {
  final queue = <AiModel>[].obs;
  final current = Rxn<AiModel>();
  bool _pumping = false;

  void add(AiModel m) {
    if (queue.any((q) => q.filename == m.filename) ||
        current.value?.filename == m.filename) {
      return;
    }
    queue.add(m);
    _pump();
  }

  void remove(AiModel m) => queue.removeWhere((q) => q.filename == m.filename);

  bool _abortCurrent = false;

  /// Stops the download that is running now; the next queued one then starts.
  void cancelCurrent() {
    final cur = current.value;
    if (cur == null) return;
    _abortCurrent = true;
    Get.find<ModelController>().pauseDownload(cur.filename);
  }

  /// Cancels the running download and empties the queue.
  void cancelAll() {
    queue.clear();
    cancelCurrent();
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      final mc = Get.find<ModelController>();
      while (queue.isNotEmpty) {
        final next = queue.first;
        queue.removeAt(0);
        current.value = next;
        if (!mc.isDownloaded(next.filename)) {
          await mc.downloadModel(next);
          // Native downloads return as soon as they start; wait for the end.
          final started = DateTime.now();
          while (mc.isDownloadingModel(next.filename) && !_abortCurrent) {
            await Future<void>.delayed(const Duration(seconds: 2));
            if (DateTime.now().difference(started).inHours >= 6) break;
          }
          await mc.refreshDownloaded();
        }
        _abortCurrent = false;
      }
    } finally {
      _abortCurrent = false;
      current.value = null;
      _pumping = false;
    }
  }
}
