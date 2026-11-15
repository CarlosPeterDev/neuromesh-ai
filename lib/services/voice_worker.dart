import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:get/get.dart';

import 'hive_service.dart';
import 'voice_service.dart';

/// Lets a stronger phone speak (with the cloned voice) for another phone on
/// the same Wi-Fi. Plain HTTP on the local network, protected by a token.
/// Keep NeuroMesh AI open on the worker phone while it is serving.
class VoiceWorkerServer extends GetxService {
  static const port = 8765;
  final running = false.obs;
  final token = ''.obs;
  final address = ''.obs;
  final requests = 0.obs;
  final lastError = ''.obs;
  HttpServer? _server;

  Future<String> _ip() async {
    final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
    for (final i in ifs) {
      for (final a in i.addresses) {
        if (!a.isLoopback) return a.address;
      }
    }
    return '';
  }

  String _newToken() {
    final r = math.Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Future<void> start() async {
    if (running.value) return;
    lastError.value = '';
    final hive = Get.find<HiveService>();
    var t = hive.getSetting<String>('voice_worker_serve_token') ?? '';
    if (t.isEmpty) {
      t = _newToken();
      await hive.setSetting('voice_worker_serve_token', t);
    }
    token.value = t;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } catch (e) {
      lastError.value = 'Could not start: $e';
      return;
    }
    address.value = 'http://${await _ip()}:$port';
    running.value = true;
    _server!.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    running.value = false;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.headers.value('authorization') != 'Bearer ${token.value}') {
        res.statusCode = 401;
        await res.close();
        return;
      }
      final voice = Get.find<VoiceService>();
      if (req.method == 'GET' && req.uri.path == '/ping') {
        res.write('ok');
      } else if (req.method == 'PUT' && req.uri.path == '/voice') {
        final bytes = await _readBody(req, 8 * 1024 * 1024);
        final wav = decodeWav(bytes);
        if (wav == null) {
          res.statusCode = 400;
        } else {
          voice.setCloneVoice(wav.samples, wav.rate);
        }
      } else if (req.method == 'POST' && req.uri.path == '/tts') {
        final body = jsonDecode(utf8.decode(await _readBody(req, 64 * 1024)))
            as Map<String, dynamic>;
        final text = (body['text'] ?? '').toString();
        if (!voice.cloneLoaded || !voice.hasCloneVoice) {
          res.statusCode = 409; // worker not ready (no model / no voice)
        } else if (text.trim().isEmpty || text.length > 600) {
          res.statusCode = 400;
        } else {
          // Let the UI isolate breathe between requests.
          final r = voice.synthesize(text);
          if (r == null) {
            res.statusCode = 500;
          } else {
            requests.value++;
            res.headers.contentType = ContentType('audio', 'wav');
            res.add(encodeWav(r.samples, r.rate));
          }
        }
      } else {
        res.statusCode = 404;
      }
    } catch (e) {
      lastError.value = '$e';
      res.statusCode = 500;
    }
    await res.close();
  }

  Future<Uint8List> _readBody(HttpRequest req, int max) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in req) {
      b.add(chunk);
      if (b.length > max) throw Exception('Request too large');
    }
    return b.takeBytes();
  }

  @override
  void onClose() {
    _server?.close(force: true);
    super.onClose();
  }
}
