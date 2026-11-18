import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:uuid/uuid.dart';

import '../controllers/chat_controller.dart';
import '../core/constants.dart';
import '../utils/chat_io.dart';
import 'hive_service.dart';
import 'voice_clone_store.dart';

enum ClusterBackupPart {
  chats('Chats'),
  settings('App preferences'),
  files('Workspace files, revisions and saved voices');

  const ClusterBackupPart(this.label);
  final String label;
}

class ClusterBackup {
  static const maxBytes = 32 * 1024 * 1024;
  static const _roots = {
    'agent_files',
    'agent_projects',
    'agent_revisions',
    'voices'
  };
  static final _projectSetting = RegExp(r'^workspace_project_[a-zA-Z0-9_-]+$');
  static const _preferences = {
    'theme_mode',
    'font_size',
    'voice_lang',
    'voice_speed',
    'voice_barge_in',
    'auto_context',
    'wifi_only',
    'auto_title',
    AppConstants.keyTemperature,
    AppConstants.keyContextSize,
    AppConstants.keyMaxTokens,
  };

  static Uint8List randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
        List.generate(length, (_) => random.nextInt(256)));
  }

  static Uint8List _crypt(
      bool encrypt, Uint8List key, Uint8List nonce, Uint8List bytes) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
          encrypt,
          AEADParameters(KeyParameter(key), 128, nonce,
              Uint8List.fromList(utf8.encode('neuromesh-cluster-backup-v1'))));
    return cipher.process(bytes);
  }

  static Uint8List seal(Uint8List key, Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('This backup category exceeds 32 MiB.');
    }
    final nonce = randomBytes(12);
    final encrypted = _crypt(true, key, nonce, bytes);
    return Uint8List(12 + encrypted.length)
      ..setRange(0, 12, nonce)
      ..setRange(12, 12 + encrypted.length, encrypted);
  }

  static Uint8List open(Uint8List key, Uint8List bytes) {
    if (bytes.length < 28 || bytes.length > maxBytes + 28) {
      throw const FormatException('Invalid encrypted backup size.');
    }
    return _crypt(false, key, Uint8List.sublistView(bytes, 0, 12),
        Uint8List.sublistView(bytes, 12));
  }

  static bool isSafePath(String path) {
    final parts = path.split('/');
    return parts.length > 1 &&
        _roots.contains(parts.first) &&
        parts.every((p) =>
            p.isNotEmpty &&
            p != '.' &&
            p != '..' &&
            !p.endsWith('.') &&
            !p.endsWith(' ') &&
            !p.contains(RegExp(r'[<>:"|?*\\\x00-\x1f]')) &&
            !RegExp(r'^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:[.]|$)',
                    caseSensitive: false)
                .hasMatch(p));
  }

  static Future<Uint8List> build(ClusterBackupPart part, Uint8List key) async {
    final hive = Get.find<HiveService>();
    final data = <String, dynamic>{'kind': part.name};
    switch (part) {
      case ClusterBackupPart.chats:
        data['backup'] = buildBackup(
          sessions: hive.getAllSessions(),
          messages: hive.messagesBox.values
              .whereType<Map>()
              .map((m) => Map<dynamic, dynamic>.from(m)
                ..remove('imagePath')
                ..remove('filePath'))
              .toList(),
          settings: {
            for (final entry in hive.settingsBox.toMap().entries)
              if (_projectSetting.hasMatch('${entry.key}') &&
                  entry.value is String)
                '${entry.key}': entry.value,
          },
        );
      case ClusterBackupPart.settings:
        data['settings'] = {
          for (final key in _preferences)
            if (hive.settingsBox.containsKey(key))
              key: hive.settingsBox.get(key),
        };
      case ClusterBackupPart.files:
        final docs = await getApplicationDocumentsDirectory();
        final files = <String, String>{};
        var total = 0;
        for (final root in _roots) {
          final directory = Directory('${docs.path}/$root');
          if (await FileSystemEntity.type(directory.path, followLinks: false) !=
              FileSystemEntityType.directory) {
            continue;
          }
          await for (final entry
              in directory.list(recursive: true, followLinks: false)) {
            if (entry is! File) continue;
            final rel = entry.path
                .substring(docs.path.length + 1)
                .replaceAll('\\', '/');
            if (!isSafePath(rel)) continue;
            total += await entry.length();
            if (total > maxBytes * 3 ~/ 4) {
              throw const FormatException(
                  'Workspace and voice files exceed the backup limit.');
            }
            files[rel] = base64Encode(await entry.readAsBytes());
          }
        }
        data['files'] = files;
    }
    return seal(key, Uint8List.fromList(utf8.encode(jsonEncode(data))));
  }

  static Future<void> restore(Uint8List key, Uint8List packet) async {
    final data =
        jsonDecode(utf8.decode(open(key, packet))) as Map<String, dynamic>;
    final hive = Get.find<HiveService>();
    switch (ClusterBackupPart.values.byName(data['kind'] as String)) {
      case ClusterBackupPart.chats:
        final backup = parseBackup(data['backup'] as String);
        final ids = <String, String>{};
        const uuid = Uuid();
        for (final session in backup.sessions) {
          final old = session['id'] as String;
          final id = uuid.v4();
          ids[old] = id;
          await hive.saveSession(id, {...session, 'id': id});
          final project = backup.settings['workspace_project_$old'];
          if (project is String && project.length <= 60) {
            await hive.setSetting('workspace_project_$id', project);
          }
        }
        for (final message in backup.messages) {
          final chatId = ids[message['chatId']];
          if (chatId == null) continue;
          final id = uuid.v4();
          await hive.saveMessage(id, {
            ...message,
            'id': id,
            'chatId': chatId,
            'imagePath': null,
            'filePath': null,
          });
        }
        if (Get.isRegistered<ChatController>()) {
          Get.find<ChatController>().loadSessions();
        }
      case ClusterBackupPart.settings:
        final settings = data['settings'] as Map<String, dynamic>;
        for (final key in _preferences) {
          final value = settings[key];
          final current = hive.settingsBox.get(key);
          if (value != null &&
              (current == null || value.runtimeType == current.runtimeType) &&
              ((key == 'theme_mode' || key == 'voice_lang') &&
                      value is String ||
                  (key == AppConstants.keyMaxTokens ||
                          key == AppConstants.keyContextSize) &&
                      value is int &&
                      value > 0 ||
                  (key == AppConstants.keyTemperature ||
                          key == 'voice_speed' ||
                          key == 'font_size') &&
                      value is double &&
                      value.isFinite ||
                  value is bool &&
                      const {
                        'voice_barge_in',
                        'auto_context',
                        'wifi_only',
                        'auto_title'
                      }.contains(key))) {
            await hive.setSetting(key, value);
          }
        }
      case ClusterBackupPart.files:
        final docs = await getApplicationDocumentsDirectory();
        final files = data['files'] as Map<String, dynamic>;
        if (files.keys.any((path) => !isSafePath(path))) {
          throw const FormatException('Unsafe workspace file path.');
        }
        for (final entry in files.entries) {
          var path = docs.path;
          final parts = entry.key.split('/');
          for (final part in parts.take(parts.length - 1)) {
            path = '$path/$part';
            final type = await FileSystemEntity.type(path, followLinks: false);
            if (type == FileSystemEntityType.notFound) {
              await Directory(path).create();
            } else if (type != FileSystemEntityType.directory) {
              throw const FormatException('Unsafe workspace destination.');
            }
          }
          final file = File('$path/${parts.last}');
          if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            continue;
          }
          final bytes = base64Decode(entry.value as String);
          await file.create(exclusive: true);
          try {
            await file.writeAsBytes(bytes, flush: true);
          } catch (_) {
            await file.delete();
            rethrow;
          }
        }
        if (Get.isRegistered<VoiceCloneStore>()) {
          await Get.find<VoiceCloneStore>().scan();
        }
    }
  }
}
