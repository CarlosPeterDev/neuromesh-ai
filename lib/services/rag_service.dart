import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/bm25.dart';
import 'document_extractor_service.dart';
import 'hive_service.dart';

class RagDoc {
  final String id;
  final String name;
  final int chunks;
  RagDoc(this.id, this.name, this.chunks);
}

/// "Chat with your documents", fully offline. Documents are split into
/// chunks and the best-matching chunks (keyword/BM25 ranking) are added to
/// the prompt. It is keyword search, not semantic search.
class RagService extends GetxService {
  static const _kEnabled = 'rag_enabled';
  final docs = <RagDoc>[].obs;
  final enabled = false.obs;
  final busy = false.obs;
  final _cache = <String, List<String>>{};

  HiveService get _hive => Get.find<HiveService>();

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/rag');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  @override
  void onInit() {
    super.onInit();
    enabled.value = _hive.getSetting<bool>(_kEnabled, defaultValue: false) ?? false;
    _scan();
  }

  Future<void> setEnabled(bool v) async {
    enabled.value = v;
    await _hive.setSetting(_kEnabled, v);
  }

  Future<void> _scan() async {
    final out = <RagDoc>[];
    for (final f in (await _dir()).listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        out.add(RagDoc(m['id'] as String, m['name'] as String,
            (m['chunks'] as List).length));
      } catch (_) {}
    }
    docs.assignAll(out);
  }

  /// Returns a message for the UI.
  Future<String> addDocument() async {
    final res = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'docx', 'txt', 'md', 'csv', 'json'],
        withData: false);
    final path = res?.files.single.path;
    if (path == null) return 'Cancelled.';
    busy.value = true;
    try {
      final name = path.split('/').last;
      final ext = name.contains('.') ? name.split('.').last : 'txt';
      final text = await DocumentExtractorService.extractText(path, ext);
      final chunks = chunkText(text);
      if (chunks.isEmpty) return 'No readable text found in $name.';
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final f = File('${(await _dir()).path}/$id.json');
      await f.writeAsString(jsonEncode({'id': id, 'name': name, 'chunks': chunks}));
      await _scan();
      return 'Added $name (${chunks.length} passages).';
    } catch (e) {
      return 'Could not read that file: $e';
    } finally {
      busy.value = false;
    }
  }

  Future<void> remove(RagDoc d) async {
    final f = File('${(await _dir()).path}/${d.id}.json');
    if (await f.exists()) await f.delete();
    _cache.remove(d.id);
    await _scan();
  }

  Future<List<String>> _chunksOf(String id) async {
    final hit = _cache[id];
    if (hit != null) return hit;
    final f = File('${(await _dir()).path}/$id.json');
    final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final list = (m['chunks'] as List).cast<String>();
    _cache[id] = list;
    return list;
  }

  /// Wraps [prompt] with the best passages, or returns it unchanged.
  Future<String> augment(String prompt, String question) async {
    if (!enabled.value || docs.isEmpty) return prompt;
    try {
      final all = <({String doc, String text})>[];
      for (final d in docs) {
        for (final c in await _chunksOf(d.id)) {
          all.add((doc: d.name, text: c));
        }
      }
      final top = bm25Top(all.map((e) => e.text).toList(), question, k: 4);
      if (top.isEmpty) return prompt;
      final b = StringBuffer(
          'Use these passages from the user\'s documents when they help. '
          'If they do not contain the answer, say so.\n');
      for (final i in top) {
        b.writeln('\n[${all[i].doc}]\n${all[i].text}');
      }
      b.writeln('\nQuestion: $prompt');
      return b.toString();
    } catch (_) {
      return prompt;
    }
  }
}
