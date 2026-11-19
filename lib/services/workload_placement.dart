import 'dart:convert';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import 'hive_service.dart';
import 'lan_network.dart';

enum PhoneWorkload {
  speech('Text to speech', '/speech'),
  transcription('Speech recognition', '/transcribe'),
  image('Image generation', '/image');

  const PhoneWorkload(this.label, this.path);
  final String label;
  final String path;
}

class WorkloadCancelled implements Exception {
  const WorkloadCancelled();
}

/// Retains handlers on the pending request so a late failure after cancellation
/// cannot become an unhandled asynchronous error.
Future<T> withWorkerCancellation<T>(
        Future<T> request, Future<void>? cancelled) =>
    cancelled == null
        ? request
        : Future.any([
            request,
            cancelled.then<T>((_) => throw const WorkloadCancelled()),
          ]);

class WorkloadWorker {
  final Uri address;
  final String token;

  const WorkloadWorker._(this.address, this.token);

  static WorkloadWorker? parse(String address, String token) {
    final uri = Uri.tryParse(address.trim());
    final code = token.trim();
    if (uri == null ||
        uri.scheme != 'http' ||
        !isPrivateLanAddress(uri.host) ||
        !uri.hasPort ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !RegExp(r'^[a-f0-9]{16,32}$').hasMatch(code)) {
      return null;
    }
    return WorkloadWorker._(uri.replace(path: ''), code);
  }

  Future<Uint8List> request(String path,
      {Object? payload,
      String contentType = 'application/json',
      Duration timeout = const Duration(seconds: 120),
      Map<String, String>? query,
      Future<void>? cancelled,
      http.Client? httpClient,
      int maxBytes = 16 * 1024 * 1024}) async {
    final client = httpClient ?? lanHttpClient();
    try {
      final pending = (() async {
        final request = http.Request(payload == null ? 'GET' : 'POST',
            address.replace(path: path, queryParameters: query))
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer $token';
        if (payload != null) {
          request.headers['Content-Type'] = contentType;
          if (payload is Uint8List) {
            request.bodyBytes = payload;
          } else {
            request.body = jsonEncode(payload);
          }
        }
        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw StateError(response.statusCode == 409
              ? 'The worker model is unavailable or busy.'
              : 'The worker returned HTTP ${response.statusCode}.');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const FormatException('The worker response is too large.');
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      })()
          .timeout(timeout);
      return await withWorkerCancellation(pending, cancelled);
    } finally {
      if (httpClient == null) client.close();
    }
  }

  Future<List<String>> capabilities() async {
    final bytes = await request('/capabilities',
        timeout: const Duration(seconds: 6), maxBytes: 4096);
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map || data['app'] != 'neuromesh') {
      throw const FormatException('This address is not a NeuroMesh worker.');
    }
    return (data['ready'] as List).whereType<String>().toList();
  }
}

class WorkloadPlacement {
  static WorkloadWorker? forWorkload(PhoneWorkload workload) {
    if (!Get.isRegistered<HiveService>()) return null;
    final hive = Get.find<HiveService>();
    final fields =
        hive.getSetting<Map>('workload_${workload.name}_worker_token');
    return WorkloadWorker.parse(
      fields?['address'] as String? ?? '',
      fields?['token'] as String? ?? '',
    );
  }

  static Future<void> assign(
      PhoneWorkload workload, WorkloadWorker? worker) async {
    final hive = Get.find<HiveService>();
    await hive.setSetting(
      'workload_${workload.name}_worker_token',
      worker == null
          ? null
          : {
              'address': worker.address.toString(),
              'token': worker.token,
            },
    );
  }
}
