import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:neuromesh_ai/services/inference_service.dart';
import 'package:neuromesh_ai/services/opencode_adapter_io.dart';

import 'openai_server_service_test.dart' show FakeInference;

void main() {
  group('Linux OpenCode adapter', () {
    late Directory directory;
    late OpenCodeAdapter adapter;
    late File profilePath;
    late File originalConfig;

    Future<void> executable(String name, String script) async {
      final file = File('${directory.path}/$name');
      await file.writeAsString('#!/bin/sh\n$script\n');
      expect((await Process.run('/bin/chmod', ['700', file.path])).exitCode, 0);
    }

    setUp(() async {
      directory =
          await Directory.systemTemp.createTemp('neuromesh-adapter-test-');
      profilePath = File('${directory.path}/profile-path');
      originalConfig = File('${directory.path}/.config/opencode/opencode.json');
      await originalConfig.create(recursive: true);
      await originalConfig.writeAsString('{"theme":"original-user-config"}');
      adapter = OpenCodeAdapter(environment: {
        'PATH': directory.path,
        'HOME': directory.path,
        'DISPLAY': ':92',
        'OPENCODE_CONFIG': originalConfig.path,
        'SAMPLE_PROVIDER_SECRET': 'do-not-inherit',
      });
      Get.put<InferenceService>(FakeInference());
    });

    tearDown(() async {
      Get.reset();
      await directory.delete(recursive: true);
    });

    test(
        'detects executable versions and marks unverified versions incompatible',
        () async {
      expect((await adapter.discover()).executable, isNull);
      await executable('opencode', 'echo 1.2.3');
      await executable('xfce4-terminal', 'exit 0');
      final installation = await adapter.discover();
      expect(installation.executable, '${directory.path}/opencode');
      expect(installation.version, '1.2.3');
      expect(installation.compatible, isFalse);
    });

    test(
        'failed config verification cleans up the session and preserves user settings',
        () async {
      await executable('opencode', '''
if [ "\$1" = --version ]; then echo ${OpenCodeAdapter.verifiedVersion}; exit 0; fi
printf '%s' "\$HOME" > '${profilePath.path}'
exit 1
''');
      await executable('xfce4-terminal', 'exit 2');
      final installation = await adapter.discover();
      expect(installation.compatible, isTrue);
      await expectLater(
        adapter.openTerminal(
          installation: installation,
          modelName: 'fake-model',
          contextTokens: 4096,
        ),
        throwsStateError,
      );
      expect(
          await Directory(await profilePath.readAsString()).exists(), isFalse);
      expect(await originalConfig.readAsString(),
          '{"theme":"original-user-config"}');
    });

    test(
        'launches terminal with temporary provider settings and removes session files',
        () async {
      await executable('opencode', '''
if [ "\$1" = --version ]; then echo ${OpenCodeAdapter.verifiedVersion}; exit 0; fi
test -z "\$OPENCODE_CONFIG" || exit 2
test -z "\$SAMPLE_PROVIDER_SECRET" || exit 3
test -n "\$NEUROMESH_BRIDGE_KEY" || exit 4
case "\$OPENCODE_CONFIG_CONTENT" in *'"tool_call":false'*) ;; *) exit 5 ;; esac
echo neuromesh/loaded
''');
      await executable('xfce4-terminal', '''
test "\$1" = --disable-server && test "\$2" = --execute || exit 6
test "\$PWD" = "\$HOME/workspace" || exit 7
test "\$5" = --model && test "\$6" = neuromesh/loaded || exit 8
printf '%s' "\$HOME" > '${profilePath.path}'
''');
      final session = await adapter.openTerminal(
        installation: await adapter.discover(),
        modelName: 'fake-model',
        contextTokens: 4096,
      );
      expect(await session.exitCode, 0);
      await session.disconnect();
      expect(
          await Directory(await profilePath.readAsString()).exists(), isFalse);
      expect(await originalConfig.readAsString(),
          '{"theme":"original-user-config"}');
    });
  }, skip: !Platform.isLinux);
}
