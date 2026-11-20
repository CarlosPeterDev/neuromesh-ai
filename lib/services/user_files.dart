import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'document_extractor_service.dart';
import 'hive_service.dart';

class GrantedFolder {
  final String uri;
  final String name;
  const GrantedFolder(this.uri, this.name);
  Map<String, String> toMap() => {'uri': uri, 'name': name};
}

class FolderEntry {
  final String name;
  final bool isDir;
  final int size;
  const FolderEntry(this.name, this.isDir, this.size);
}

/// Folders the user chose in Android's own folder picker. The app can only
/// reach what is inside them (no broad storage permission), and the user can
/// revoke a folder at any time.
class UserFilesService extends GetxService {
  static const _ch = MethodChannel('com.neuromesh.ai/device');
  static const _key = 'granted_folders';

  final folders = <GrantedFolder>[].obs;

  @override
  void onInit() {
    super.onInit();
    final raw = Get.find<HiveService>().getSetting<List>(_key) ?? const [];
    folders.value = [
      for (final m in raw.whereType<Map>())
        GrantedFolder((m['uri'] ?? '').toString(), (m['name'] ?? '').toString())
    ].where((f) => f.uri.isNotEmpty).toList();
  }

  Future<void> _save() => Get.find<HiveService>()
      .setSetting(_key, folders.map((f) => f.toMap()).toList());

  /// Opens the folder picker. Returns the folder added, or null if cancelled.
  Future<GrantedFolder?> addFolder() async {
    final r = await _ch.invokeMapMethod<String, dynamic>('pickFolder');
    if (r == null) return null;
    final uri = (r['uri'] ?? '').toString();
    if (uri.isEmpty) return null;
    final existing = folders.firstWhereOrNull((f) => f.uri == uri);
    if (existing != null) return existing;
    final f = GrantedFolder(uri, (r['name'] ?? 'Folder').toString());
    folders.add(f);
    await _save();
    return f;
  }

  Future<void> removeFolder(GrantedFolder f) async {
    folders.removeWhere((x) => x.uri == f.uri);
    await _save();
    try {
      await _ch.invokeMethod('releaseFolder', {'uri': f.uri});
    } catch (_) {}
  }

  /// Finds a granted folder by the name the model used (case-insensitive).
  /// An omitted name selects the only granted folder, if there is one.
  GrantedFolder? find(String? name) {
    if (folders.isEmpty) return null;
    if (name == null || name.trim().isEmpty) {
      return folders.length == 1 ? folders.first : null;
    }
    final n = name.trim().toLowerCase();
    final matches = folders.where((f) => f.name.toLowerCase() == n);
    return matches.length == 1 ? matches.single : null;
  }

  Future<List<FolderEntry>> list(GrantedFolder f, String path) async {
    final r = await _ch
        .invokeListMethod<Map>('listFolder', {'uri': f.uri, 'path': path});
    return [
      for (final m in r ?? const <Map>[])
        FolderEntry((m['name'] ?? '').toString(), m['isDir'] == true,
            (m['size'] as num?)?.toInt() ?? 0)
    ];
  }

  /// Reads a file as text. PDF and DOCX are converted to text; other binary
  /// files return a short description instead of garbage.
  Future<String> readText(GrantedFolder f, String path,
      {int maxChars = 6000, bool requireComplete = false}) async {
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    final big = ext == 'pdf' || ext == 'docx';
    if (big && requireComplete) {
      throw const FormatException('Only plain text files can be edited.');
    }
    final r = await _ch.invokeMapMethod<String, dynamic>('readFile', {
      'uri': f.uri,
      'path': path,
      'maxBytes': big ? 4 * 1024 * 1024 : maxChars * 4,
    });
    if (r == null) {
      if (requireComplete)
        throw StateError('Could not read the complete file.');
      return 'Error: could not read the file.';
    }
    final bytes = r['bytes'] as Uint8List;
    final size = (r['size'] as num?)?.toInt() ?? bytes.length;
    final truncated = r['truncated'] == true;
    if (requireComplete && truncated) {
      throw const FormatException('This file is too large to edit safely.');
    }
    String text;
    if (big) {
      if (truncated)
        return 'Error: this $ext is too large to read (${_kb(size)}).';
      text = await DocumentExtractorService.extractTextFromBytes(bytes, ext);
    } else if (looksBinary(bytes)) {
      if (requireComplete) {
        throw const FormatException('Only plain text files can be edited.');
      }
      return '(binary file, ${_kb(size)}; cannot show as text)';
    } else {
      text = utf8.decode(bytes, allowMalformed: !requireComplete);
    }
    if (text.length > maxChars) {
      if (requireComplete) {
        throw const FormatException('This file is too large to edit safely.');
      }
      return '${text.substring(0, maxChars)}\n…(showing $maxChars of ${text.length} characters)';
    }
    return truncated ? '$text\n…(file continues)' : text;
  }

  Future<void> writeText(GrantedFolder f, String path, String content) async {
    final success = await _ch.invokeMethod<bool>('writeFile', {
      'uri': f.uri,
      'path': path,
      'bytes': Uint8List.fromList(utf8.encode(content))
    });
    if (success != true) {
      throw StateError('The shared folder did not confirm the write.');
    }
  }

  Future<String> mutateFile(GrantedFolder folder, String path, String action,
      {String content = '', String newName = ''}) async {
    final result = await _ch.invokeMethod<String>('mutateSharedFile', {
      'uri': folder.uri,
      'path': path,
      'action': action,
      if (action == 'append') 'bytes': Uint8List.fromList(utf8.encode(content)),
      if (action == 'rename') 'name': newName,
    });
    if (result == null)
      throw StateError('The shared folder did not confirm the change.');
    return result;
  }

  static String _kb(int b) => b < 1024 * 1024
      ? '${(b / 1024).toStringAsFixed(0)} KB'
      : '${(b / 1048576).toStringAsFixed(1)} MB';
}

/// True when [bytes] look like a binary file (NUL bytes or many control chars).
bool looksBinary(List<int> bytes) {
  final n = bytes.length < 2000 ? bytes.length : 2000;
  if (n == 0) return false;
  var bad = 0;
  for (var i = 0; i < n; i++) {
    final b = bytes[i];
    if (b == 0) return true;
    if (b < 9 || (b > 13 && b < 32)) bad++;
  }
  return bad / n > 0.1;
}
