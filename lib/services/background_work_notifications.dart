import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

enum BackgroundWork { image, relay }

/// Android keeps the process available while the app owns a cancellable job.
class BackgroundWorkNotifications {
  static const _channel = MethodChannel('com.neuromesh.ai/background_work');
  final _cancellations = <String, FutureOr<void> Function()>{};
  bool _askedForPermission = false;

  void init() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'stop' || call.arguments is! String) return;
      final cancel = _cancellations.remove(call.arguments);
      if (cancel != null) await cancel();
    });
  }

  String? begin(BackgroundWork work, FutureOr<void> Function() cancel) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final id = const Uuid().v4();
    _cancellations[id] = cancel;
    unawaited(_send('start', {'kind': work.name, 'id': id}));
    if (!_askedForPermission) {
      _askedForPermission = true;
      unawaited(Permission.notification
          .request()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    }
    return id;
  }

  void finish(String? id) {
    if (id == null || _cancellations.remove(id) == null) return;
    unawaited(_send('finish', id));
  }

  Future<void> _send(String method, Object arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      // Android can deny foreground promotion if the app is already hidden.
      debugPrint('Background notification unavailable: ${error.code}');
    } on MissingPluginException {
      // An older platform embedding has no Android notification transport.
    }
  }
}
