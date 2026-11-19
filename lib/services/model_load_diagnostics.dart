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
    'ramLowThreshold',
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
  final _clock = Stopwatch()..start();
  final _timeline = <Map<String, Object?>>[];

  final Map<String, Object?> _fields = {
    'schemaVersion': 2,
    'startedUtc': DateTime.now().toUtc().toIso8601String(),
  };
  bool _checkpointed = false;

  static String? parameterLabel(String name) =>
      _parameterPattern.firstMatch(name)?.group(1)?.toUpperCase();

  bool get includeHelpers => _fields['includeHelpers'] != false;

  void set(String key, Object? value) {
    if (value == null) return;
    if (value is String) {
      final safe = diagnosticText(value);
      _fields[key] = safe.length <= 8192 ? safe : '${safe.substring(0, 8192)}…';
    } else {
      _fields[key] = value;
    }
  }

  void stage(String name) {
    if (_fields['stage'] == name) return;
    set('stage', name);
    if (_timeline.length == 32) _timeline.removeAt(0);
    _timeline.add({
      'elapsedMs': _clock.elapsedMilliseconds,
      'stage': diagnosticText(name),
    });
  }

  Future<void> _captureDevice(String prefix) async {
    if (!Get.isRegistered<DeviceBridge>()) return;
    try {
      final device = await Get.find<DeviceBridge>()
          .status()
          .timeout(const Duration(seconds: 1));
      for (final key in _deviceFields) {
        final value = device[key];
        if (value is num && value >= 0) set('${prefix}_$key', value);
      }
      for (final key in ['charging', 'saver', 'lowMemory']) {
        final value = device[key];
        if (value is bool) set('${prefix}_$key', value);
      }
    } catch (_) {
      // Diagnostic sampling must not block inference.
    }
  }

  Map<String, Object?> _snapshot() => {
        ..._fields,
        'elapsedMs': _clock.elapsedMilliseconds,
        'timeline': List.of(_timeline),
      };

  Future<void> checkpoint(String name) async {
    stage(name);
    if (!_checkpointed) await _captureDevice('beforeLoad');
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
    await _write(pendingKey, _snapshot());
  }

  Future<void> finish({String? error, String? details}) async {
    if (error != null) {
      final failedAt = DateTime.now().toUtc();
      final failedAfter = _clock.elapsedMilliseconds;
      await _captureDevice('atFailure');
      set('error', error);
      set('details', details);
      set('failedUtc', failedAt.toIso8601String());
      set('failedAfterMs', failedAfter);
      await _write(failureKey, _snapshot());
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
