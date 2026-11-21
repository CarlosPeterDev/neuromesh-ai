import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:neuromesh_ai/core/constants.dart';
import 'package:neuromesh_ai/services/android_opencode.dart';
import 'package:neuromesh_ai/services/app_log_service.dart';
import 'package:neuromesh_ai/services/hive_service.dart';
import 'package:neuromesh_ai/services/inference_service.dart';
import 'package:neuromesh_ai/services/openai_server_service_io.dart';
import 'package:neuromesh_ai/services/opencode_server_client.dart';

void main() {
  final modelPath = Platform.environment['NEUROMESH_TEST_OPENCODE_MODEL'];
  final cliPath = Platform.environment['NEUROMESH_TEST_OPENCODE_CLI'];
  test('Android OpenCode server client uses a real local GGUF on Linux',
      () async {
    final root = await Directory.systemTemp.createTemp('opencode-gguf-');
    final workspace = await root.createTemp('workspace-');
    final fixture = File('${workspace.path}/fixture.txt');
    await fixture.writeAsString('pineapple-47');
    Hive.init(root.path);
    final hive = Get.put(await HiveService().init());
    Get.put(AppLogService());
    final inference = Get.put(InferenceService());
    await hive.setSetting(AppConstants.keyContextSize, 8192);
    final loaded = await inference.loadModel(modelPath!, modelName: 'Artemis');
    expect(inference.isModelLoaded.value, isTrue, reason: loaded);
    final bridge =
        OpenAiServerService.forAgentModel('Artemis', allowTools: true);
    addTearDown(() async {
      await bridge.stop();
      await inference.unloadModel();
      await Hive.close();
      Get.reset();
      await root.delete(recursive: true);
    });
    await bridge.start(port: 0, apiKey: 'local-gguf-test');
    final environment = {
      'HOME': '${root.path}/opencode-home',
      'PATH': '/usr/local/bin:/usr/bin:/bin',
      'OPENCODE_DISABLE_PROJECT_CONFIG': 'true',
      'OPENCODE_DISABLE_DEFAULT_PLUGINS': 'true',
      'OPENCODE_DISABLE_EXTERNAL_SKILLS': 'true',
      'OPENCODE_DISABLE_LSP_DOWNLOAD': 'true',
      'OPENCODE_DISABLE_MODELS_FETCH': 'true',
      'OPENCODE_DISABLE_AUTOUPDATE': 'true',
      'OPENCODE_SERVER_PASSWORD': 'server-test-key',
      'NEUROMESH_BRIDGE_KEY': 'local-gguf-test',
      'OPENCODE_CONFIG_CONTENT': OpenCodeLocalProfile.localProviderConfig(
          name: 'Artemis', context: 8192, endpoint: '${bridge.localUrl}/v1'),
    };
    final reserved = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = reserved.port;
    await reserved.close();
    final child = await Process.start(cliPath!,
        ['serve', '--pure', '--hostname', '127.0.0.1', '--port', '$port'],
        workingDirectory: workspace.path,
        includeParentEnvironment: false,
        environment: environment);
    addTearDown(() async {
      child.kill();
      await child.exitCode;
    });
    final ready = Completer<void>();
    final stdout = child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (!ready.isCompleted && line.contains('listening')) ready.complete();
    });
    addTearDown(stdout.cancel);
    unawaited(child.stderr.drain<void>());
    await ready.future.timeout(const Duration(seconds: 20));
    final client = OpenCodeServerClient(
        'http://127.0.0.1:$port', 'opencode', 'server-test-key');
    addTearDown(client.close);
    expect(await client.verify(), OpenCodeServerClient.supportedVersion);
    final model = (await client.models())
        .singleWhere((model) => model.provider == 'neuromesh');
    final chat = await client.createSession();
    final text = StringBuffer();
    await client.send(chat, model, 'Reply with exactly the word seven.',
        onText: text.write, onTool: (_) {});
    expect(text.toString().toLowerCase(), contains('seven'));
    final read = await client.createSession(allowWorkspaceReads: true);
    final tools = <String>[];
    await client.send(
      read,
      model,
      'Use the read tool to read ${fixture.path} and tell me exactly what it contains.',
      onText: (_) {},
      onTool: tools.add,
    );
    expect(tools, contains('read · completed'));
    expect((await client.history(read)).last.text, contains('pineapple-47'));
  },
      skip: !Platform.isLinux || modelPath == null || cliPath == null
          ? 'Requires Linux, OpenCode v1.19.6 and a local GGUF.'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
