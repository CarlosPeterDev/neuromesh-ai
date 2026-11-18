import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class TelegramReportDelivery {
  static const _storage = FlutterSecureStorage();
  static const _key = 'neuromesh_diagnostic_telegram_destination';
  final String _token;
  final String chatId;

  TelegramReportDelivery._(this._token, this.chatId);

  static TelegramReportDelivery? parse(String token, String chatId) {
    final cleanToken = token.trim();
    final cleanId = chatId.trim();
    if (!RegExp(r'^\d+:[A-Za-z0-9_-]{20,}$').hasMatch(cleanToken) ||
        !RegExp(r'^-?[1-9][0-9]{0,18}$').hasMatch(cleanId)) return null;
    return TelegramReportDelivery._(cleanToken, cleanId);
  }

  static Future<TelegramReportDelivery?> load() async {
    final raw = await _storage.read(key: _key);
    if (raw == null) return null;
    final values = jsonDecode(raw);
    if (values is! Map) return null;
    return parse(
        values['token'] as String? ?? '', values['chatId'] as String? ?? '');
  }

  Future<void> save() => _storage.write(
        key: _key,
        value: jsonEncode({'token': _token, 'chatId': chatId}),
      );

  static Future<void> clear() => _storage.delete(key: _key);

  Future<http.Response> send(String report, http.Client client) async {
    final data = utf8.encode(report);
    final zip = ZipEncoder().encodeBytes(
      Archive()..addFile(ArchiveFile('diagnostics.txt', data.length, data)),
    );
    final request = http.MultipartRequest(
      'POST',
      Uri.https('api.telegram.org', '/bot$_token/sendDocument'),
    )
      ..followRedirects = false
      ..fields['chat_id'] = chatId
      ..fields['disable_notification'] = 'true'
      ..files.add(http.MultipartFile.fromBytes(
        'document',
        zip,
        filename:
            'NeuroMesh-diagnostics-${DateTime.now().millisecondsSinceEpoch}.zip',
      ));
    return client.send(request).then(http.Response.fromStream);
  }
}
