import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:neuromesh_ai/services/telegram_report_delivery.dart';

class _TelegramClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(request.url.host, 'api.telegram.org');
    expect(request.url.path, endsWith('/sendDocument'));
    expect(request.followRedirects, false);
    final multipart = request as http.MultipartRequest;
    expect(multipart.fields['chat_id'], '-1234');
    final file = multipart.files.single;
    expect(file.filename, endsWith('.zip'));
    final archive = ZipDecoder().decodeBytes(await file.finalize().toBytes());
    expect(archive.files.single.name, 'diagnostics.txt');
    expect(utf8.decode(archive.files.single.content), 'بلاغ تجريبي');
    return http.StreamedResponse(Stream.value(utf8.encode('{"ok":true}')), 200);
  }
}

void main() {
  test('stores direct settings securely and posts the exact report as a ZIP',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final token = '12345678:${List.filled(35, 'x').join()}';
    expect(TelegramReportDelivery.parse(token, 'bad chat'), isNull);
    final delivery = TelegramReportDelivery.parse(token, ' -1234 ')!;
    await delivery.save();
    final saved = await TelegramReportDelivery.load();
    expect(saved?.chatId, '-1234');
    final response = await saved!.send('بلاغ تجريبي', _TelegramClient());
    expect(response.statusCode, 200);
    await TelegramReportDelivery.clear();
    expect(await TelegramReportDelivery.load(), isNull);
  });
}
