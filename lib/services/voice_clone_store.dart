import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import 'hive_service.dart';
import 'voice_service.dart';

/// The user's saved reference voices (short WAV recordings).
class VoiceCloneStore extends GetxService {
  static const _kActive = 'clone_voice_active';
  final voices = <String>[].obs;
  final active = ''.obs;

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/voices');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  @override
  void onInit() {
    super.onInit();
    active.value = Get.find<HiveService>().getSetting<String>(_kActive) ?? '';
    scan();
  }

  Future<void> scan() async {
    final names = (await _dir())
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('.wav'))
        .map((f) => f.uri.pathSegments.last.replaceFirst(RegExp(r'\.wav$'), ''))
        .toList()
      ..sort();
    voices.assignAll(names);
    if (active.value.isNotEmpty && !names.contains(active.value)) {
      active.value = '';
    }
  }

  String _clean(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '').trim();

  Future<String?> save(String name, Float32List samples, int rate) async {
    final n = _clean(name);
    if (n.isEmpty) return null;
    final f = File('${(await _dir()).path}/$n.wav');
    await f.writeAsBytes(encodeWav(samples, rate));
    await scan();
    return n;
  }

  Future<({Float32List samples, int rate})?> load(String name) async {
    if (name.isEmpty || _clean(name) != name)
      throw ArgumentError('Invalid saved voice name.');
    final f = File('${(await _dir()).path}/$name.wav');
    if (await FileSystemEntity.type(f.path, followLinks: false) !=
        FileSystemEntityType.file) return null;
    return decodeWav(await f.readAsBytes());
  }

  Future<void> remove(String name) async {
    if (name.isEmpty || _clean(name) != name)
      throw ArgumentError('Invalid saved voice name.');
    final f = File('${(await _dir()).path}/$name.wav');
    if (await f.exists()) await f.delete();
    if (active.value == name) await select('');
    await scan();
  }

  /// Makes [name] the voice used for cloned speech (empty = none).
  Future<void> select(String name) async {
    final reference = name.isEmpty ? null : await load(name);
    if (name.isNotEmpty && (reference == null || reference.samples.isEmpty))
      throw StateError('Saved voice is missing or invalid.');
    active.value = name;
    await Get.find<HiveService>().setSetting(_kActive, name);
    if (reference != null)
      Get.find<VoiceService>().setCloneVoice(reference.samples, reference.rate);
  }

  /// Loads the saved active voice into the speech engine at startup.
  Future<void> restoreActive() async {
    if (active.value.isNotEmpty) await select(active.value);
  }
}
