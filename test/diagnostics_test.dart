import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/services/diagnostics_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/model_load_diagnostics.dart';
import 'package:neuromesh_ai/utils/chat_io.dart';

void main() {
  test('ZIP contains exactly the report preview, including Unicode', () {
    const preview = 'Model diagnostics\nالنموذج: مثال\n';
    final zip = ZipDecoder().decodeBytes(DiagnosticsService.encodeZip(preview));
    expect(zip.files, hasLength(1));
    expect(zip.files.single.name, 'diagnostics.txt');
    expect(utf8.decode(zip.files.single.content), preview);
  });

  test('redacts URLs, provider tokens and parent directories', () {
    final fakeToken = '123456789:${List.filled(35, 'A').join()}';
    final output = diagnosticText(
      'https://example.com/private?a=1 $fakeToken /storage/emulated/0/model.gguf',
    );
    expect(output, '[URL] [REDACTED BOT TOKEN] [path]/model.gguf');
  });

  test('parameter labels are optional and distinguish model sizes', () {
    expect(
        ModelLoadDiagnostics.parameterLabel('Qwen2.5-1.5B-Instruct'), '1.5B');
    expect(ModelLoadDiagnostics.parameterLabel('Mixtral-8x7B'), '8X7B');
    expect(ModelLoadDiagnostics.parameterLabel('my_model-q4_k_m.gguf'), isNull);
  });

  test('recovers interrupted loads and clears successful checkpoints',
      () async {
    final dir = await Directory.systemTemp.createTemp('load_diagnostics');
    Hive.init(dir.path);
    addTearDown(() async {
      Get.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });

    Get.put(await HiveService().init());
    final first = ModelLoadDiagnostics()..set('model', 'interrupted');
    await first.checkpoint('initialize GPU');
    await Hive.close();
    Get.reset();
    final reopened = Get.put(await HiveService().init());
    expect(reopened.getSetting<Map>(ModelLoadDiagnostics.pendingKey)?['stage'],
        'initialize GPU');

    final next = ModelLoadDiagnostics()..set('model', 'retry');
    await next.checkpoint('initialize CPU');
    await next.finish();
    expect(reopened.getSetting<Map>(ModelLoadDiagnostics.pendingKey), isNull);
    expect(reopened.getSetting<Map>(ModelLoadDiagnostics.failureKey)?['model'],
        'interrupted');

    final failure = ModelLoadDiagnostics()..set('model', 'bad file');
    await failure.finish(error: 'Invalid header');
    expect(reopened.getSetting<Map>(ModelLoadDiagnostics.failureKey)?['error'],
        'Invalid header');
  });

  test('excludes diagnostic history from regular backups', () {
    expect(
        stripSecrets({
          ModelLoadDiagnostics.failureKey: {'error': 'sample'},
          ModelLoadDiagnostics.pendingKey: {'stage': 'sample'},
          'theme': 'dark',
        }),
        {'theme': 'dark'});
  });
}
