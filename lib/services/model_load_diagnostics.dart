import 'package:get/get.dart';

import '../core/redact.dart';
import 'device_bridge.dart';
import 'hive_service.dart';

/// Stores only the current load checkpoint and the last failure, so a native
/// crash or OS process kill can still be investigated after reopening the app.
class ModelLoadDiagnostics {
  static const pendingKey = 'diagnostics_model_load_pending';
  static const failureKey = 'diagnostics_model_load_failure';
  static const _deviceFields = [
    'ramTotal',
    'ramFree',
    'storageTotal',
    'storageFree',
    'thermal',
    'level',
  ];

  static final _parameterPattern = RegExp(
    r'(?:^|[^a-z0-9])((?:\d+x)?\d+(?:[._]\d+)?[bm])(?=$|[^a-z0-9])',
    caseSensitive: false,
  );

  final _hive = Get.find<HiveService>();
  final Map<String, Object?> _fields = {
    'startedUtc': DateTime.now().toUtc().toIso8601String(),
  };
  bool _checkpointed = false;

  static String? parameterLabel(String name) =>
      _parameterPattern.firstMatch(name)?.group(1)?.toUpperCase();

  void set(String key, Object? value) {
    if (value == null) return;
    _fields[key] = value is String ? diagnosticText(value) : value;
  }

  Future<void> checkpoint(String stage) async {
    set('stage', stage);
    if (!_checkpointed && Get.isRegistered<DeviceBridge>()) {
      try {
        final device = await Get.find<DeviceBridge>().status().timeout(
              const Duration(seconds: 1),
            );
        for (final key in _deviceFields) {
          final value = device[key];
          if (value is num && value >= 0) set('beforeLoad_$key', value);
        }
      } catch (_) {
        // Snapshot availability must never prevent inference.
      }
    }
    if (!_checkpointed) {
      final unfinished = _hive.getSetting<Map>(pendingKey);
      if (unfinished != null) {
        await _write(failureKey, {
          ...unfinished,
          'error': 'An earlier model load ended without recording a result.',
        });
      }
    }
    _checkpointed = true;
    await _write(pendingKey, Map<String, Object?>.of(_fields));
  }

  Future<void> finish({String? error, String? details}) async {
    if (error != null) {
      set('error', error);
      set('details', details);
      set('failedUtc', DateTime.now().toUtc().toIso8601String());
      await _write(failureKey, Map<String, Object?>.of(_fields));
    }
    if (_checkpointed) {
      _checkpointed = false;
      await _write(pendingKey, null);
    }
  }

  Future<void> _write(String key, Object? value) async {
    try {
      await _hive.setSetting(key, value);
    } catch (_) {
      // A full or unavailable settings store must not stop a model load.
    }
  }
}

String diagnosticText(String input) => redactSecrets(input)
    .replaceAll(RegExp(r'https?://[^\s<>"]+', caseSensitive: false), '[URL]')
    .replaceAll(
      RegExp(r'(?:file|content)://[^\s<>"]+', caseSensitive: false),
      '[local URI]',
    )
    .replaceAllMapped(
      RegExp(r'(?:/[\w.@%+~-]+){2,}'),
      (match) => '[path]/${match[0]!.split('/').last}',
    );
