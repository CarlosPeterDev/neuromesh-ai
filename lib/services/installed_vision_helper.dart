import 'dart:io';

import 'package:crypto/crypto.dart';

import '../models/ai_model.dart';
import '../utils/model_file_role.dart';
import 'gguf_metadata.dart';

String visionModelFamily(String name) => name
    .toLowerCase()
    .replaceFirst(RegExp(r'\.gguf$'), '')
    .replaceAll(RegExp(r'(^|[-_. ])mmproj(?=$|[-_. ])'), '-')
    .replaceAll(RegExp(r'^[-_. ]+|[-_. ]+$'), '')
    .replaceFirst(RegExp(r'(^|[-_. ])(?:i?q[0-9][a-z0-9_]*|bf16|f16|f32)$'), '')
    .replaceAll(RegExp(r'[-_. ]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

/// A bare precision name such as mmproj-BF16.gguf carries no model identity.
class InstalledVisionHelpers {
  static const _artemisProjectors = <int, String>{
    207346272:
        '8fa5933772e64b56d96509b902b70119ce01fd21462f42d8fbb2c8acf0c354a5',
    204986976:
        '07f95999c776a30fc0e2106dc1ad62f110eb745b3f4d7d4de644ec72c19399e3',
  };

  final _fingerprints = <String, Future<String>>{};

  Future<bool> _hasHeader(String path) async {
    try {
      return await hasGgufSignature(path);
    } on FileSystemException {
      return false;
    }
  }

  Future<String?> find(AiModel model, Map<String, String> candidates) async {
    if (model.runtime != AiModel.runtimeLlama ||
        !model.filename.toLowerCase().endsWith('.gguf') ||
        modelFileRole(model.filename).isHelper) return null;

    final installedLink = candidates[model.mmprojFilename];
    if (installedLink != null && await _hasHeader(installedLink)) {
      return model.mmprojFilename;
    }
    final family = visionModelFamily(model.filename);
    if (family.isEmpty) return null;
    final named = <String>[];
    for (final entry in candidates.entries) {
      if (visionModelFamily(entry.key) == family &&
          await _hasHeader(entry.value)) {
        named.add(entry.key);
      }
    }
    if (named.length == 1) return named.single;

    if (family != 'qwen3-5-0-8b-artemis') return null;
    for (final entry in candidates.entries) {
      try {
        final file = File(entry.value);
        final stat = await file.stat();
        final expected = _artemisProjectors[stat.size];
        if (expected == null || !await _hasHeader(entry.value)) continue;
        final key =
            '${entry.value}:${stat.modified.microsecondsSinceEpoch}:${stat.size}';
        final actual = await _fingerprints.putIfAbsent(key,
            () async => (await sha256.bind(file.openRead()).first).toString());
        if (actual == expected) return entry.key;
      } on FileSystemException {
        // A file may be removed while the model list is refreshing.
      }
    }
    return null;
  }
}
