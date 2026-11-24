import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:neuromesh_ai/services/app_log_service.dart';
import 'package:neuromesh_ai/services/background_work_notifications.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/inference_android.dart';
import 'package:neuromesh_ai/services/inference_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late InferenceService inference;
  late _TestEngine engine;
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('inference-priority-');
    Hive.init(directory.path);
    Get.put(await HiveService().init());
    Get.put(AppLogService());
    engine = _TestEngine();
    inference = InferenceService.withEngine(() => engine);
    expect(
        await inference.loadModel('${directory.path}/fixture.gguf'), 'Loaded');
  });

  tearDown(() async {
    await inference.unloadModel();
    Get.reset();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final source in ['title', 'capability-check']) {
    test('interactive visual planning preempts $source', () async {
      final background =
          inference.generate(prompt: 'Background', source: source);
      expect(await engine.started.future, source);
      final foreground = inference.generate(
        prompt: 'A vintage spaceport on a postcard, please.',
        source: InferenceService.visualPlanSource,
      );
      expect(await foreground, 'artwork');
      expect(await background, isEmpty);
      expect(engine.stops, 1);
      expect(engine.sources, [source, InferenceService.visualPlanSource]);
    });
  }

  test('a scheduled title yields while an interactive turn takes the engine',
      () async {
    final foreground = inference.generate(prompt: 'Foreground');
    final title = inference.generate(prompt: 'Background', source: 'title');
    expect(await title, isEmpty);
    expect(await foreground, 'artwork');
    expect(engine.sources, ['chat']);
  });

  test('Stop model cancels inference and releases the loaded local model',
      () async {
    await inference.unloadModel();
    engine = _TestEngine();
    inference = InferenceService.withEngine(() => engine);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    const channel = MethodChannel('com.neuromesh.ai/background_work');
    final started = Completer<Map>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (call.method == 'start') started.complete(call.arguments as Map);
      return null;
    });
    Get.put(BackgroundWorkNotifications()).init();
    addTearDown(() {
      channel.setMethodCallHandler(null);
      debugDefaultTargetPlatformOverride = null;
    });

    expect(
        await inference.loadModel('${directory.path}/fixture.gguf'), 'Loaded');
    final action = await started.future;
    expect(action['kind'], 'model');
    final active =
        inference.generate(prompt: 'Generate a title', source: 'title');
    await engine.started.future;
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('stop', action['id'])),
      (_) {},
    );
    expect(await active, isEmpty);
    expect(inference.isModelLoaded.value, isFalse);
    expect(engine.stops, 1);
    expect(engine.disposals, 1);
  });
}

class _TestEngine implements InferenceEngine {
  final started = Completer<String>();
  final pending = Completer<String>();
  final sources = <String>[];
  int stops = 0;
  int disposals = 0;

  @override
  bool get ggufVisionLoaded => false;

  @override
  Future<ContextInfo?> getContextInfo() async => null;

  @override
  Future<void> stop() async {
    stops++;
    if (!pending.isCompleted) pending.complete('');
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #loadModel) {
      return Future.value(LoadResult(success: true, message: 'Loaded'));
    }
    if (invocation.memberName == #generate) {
      final source = invocation.namedArguments[#source] as String;
      sources.add(source);
      if (!started.isCompleted) started.complete(source);
      return source == 'title' || source == 'capability-check'
          ? pending.future
          : Future.value('artwork');
    }
    return super.noSuchMethod(invocation);
  }
}
