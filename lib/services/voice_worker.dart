import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:get/get.dart';

import 'hive_service.dart';
import 'voice_service.dart';
import 'voice_models.dart';
import 'local_image_service.dart';
import 'lan_network.dart' show lanAddress;
import 'workload_placement.dart';

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
  bool _starting = false;

  String _newToken() {
    final r = math.Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  Future<void> start() async {
    if (running.value || _starting) return;
    _starting = true;
    lastError.value = '';
    try {
      final hive = Get.find<HiveService>();
      var code = hive.getSetting<String>('voice_worker_serve_token') ?? '';
      if (code.isEmpty) {
        code = _newToken();
        await hive.setSetting('voice_worker_serve_token', code);
      }
      final ip = await lanAddress();
      if (ip == null) {
        throw StateError('Connect to a private Wi-Fi network first.');
      }
      final server = await HttpServer.bind(InternetAddress(ip), port);
      _server = server;
      token.value = code;
      address.value = 'http://$ip:$port';
      running.value = true;
      server.listen(_handle, onError: (_) {});
    } catch (e) {
      lastError.value = 'Could not start: $e';
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    running.value = false;
  }

  final _working = <PhoneWorkload>{};

  List<String> get availableWorkloads {
    final voice = Get.find<VoiceService>();
    return [
      if (voice.pickInstalled(VoiceKind.tts) != null) PhoneWorkload.speech.name,
      if (voice.pickInstalled(VoiceKind.stt) != null)
        PhoneWorkload.transcription.name,
      if (Get.find<LocalImageService>().isModelLoaded.value)
        PhoneWorkload.image.name,
    ];
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
      } else if (req.method == 'GET' && req.uri.path == '/capabilities') {
        res.headers.contentType = ContentType.json;
        res.write(
            jsonEncode({'app': 'neuromesh', 'ready': availableWorkloads}));
      } else if (req.method == 'POST' &&
          PhoneWorkload.values.any((job) => job.path == req.uri.path)) {
        final job =
            PhoneWorkload.values.firstWhere((job) => job.path == req.uri.path);
        if (!availableWorkloads.contains(job.name) || !_working.add(job)) {
          res.statusCode = 409;
        } else {
          try {
            await _handleWorkload(job, req, voice);
          } finally {
            _working.remove(job);
          }
        }
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

  Future<void> _handleWorkload(
      PhoneWorkload job, HttpRequest req, VoiceService voice) async {
    final res = req.response;
    if (job == PhoneWorkload.transcription) {
      final wav = decodeWav(await _readBody(req, 3 * 1024 * 1024));
      if (wav == null || wav.rate != 16000 || wav.samples.isEmpty) {
        res.statusCode = 400;
        return;
      }
      final language = req.uri.queryParameters['language'] ?? '';
      final text = await voice.transcribeSamples(
        wav.samples,
        language: language,
        allowWorker: false,
      );
      res.headers.contentType = ContentType.text;
      res.write(text);
    } else {
      final body = jsonDecode(utf8.decode(await _readBody(req, 32 * 1024)));
      final text = body is Map ? body['text'] : null;
      if (text is! String || text.trim().isEmpty || text.length > 6000) {
        res.statusCode = 400;
        return;
      }
      if (job == PhoneWorkload.speech) {
        final lang = body['language'];
        final bytes = await voice.synthesizeToWav(text,
            lang: lang is String ? lang : '', allowWorker: false);
        res.headers.contentType = ContentType('audio', 'wav');
        res.add(bytes);
      } else {
        final bytes = await Get.find<LocalImageService>()
            .generateImage(prompt: text, allowWorker: false);
        if (bytes == null) {
          res.statusCode = 409;
          return;
        }
        res.headers.contentType = ContentType('image', 'png');
        res.add(bytes);
      }
    }
    requests.value++;
  }

  Future<Uint8List> _readBody(HttpRequest req, int max) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in req.timeout(const Duration(seconds: 10))) {
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
