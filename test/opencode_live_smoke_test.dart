import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/services/app_log_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/inference_service.dart';
import 'package:neuromesh_ai/services/opencode_adapter_io.dart';

void main() {
  final modelPath = Platform.environment['NEUROMESH_TEST_OPENCODE_MODEL'];
  test(
    'OpenCode in Xfce Terminal streams a reply from the real GGUF engine',
    () async {
      final settings =
          await Directory.systemTemp.createTemp('neuromesh-live-test-');
      Hive.init(settings.path);
      final hive = Get.put(await HiveService().init());
      Get.put(AppLogService());
      final inference = Get.put(InferenceService());
      addTearDown(() async {
        await inference.unloadModel();
        await Hive.close();
        Get.reset();
        await settings.delete(recursive: true);
      });
      await hive.setSetting(AppConstants.keyContextSize, 8192);
      final loaded =
          await inference.loadModel(modelPath!, modelName: 'Artemis');
      expect(inference.isModelLoaded.value, isTrue, reason: loaded);

      final adapter = OpenCodeAdapter();
      final installation = await adapter.discover();
      expect(installation.compatible, isTrue);
      expect(installation.terminalAvailable, isTrue);
      final session = await adapter.openTerminal(
        installation: installation,
        modelName: inference.loadedModelName.value,
        contextTokens: inference.contextTokensTotal.value,
      );
      addTearDown(session.disconnect);

      Future<String> xdotool(List<String> arguments) async {
        final result = await Process.run('xdotool', arguments);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return result.stdout.toString().trim();
      }

      final windows = await xdotool(
        ['search', '--sync', '--onlyvisible', '--class', 'Xfce4-terminal'],
      ).timeout(const Duration(seconds: 15));
      final window = windows.split('\n').first;
      addTearDown(() async {
        await xdotool(['windowkill', window]);
        await session.exitCode;
      });
      await xdotool(['windowfocus', '--sync', window]);
      // Let the TUI switch the pseudoterminal to raw mode before entering input.
      await Future<void>.delayed(const Duration(seconds: 5));
      await xdotool(['type', '--delay', '70', 'Reply with the word seven.']);
      final pendingReply = inference.streamingText.stream
          .firstWhere((text) =>
              RegExp(r'\bseven\b', caseSensitive: false).hasMatch(text))
          .timeout(const Duration(seconds: 40));
      await xdotool(['key', 'Return']);
      final reply = await pendingReply;
      expect(reply, contains(RegExp('seven', caseSensitive: false)));
    },
    skip: !Platform.isLinux || modelPath == null
        ? 'Requires a Linux desktop, OpenCode, Xfce Terminal, xdotool and a GGUF.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
