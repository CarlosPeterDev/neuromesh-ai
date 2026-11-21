import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// User-initiated Save As. Android uses one-document SAF consent and read-back
/// verification; it does not grant the agent access to the destination folder.
class OutputFileService {
  static Future<String?> save(File file) async {
    final size = await file.length();
    if (size == 0 || size > 200 * 1024 * 1024) {
      throw StateError('Choose a nonempty output smaller than 200 MB.');
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final name = file.uri.pathSegments.last;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final result = await const MethodChannel('com.neuromesh.ai/device')
          .invokeMapMethod<String, dynamic>('saveOutputFile', {
        'path': file.path,
        'name': name,
        'sha256': digest,
      });
      if (result == null) return null;
      if (result['verified'] != true ||
          result['sha256'] != digest ||
          result['bytes'] != size ||
          result['uri'] is! String ||
          !result['uri'].startsWith('content://')) {
        throw StateError('The destination did not verify the saved file.');
      }
      return result['uri'] as String;
    }
    final path = await FilePicker.saveFile(
        dialogTitle: 'Save $name',
        fileName: name,
        bytes: await file.readAsBytes());
    if (path == null) return null;
    final destination = File(path);
    await file.copy(destination.path);
    if (await destination.length() != size ||
        (await sha256.bind(destination.openRead()).first).toString() !=
            digest) {
      throw StateError('The saved file did not match the original.');
    }
    return path;
  }
}
