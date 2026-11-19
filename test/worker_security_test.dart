import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/mcp_oauth.dart';
import 'package:neuromesh_ai/services/model_transfer_service.dart';
import 'package:neuromesh_ai/services/workload_placement.dart';

void main() {
  test('transfer codes require the sender format and private IPv4', () {
    const token = 'abcdefghjk23';
    expect(
        ModelTransferClient.parse('192.168.1.7:8765/?token=$token'), isNotNull);
    for (final address in [
      'http://8.8.8.8:8765/?token=$token',
      'http://127.0.0.1:8765/?token=$token',
      'http://host.local:8765/?token=$token',
      'https://192.168.1.7:8765/?token=$token',
      'http://192.168.1.7:8765/file?token=$token',
      'http://192.168.1.7:8765/?token=$token&token=$token',
    ]) {
      expect(ModelTransferClient.parse(address), isNull, reason: address);
    }
  });

  test('workloads can be assigned to different authenticated LAN phones',
      () async {
    final dir = await Directory.systemTemp.createTemp('worker_placement');
    Hive.init(dir.path);
    addTearDown(() async {
      Get.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    Get.put(await HiveService().init());
    const token = 'a234567890abcdef';
    final a = WorkloadWorker.parse('http://192.168.2.10:8765', token)!;
    final b = WorkloadWorker.parse('http://192.168.2.11:8765', token)!;
    expect(WorkloadWorker.parse('http://1.2.3.4:8765', token), isNull);
    await WorkloadPlacement.assign(PhoneWorkload.speech, a);
    await WorkloadPlacement.assign(PhoneWorkload.transcription, b);
    expect(WorkloadPlacement.forWorkload(PhoneWorkload.speech)?.address,
        a.address);
    expect(WorkloadPlacement.forWorkload(PhoneWorkload.transcription)?.address,
        b.address);
    expect(WorkloadPlacement.forWorkload(PhoneWorkload.image), isNull);
    await WorkloadPlacement.assign(PhoneWorkload.speech, null);
    expect(WorkloadPlacement.forWorkload(PhoneWorkload.speech), isNull);
  });

  test('legacy OAuth tokens migrate out of Hive and sign-out removes them',
      () async {
    final dir = await Directory.systemTemp.createTemp('oauth_migration');
    Hive.init(dir.path);
    addTearDown(() async {
      Get.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    FlutterSecureStorage.setMockInitialValues({});
    final hive = Get.put(await HiveService().init());
    const url = 'https://example.com/mcp';
    final key = 'mcp_oauth_${base64Url.encode(utf8.encode(url))}';
    await hive.setSetting(key, jsonEncode({'access': 'sample'}));
    await McpOAuth.prepareSecureStorage();
    expect(hive.settingsBox.containsKey(key), isFalse);
    expect(await McpOAuth.accessToken(url), 'sample');
    await McpOAuth.signOut(url);
    expect(await McpOAuth.accessToken(url), isNull);
  });
}
