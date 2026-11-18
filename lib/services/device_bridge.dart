import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/chat_controller.dart';
import 'desktop_diagnostics.dart';

/// Battery + thermal watching and "share to NeuroMesh" text intake.
class DeviceBridge extends GetxService {
  static const _ch = MethodChannel('com.neuromesh.ai/device');

  final batteryLevel = (-1).obs;
  final charging = false.obs;
  final batterySaver = false.obs;
  /// Android PowerManager thermal status: 0 none … 3 severe … 6 shutdown.
  final thermal = 0.obs;

  Timer? _timer;

  @override
  void onInit() {
    super.onInit();
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'sharedTextReady') await _takeShared();
    });
    refresh();
    _takeShared();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }

  Future<void> refresh() async {
    try {
      final b = await _ch.invokeMapMethod<String, dynamic>('batteryInfo');
      if (b != null) {
        batteryLevel.value = (b['level'] as num?)?.toInt() ?? -1;
        charging.value = b['charging'] == true;
        batterySaver.value = b['saver'] == true;
      }
      thermal.value = (await _ch.invokeMethod<int>('thermalStatus')) ?? 0;
    } catch (_) {
      // Not on Android or the bridge is unavailable: leave defaults.
    }
  }

  Future<String> nativeLibDir() async =>
      (await _ch.invokeMethod<String>('nativeLibDir')) ?? '';

  /// Decodes mp3/m4a/ogg/wav/mp4… to 16 kHz mono floats (null if unsupported).
  Future<Float32List?> decodeAudio(String path) async {
    final out = await _ch.invokeMethod<String>('decodeAudio', {'path': path, 'rate': 16000});
    if (out == null) return null;
    final f = File(out);
    final bytes = await f.readAsBytes();
    await f.delete();
    final bd = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    final r = Float32List(n);
    for (var i = 0; i < n; i++) {
      r[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return r;
  }

  /// Read-only phone facts (battery, storage, memory, network, temperature).
  Future<Map<String, dynamic>> status() async {
    if (!Platform.isAndroid) return desktopDiagnostics();
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('deviceStatus');
      return m ?? <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _takeShared() async {
    try {
      final fresh = await _ch.invokeMethod<bool>('takeNewChat');
      if (fresh == true && Get.isRegistered<ChatController>()) {
        Get.find<ChatController>().createNewChat();
      }
      final text = await _ch.invokeMethod<String>('takeSharedText');
      if (text == null || text.isEmpty || !Get.isRegistered<ChatController>()) {
        return;
      }
      final chat = Get.find<ChatController>();
      chat.createNewChat();
      chat.textController.text = text;
    } catch (_) {}
  }

  bool get lowBattery =>
      !charging.value &&
      ((batteryLevel.value >= 0 && batteryLevel.value <= 15) ||
          batterySaver.value);
  bool get hot => thermal.value >= 3;

  /// One-line advice for the UI, or null when everything is fine.
  String? get advisory {
    if (hot) {
      return 'Your phone is running hot. Pause for a minute or use a smaller model.';
    }
    if (lowBattery) {
      return 'Battery is low. Short replies and smaller models save power.';
    }
    return null;
  }
}

