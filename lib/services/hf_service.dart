import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class HfException implements Exception {
  final String message;
  HfException(this.message);
  @override
  String toString() => message;
}

/// A model repository on Hugging Face.
class HfRepo {
  final String id;
  final int downloads;
  final int likes;

  /// Gated repos need a Hugging Face login / licence acceptance first.
  final bool gated;

  const HfRepo({
    required this.id,
    this.downloads = 0,
    this.likes = 0,
    this.gated = false,
  });

  String get author => id.contains('/') ? id.split('/').first : '';
  String get name => id.contains('/') ? id.substring(id.indexOf('/') + 1) : id;

  factory HfRepo.fromJson(Map<String, dynamic> json) {
    final gated = json['gated'];
    return HfRepo(
      id: (json['id'] ?? json['modelId'] ?? '').toString(),
      downloads: (json['downloads'] as num?)?.toInt() ?? 0,
      likes: (json['likes'] as num?)?.toInt() ?? 0,
      gated: gated != null && gated != false,
    );
  }
}

/// True for files that are add-ons (VAE, LoRA, ControlNet...) and not a
/// full checkpoint.
bool isImageAddon(String lowerName) =>
    lowerName.contains('vae') ||
    lowerName.contains('lora') ||
    lowerName.contains('controlnet') ||
    lowerName.contains('embedding') ||
    lowerName.contains('taesd') ||
    lowerName.contains('refiner');

/// One .gguf file inside a repository.
class HfGgufFile {
  final String path;
  final int size;

  const HfGgufFile({required this.path, required this.size});

  String get filename => path.split('/').last;

  /// Multi-part models ("-00001-of-00003") are not supported by the
  /// single-file downloader.
  bool get isSplit => RegExp(r'-\d{5}-of-\d{5}').hasMatch(filename);

  /// Vision projector files are not chat models on their own.
  bool get isProjector => filename.toLowerCase().contains('mmproj');

  /// Quantisation label read from the file name (Q4_K_M, IQ3_XS, F16 ...),
  /// or an empty string if none is recognised.
  String get quant {
    final m = RegExp(
      r'(IQ\d_[A-Z0-9_]+|Q\d_[A-Z0-9_]+|Q\d_\d|BF16|F16|F32|Q\d)',
      caseSensitive: false,
    ).firstMatch(filename);
    return m == null ? '' : m.group(0)!.toUpperCase();
  }
}

/// Minimal client for Hugging Face's public (no key needed) model API.
class HfService {
  HfService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  static const _host = 'huggingface.co';
  static const _headers = {
    'User-Agent': 'NeuroMeshAI',
    'Accept': 'application/json',
  };

  /// GGUF repos matching [query], most downloaded first. An empty query
  /// returns the most downloaded GGUF repos overall.
  Future<List<HfRepo>> searchModels(String query,
      {int limit = 30, bool images = false}) async {
    final params = <String, String>{
      'filter': images ? 'text-to-image' : 'gguf',
      'sort': 'downloads',
      'direction': '-1',
      'limit': '$limit',
      if (query.trim().isNotEmpty) 'search': query.trim(),
    };
    final data = await _getJson(Uri.https(_host, '/api/models', params));
    if (data is! List) throw HfException('Unexpected reply from Hugging Face.');
    return data
        .whereType<Map<String, dynamic>>()
        .map(HfRepo.fromJson)
        .where((r) => r.id.isNotEmpty)
        .toList();
  }

  /// Downloadable single-file .gguf models in [repoId], smallest first.
  Future<List<HfGgufFile>> listGgufFiles(String repoId,
      {bool images = false}) async {
    final data = await _getJson(
      Uri.https(_host, '/api/models/$repoId/tree/main',
          {if (!images) 'recursive': 'true'}),
    );
    if (data is! List) throw HfException('Unexpected reply from Hugging Face.');
    final files = <HfGgufFile>[];
    for (final item in data.whereType<Map<String, dynamic>>()) {
      if (item['type'] != 'file') continue;
      final path = (item['path'] ?? '').toString();
      final lower = path.toLowerCase();
      if (images) {
        // Single-file checkpoints at the repo root only (not diffusers
        // folders), without add-ons the generator can't use on their own.
        if (!lower.endsWith('.safetensors') || path.contains('/')) continue;
        if (isImageAddon(lower)) continue;
      } else if (!lower.endsWith('.gguf')) {
        continue;
      }
      final lfs = item['lfs'];
      final size = (lfs is Map ? lfs['size'] : null) ?? item['size'];
      final file = HfGgufFile(path: path, size: (size as num?)?.toInt() ?? 0);
      if (!images && (file.isSplit || file.isProjector)) continue;
      // Phones can't hold huge image checkpoints.
      if (images && (file.size > 6 * 1024 * 1024 * 1024)) continue;
      files.add(file);
    }
    files.sort((a, b) => a.size.compareTo(b.size));
    return files;
  }

  static String downloadUrl(String repoId, String path) {
    final encoded = path.split('/').map(Uri.encodeComponent).join('/');
    return 'https://$_host/$repoId/resolve/main/$encoded';
  }

  Future<dynamic> _getJson(Uri uri) async {
    try {
      final res =
          await _client.get(uri, headers: _headers).timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) return jsonDecode(utf8.decode(res.bodyBytes));
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw HfException('This model needs a Hugging Face login.');
      }
      if (res.statusCode == 429) {
        throw HfException('Hugging Face is rate limiting requests. Try again in a minute.');
      }
      throw HfException('Hugging Face returned an error (${res.statusCode}).');
    } on HfException {
      rethrow;
    } on TimeoutException {
      throw HfException('Hugging Face took too long to answer.');
    } catch (_) {
      throw HfException('Could not reach Hugging Face. Check your internet connection.');
    }
  }

  void dispose() => _client.close();
}
