import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../utils/model_file_role.dart';
import 'gguf_metadata.dart';

String? artifactRepository(String value) {
  final url = huggingFaceRepository(value.trim());
  if (url != null) return url;
  if (RegExp(r'^[A-Za-z0-9][\w.-]*/[A-Za-z0-9][\w.-]*$')
      .hasMatch(value.trim())) {
    return value.trim();
  }
  return null;
}

class ModelArtifactReader {
  final _cache =
      <String, ({DateTime modified, int size, ModelArtifact artifact})>{};

  Future<ModelArtifact?> read(String path) async {
    final lower = path.toLowerCase();
    if (!lower.endsWith('.gguf') && !lower.endsWith('.safetensors'))
      return null;
    try {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) return null;
      final cached = _cache[path];
      if (cached != null &&
          cached.modified == stat.modified &&
          cached.size == stat.size) return cached.artifact;
      final artifact = lower.endsWith('.gguf')
          ? _gguf(await readGgufArtifactFields(path))
          : await _safetensors(path, stat.size);
      _cache[path] =
          (modified: stat.modified, size: stat.size, artifact: artifact);
      return artifact;
    } on Exception {
      return null;
    }
  }

  ModelArtifact _gguf(Map<String, Object?> fields) {
    final names = <String>{
      for (final key in ['general.name', 'general.basename'])
        if (fields[key] case final String value
            when value.trim().isNotEmpty && value.length <= 300)
          value,
    };
    final baseNames = <String>{};
    final repos = <String>{};
    final baseRepos = <String>{};
    for (final entry in fields.entries) {
      final value = entry.value;
      if (value is! String || value.trim().isEmpty || value.length > 300) {
        continue;
      }
      final key = entry.key;
      if (key.endsWith('.repo_url') || key.endsWith('.url')) {
        final repo = artifactRepository(value);
        if (repo != null) {
          if (key.startsWith('general.base_model.')) {
            baseRepos.add(repo);
          } else if (const {
            'general.repo_url',
            'general.url',
            'general.source.repo_url',
            'general.source.url'
          }.contains(key)) {
            repos.add(repo);
          }
        }
      }
      if (key.startsWith('general.base_model.') &&
          (key.endsWith('.name') || key.endsWith('.basename'))) {
        baseNames.add(value);
      }
    }
    final architecture = fields['general.architecture'];
    final role = switch (fields['general.type']) {
      'adapter' => ModelFileRole.adapter,
      'mmproj' || 'projector' => ModelFileRole.projector,
      _
          when architecture == 'clip' &&
              fields['clip.has_text_encoder'] == true &&
              fields['clip.has_vision_encoder'] == false =>
        ModelFileRole.imageAddon,
      _ when fields['adapter.type'] != null => ModelFileRole.adapter,
      _
          when architecture == 'clip' &&
              (fields['clip.projector_type'] != null ||
                  fields['clip.has_vision_encoder'] == true) =>
        ModelFileRole.projector,
      _
          when architecture == 'clip' &&
              fields['clip.has_text_encoder'] == true =>
        ModelFileRole.imageAddon,
      _ => null,
    };
    return ModelArtifact(
        role: role,
        names: names,
        baseNames: baseNames,
        repositories: repos,
        baseRepositories: baseRepos);
  }

  Future<ModelArtifact> _safetensors(String path, int size) async {
    final file = await File(path).open();
    try {
      final prefix = await file.read(8);
      if (prefix.length != 8) return const ModelArtifact();
      final length = ByteData.sublistView(prefix).getUint64(0, Endian.little);
      if (length <= 0 || length > 8 * 1024 * 1024 || length > size - 8) {
        return const ModelArtifact();
      }
      final parsed = jsonDecode(utf8.decode(await file.read(length)));
      if (parsed is! Map<String, dynamic>) return const ModelArtifact();
      final meta = parsed['__metadata__'];
      final names = <String>{};
      final bases = <String>{};
      final repos = <String>{};
      final architecture = meta is Map ? meta['modelspec.architecture'] : null;
      if (meta is Map) {
        final name = meta['modelspec.title'];
        if (name is String && name.length <= 300) names.add(name);
        for (final key in [
          'ss_sd_model_name',
          'base_model_name_or_path',
          'modelspec.base_model',
          'base_model'
        ]) {
          final value = meta[key];
          if (value is! String || value.isEmpty || value.length > 300) continue;
          final repo = artifactRepository(value);
          if (repo == null) {
            bases.add(value);
          } else {
            repos.add(repo);
          }
        }
      }
      final isLora = (architecture is String &&
              architecture.toLowerCase().contains('lora')) ||
          parsed.keys.any((key) => RegExp(
                  r'(?:[._]lora_[ab]|\.lora_(?:up|down)\.)',
                  caseSensitive: false)
              .hasMatch(key));
      final isVae = parsed.keys.any((key) => key.startsWith('encoder.')) &&
          parsed.keys.any((key) => key.startsWith('decoder.')) &&
          parsed.keys.any((key) =>
              key.startsWith('quant_conv.') ||
              key.startsWith('post_quant_conv.'));
      return ModelArtifact(
        role: isLora
            ? ModelFileRole.adapter
            : isVae
                ? ModelFileRole.imageAddon
                : null,
        names: names,
        baseNames: bases,
        baseRepositories: repos,
      );
    } finally {
      await file.close();
    }
  }
}
