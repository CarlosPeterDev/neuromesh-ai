import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:neuromesh_ai/services/background_work_notifications.dart';
import 'package:neuromesh_ai/services/chat_calculator.dart';
import 'package:neuromesh_ai/services/chat_tool_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.neuromesh.ai/background_work');
  final sent = <MethodCall>[];
  late BackgroundWorkNotifications notifications;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    sent.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      sent.add(call);
      return null;
    });
    notifications = BackgroundWorkNotifications()..init();
  });

  tearDown(() {
    channel.setMethodCallHandler(null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> stop(String id) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('stop', id)),
      (_) {},
    );
  }

  test('notification actions stop only their own live operation', () async {
    final stopped = <BackgroundWork>[];
    final image = notifications.begin(BackgroundWork.image, () {
      stopped.add(BackgroundWork.image);
    })!;
    final relay = notifications.begin(BackgroundWork.relay, () {
      stopped.add(BackgroundWork.relay);
    })!;
    await stop(image);
    await stop(image);
    expect(stopped, [BackgroundWork.image]);
    notifications.finish(relay);
    await stop(relay);
    expect(stopped, [BackgroundWork.image]);
    expect(sent.map((call) => call.method), ['start', 'start', 'finish']);
    expect(sent.last.arguments, relay);
  });

  test('Stop closes an active Pollinations request', () async {
    final dir = await Directory.systemTemp.createTemp('pollinations-stop-');
    Hive.init(dir.path);
    Get.put(await HiveService().init());
    Get.put(notifications);
    addTearDown(() async {
      Get.reset();
      await Hive.close();
      await dir.delete(recursive: true);
    });
    final client = _PendingRequest();
    final abort = Completer<void>();
    final tools = ChatToolService();
    final response = http.runWithClient(
      () => tools.executeChatTool(
        const ParsedToolCall(
            'generate_image', {'prompt': 'A vintage spaceport'}, ''),
        (_, __, ___) async => true,
        abort: abort.future,
        cancelled: () => abort.isCompleted,
        onStop: abort.complete,
      ),
      () => client,
    );
    await client.started.future;
    final action = sent.single.arguments as Map;
    expect(action['kind'], 'image');
    await stop(action['id'] as String);
    expect(client.closed, isTrue);
    expect(await response, startsWith('Error:'));
  });
}

class _PendingRequest extends http.BaseClient {
  final started = Completer<void>();
  final response = Completer<http.StreamedResponse>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    started.complete();
    return response.future;
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    response.completeError(http.ClientException('Request cancelled'));
  }
}
