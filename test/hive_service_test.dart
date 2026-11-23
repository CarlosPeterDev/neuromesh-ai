import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/services/hive_service.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hive_service_test');
    Hive.init(dir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('startup cleanup keeps current server settings', () async {
    final box = await Hive.openBox(AppConstants.settingsBox);
    await box.put(AppConstants.keyServerAllowNetwork, true);
    await box.put(AppConstants.keyServerUseApiKey, true);
    await box.put(AppConstants.keyServerApiKey, 'aichat_abc');
    await box.put('server_obsolete_provider', 'x');
    await box.close();

    final hive = await HiveService().init();

    expect(hive.getSetting<bool>(AppConstants.keyServerAllowNetwork), isTrue);
    expect(hive.getSetting<bool>(AppConstants.keyServerUseApiKey), isTrue);
    expect(hive.getSetting<String>(AppConstants.keyServerApiKey), 'aichat_abc');
    expect(hive.settingsBox.containsKey('server_obsolete_provider'), isFalse);
  });

  test('legacy setting types fall back without modifying stored values',
      () async {
    final hive = await HiveService().init();
    await hive.setSetting('legacy', 'old-type');
    expect(hive.getSetting<int>('legacy', defaultValue: 20), 20);
    expect(hive.getSetting<String>('legacy'), 'old-type');
  });

  test('a corrupted storage file is preserved when initialization fails',
      () async {
    final hive = await HiveService().init();
    await hive.saveSession('session', {'id': 'session', 'title': 'preserve'});
    await Hive.close();
    final file =
        File('${dir.path}/${AppConstants.chatSessionsBox.toLowerCase()}.hive');
    final bytes = await file.readAsBytes();
    final damaged = [...bytes]..[bytes.length - 1] ^= 0xff;
    await file.writeAsBytes(damaged);
    await expectLater(HiveService().init(), throwsA(isA<HiveError>()));
    expect(await file.readAsBytes(), damaged);
    await file.writeAsBytes(bytes);
    final recovered = await HiveService().init();
    expect(recovered.getAllSessions().single['title'], 'preserve');
  });
}
