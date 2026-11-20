import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/constants.dart';
import '../models/ai_model.dart';
import 'gguf_metadata.dart';

String visionModelFamily(String name) => name
    .toLowerCase()
    .replaceFirst(RegExp(r'\.gguf$'), '')
    .replaceAll(RegExp(r'(^|[-_. ])mmproj(?=$|[-_. ])'), '-')
    .replaceAll(RegExp(r'^[-_. ]+|[-_. ]+$'), '')
    .replaceFirst(RegExp(r'(^|[-_. ])(?:i?q[0-9][a-z0-9_]*|bf16|f16|f32)$'), '')
    .replaceAll(RegExp(r'[-_. ]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

typedef VisionHelperSource = ({String repository, String path, String family});

/// Verifies known projectors even when the original filename is generic.
class InstalledVisionHelpers {
  static const _artemis = 'turintech/Qwen3.5-0.8B-Artemis-GGUF';
  static final artemisFamily =
      visionModelFamily(AppConstants.artemisStarter['filename']!);
  static const _artemisProjectors = <int, ({String path, String sha256})>{
    207346272: (
      path: 'mmproj-BF16.gguf',
      sha256:
          '8fa5933772e64b56d96509b902b70119ce01fd21462f42d8fbb2c8acf0c354a5',
    ),
    204986976: (
      path: 'mmproj-F16.gguf',
      sha256:
          '07f95999c776a30fc0e2106dc1ad62f110eb745b3f4d7d4de644ec72c19399e3',
    ),
  };

  final _fingerprints = <String, Future<String>>{};

  Future<bool> _hasHeader(String path) async {
    try {
      return await hasGgufSignature(path);
    } on FileSystemException {
      return false;
    }
  }

  Future<String?> fingerprint(String path, {FileStat? fileStat}) async {
    try {
      final file = File(path);
      final stat = fileStat ?? await file.stat();
      if (stat.type != FileSystemEntityType.file) return null;
      final key = '$path:${stat.modified.microsecondsSinceEpoch}:${stat.size}';
      return await _fingerprints.putIfAbsent(key,
          () async => (await sha256.bind(file.openRead()).first).toString());
    } on FileSystemException {
      return null;
    }
  }

  Future<VisionHelperSource?> identify(String path) async {
    try {
      final stat = await File(path).stat();
      final expected = _artemisProjectors[stat.size];
      if (expected == null || !await _hasHeader(path)) return null;
      if (await fingerprint(path, fileStat: stat) == expected.sha256) {
        return (
          repository: _artemis,
          path: expected.path,
          family: artemisFamily
        );
      }
    } on FileSystemException {
      // A file may be removed while the model list is refreshing.
    }
    return null;
  }

  Future<String?> find(AiModel model, Map<String, String> candidates,
      {bool Function(String filename)? matchesMetadata}) async {
    if (model.runtime != AiModel.runtimeLlama ||
        !model.filename.toLowerCase().endsWith('.gguf') ||
        model.fileRole.isHelper) return null;

    final installedLink = candidates[model.mmprojFilename];
    if (installedLink != null && await _hasHeader(installedLink)) {
      return model.mmprojFilename;
    }
    final families = {
      visionModelFamily(model.filename),
      ...?model.artifact?.names.map(visionModelFamily),
    }..remove('');
    if (families.isEmpty) return null;
    final named = <String>[];
    for (final entry in candidates.entries) {
      if ((families.contains(visionModelFamily(entry.key)) ||
              matchesMetadata?.call(entry.key) == true) &&
          await _hasHeader(entry.value)) {
        named.add(entry.key);
      }
    }
    if (named.length == 1) return named.single;

    if (!families.contains(artemisFamily)) return null;
    for (final entry in candidates.entries) {
      if ((await identify(entry.value))?.family == artemisFamily) {
        return entry.key;
      }
    }
    return null;
  }
}
