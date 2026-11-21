import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:neuromesh_ai/services/voice_clone_store.dart';
import 'package:neuromesh_ai/services/voice_service.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'saved clone reference is real WAV; invalid paths and symlinks cannot load',
      () async {
    final root = await Directory.systemTemp.createTemp('clone-store-');
    final before = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    try {
      final store = VoiceCloneStore();
      expect(
          await store.save(
              'My voice', Float32List.fromList([0, .5, -.5]), 16000),
          'My voice');
      final saved = File('${root.path}/voices/My voice.wav');
      expect(await saved.exists(), true);
      expect(decodeWav(await saved.readAsBytes())?.samples.length, 3);
      expect((await store.load('My voice'))?.rate, 16000);
      await expectLater(store.load('../My voice'), throwsArgumentError);
      await expectLater(store.remove('../My voice'), throwsArgumentError);
      if (!Platform.isWindows) {
        await Link('${root.path}/voices/Linked.wav').create(saved.path);
        await store.scan();
        expect(store.voices, isNot(contains('Linked')));
        expect(await store.load('Linked'), isNull);
      }
    } finally {
      PathProviderPlatform.instance = before;
      await root.delete(recursive: true);
    }
  });
}
