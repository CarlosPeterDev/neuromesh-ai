import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:neuromesh_ai/services/lan_network.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/cluster_service.dart';
import 'package:neuromesh_ai/services/mcp_oauth.dart';
import 'package:neuromesh_ai/services/model_transfer_service.dart';
import 'package:neuromesh_ai/services/workload_placement.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('LAN candidates prefer physical Wi-Fi and hotspot, and skip tunnels',
      () {
    final entries = sortLanEndpoints([
      (address: '10.0.0.2', interfaceName: 'tun0'),
      (address: '192.168.1.15', interfaceName: 'wlan0'),
      (address: '192.168.43.1', interfaceName: 'ap0'),
      (address: '192.168.1.15', interfaceName: 'eth0'),
      (address: '10.1.2.3', interfaceName: 'rmnet_data0'),
    ]);
    expect(entries.map((entry) => entry.address),
        ['192.168.1.15', '192.168.43.1']);
  });

  test('transfer prefers the closest physical source address on retry', () {
    expect(
        lanSourceAddresses('192.168.1.7', [
          (address: '10.0.0.5', interfaceName: 'wlan0'),
          (address: '192.168.1.5', interfaceName: 'eth0'),
          (address: '192.168.1.7', interfaceName: 'eth1'),
          (address: '192.168.1.6', interfaceName: 'tun0'),
        ]),
        ['192.168.1.5', '10.0.0.5']);
  });

  test('transfer HTTP connections can bind a specific local source', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client =
          lanHttpClient(sourceAddress: InternetAddress.loopbackIPv4.address);
      try {
        server.listen((request) async {
          request.response.write(request.connectionInfo?.remoteAddress.address);
          await request.response.close();
        });
        final response = await client.get(Uri(
            scheme: 'http', host: server.address.address, port: server.port));
        expect(response.body, InternetAddress.loopbackIPv4.address);
      } finally {
        client.close();
        await server.close(force: true);
      }
    }, _LanTestHttpOverrides());
  });

  test('transfer route error gives recovery steps without the pairing URL', () {
    final error = http.ClientException('No route to host',
        Uri.parse('http://192.168.1.7:8765/list?token=abcdefghjk23'));
    final message = transferErrorMessage(error);
    expect(message, contains('no local route'));
    expect(message, contains('hotspot'));
    expect(message, isNot(contains('abcdefghjk23')));
  });

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

  test('pairing checks the rediscovered address when a worker changes IP',
      () async {
    final dir = await Directory.systemTemp.createTemp('cluster_pairing');
    Hive.init(dir.path);
    Get.put(await HiveService().init());
    final cluster = ClusterService();
    const channel = MethodChannel('llama_flutter_android/cluster');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final probes = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'probe') {
        final endpoint = call.arguments['endpoint'] as String;
        probes.add(endpoint);
        return endpoint == '192.168.236.11:50052';
      }
      if (call.method == 'discover') {
        return [
          {'host': '192.168.236.11', 'port': 50052, 'id': 'test-worker'},
        ];
      }
      throw MissingPluginException();
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      Get.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });

    expect(await cluster.addManual('8.8.8.8:50052'), isNotNull);
    expect(
        await cluster.addFromQr(
            'neuromesh://worker?host=192.168.236.10&port=50052&id=test-worker'),
        isNull);
    expect(probes, ['192.168.236.10:50052', '192.168.236.11:50052']);
    expect(cluster.workers.single.host, '192.168.236.11');

    probes.clear();
    expect(
        await cluster.addFromQr(
            'neuromesh://worker?host=192.168.236.10&port=50052'
            '&id=test-worker&alt=192.168.236.11,8.8.8.8'),
        isNull);
    expect(probes, ['192.168.236.10:50052', '192.168.236.11:50052']);
    expect(cluster.workers.single.host, '192.168.236.11');

  });

  test('a refused cluster connection tells the master the port is closed',
      () async {
    final dir = await Directory.systemTemp.createTemp('cluster_refused');
    Hive.init(dir.path);
    Get.put(await HiveService().init());
    final cluster = ClusterService();
    const channel = MethodChannel('llama_flutter_android/cluster');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'probe') return false;
      if (call.method == 'probeDiagnostic') return 'refused';
      throw MissingPluginException();
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      Get.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });

    expect(await cluster.addManual('192.168.236.10:50052'),
        contains('no worker is listening on that port'));
    expect(cluster.workers, isEmpty);
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

class _LanTestHttpOverrides extends HttpOverrides {}
