import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/services/app_log_service.dart';
import 'package:neuromesh_ai/services/cluster_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const api = MethodChannel('llama_flutter_android/cluster');

  test('failed native worker start clears role and permits retry', () async {
    final temp = await Directory.systemTemp.createTemp('worker_lifecycle');
    Hive.init(temp.path);
    Get.put(await HiveService().init());
    Get.put(AppLogService());
    final cluster = Get.put(ClusterService());
    final calls = <String>[];
    var running = false;
    var fail = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(api, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'startWorker':
          if (fail)
            throw PlatformException(
                code: 'WORKER_START', message: 'Port unavailable');
          running = true;
        case 'workerStatus':
          return {'state': running ? 'running' : 'stopped'};
        case 'stopWorker':
          running = false;
      }
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(api, null);
      Get.reset();
      await Hive.close();
      await temp.delete(recursive: true);
    });

    await cluster.startWorker();
    expect(cluster.role, ClusterRole.off);
    expect(cluster.worker.value.state, 'error');
    expect(cluster.worker.value.error, 'Port unavailable');
    fail = false;
    await Future.wait(
        [cluster.startWorker(), cluster.setRole(ClusterRole.off)]);
    expect(calls.where((name) => name == 'startWorker'), hasLength(2));
    expect(calls.where((name) => name == 'stopWorker'), hasLength(1));
    expect(cluster.role, ClusterRole.off);
    expect(cluster.worker.value.state, 'stopped');
  });
}
