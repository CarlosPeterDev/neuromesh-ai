import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:neuromesh_ai/services/app_log_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/inference_android.dart';
import 'package:neuromesh_ai/services/inference_service.dart';

void main() {
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
}

class _TestEngine implements InferenceEngine {
  final started = Completer<String>();
  final pending = Completer<String>();
  final sources = <String>[];
  int stops = 0;

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
  Future<void> dispose() async {}

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
