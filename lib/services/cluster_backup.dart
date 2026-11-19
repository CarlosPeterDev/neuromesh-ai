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
import '../utils/memory_text.dart';
import 'agent_service.dart';
import 'hive_service.dart';
import 'sandbox_service.dart';
import '../utils/model_file_role.dart';
import 'voice_clone_store.dart';

enum ClusterBackupPart {
  chats('Chats'),
  settings('App preferences'),
  memory('Saved assistant memory'),
  files('Workspace, documents, skills and saved voices');

  const ClusterBackupPart(this.label);
  final String label;

  String get transferId => 'backup-$name';

  static ClusterBackupPart? fromTransferId(String id) =>
      values.firstWhereOrNull((part) => part.transferId == id);
}

class ClusterBackup {
  static const maxBytes = 32 * 1024 * 1024;
  static const _roots = {
    'agent_files',
    'agent_projects',
    'agent_revisions',
    'voices',
    'rag',
    'skills'
  };
  static final _projectSetting = RegExp(r'^workspace_project_[a-zA-Z0-9_-]+$');
  static const _preferences = {
    'theme_mode',
    AppConstants.keyFontScale,
    'voice_lang',
    'voice_speed',
    'voice_barge_in',
    'auto_context',
    'wifi_only',
    'auto_title',
    'auto_load_last',
    'local_normal_thinking',
    'voice_stt_id',
    'voice_tts_id',
    'voice_sid',
    AppConstants.keyHapticsEnabled,
    AppConstants.keyGlobalSystemPrompt,
    AppConstants.keyImageSteps,
    AppConstants.keyImageGenSize,
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
      bool encrypt, Uint8List key, Uint8List nonce, Uint8List bytes,
      {String domain = 'neuromesh-cluster-backup-v1'}) {
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
          encrypt,
          AEADParameters(KeyParameter(key), 128, nonce,
              Uint8List.fromList(utf8.encode(domain))));
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

  static const _workspaceMagic = 'NMWS2';
  static const _workspaceChunk = 1024 * 1024;

  /// Creates the workspace backup on disk. Only a single authenticated record
  /// is kept in memory, even when the backup includes large attachments.
  static Future<void> writeWorkspace(File output, Uint8List key) async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final destination = await output.open(mode: FileMode.write);
    final archiveId = randomBytes(16);
    final streamId = base64Url.encode(archiveId);
    var record = 0;
    Future<void> writeRecord(Uint8List data) async {
      final nonce = randomBytes(12);
      final encrypted = _crypt(true, key, nonce, data,
          domain: '$_workspaceMagic:$streamId:${record++}');
      final length = ByteData(4)..setUint32(0, encrypted.length);
      await destination.writeFrom(length.buffer.asUint8List());
      await destination.writeFrom(nonce);
      await destination.writeFrom(encrypted);
    }

    try {
      await destination.writeString(_workspaceMagic);
      await destination.writeFrom(archiveId);
      for (final root in _roots) {
        final base = root == 'skills' ? support : docs;
        final directory = Directory('${base.path}/$root');
        if (await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) continue;
        await for (final entry
            in directory.list(recursive: true, followLinks: false)) {
          if (entry is! File) continue;
          final path = entry.path
              .substring(base.path.length + 1)
              .replaceAll(Platform.pathSeparator, '/');
          if (!isSafePath(path)) continue;
          final input = await entry.open();
          try {
            var left = await input.length();
            final metadata =
                utf8.encode(jsonEncode({'path': path, 'size': left}));
            if (metadata.length > 16384) {
              throw const FormatException('Workspace filename is too long.');
            }
            await writeRecord(Uint8List.fromList(metadata));
            while (left > 0) {
              final bytes = await input.read(min(left, _workspaceChunk));
              if (bytes.isEmpty) {
                throw const FormatException(
                    'A workspace file changed during backup.');
              }
              await writeRecord(bytes);
              left -= bytes.length;
            }
          } finally {
            await input.close();
          }
        }
      }
      await writeRecord(Uint8List(0));
    } finally {
      await destination.close();
    }
  }

  static Future<void> restoreWorkspace(File packet, Uint8List key) async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final staging = await packet.parent.createTemp('workspace-');
    try {
      final input = await packet.open();
      try {
        final prefix = await input.read(_workspaceMagic.length);
        if (ascii.decode(prefix, allowInvalid: true) != _workspaceMagic) {
          if (await input.length() > maxBytes + 28) {
            throw const FormatException('Unknown workspace backup format.');
          }
          await restore(
              ClusterBackupPart.files, key, await packet.readAsBytes());
          return;
        }
        final archiveId = await input.read(16);
        if (archiveId.length != 16)
          throw const FormatException('Incomplete backup.');
        final streamId = base64Url.encode(archiveId);
        var record = 0;
        Future<Uint8List> readRecord(int maxPlaintext) async {
          final header = await input.read(4);
          if (header.length != 4)
            throw const FormatException('Incomplete backup.');
          final length = ByteData.sublistView(header).getUint32(0);
          if (length < 16 || length > maxPlaintext + 16) {
            throw const FormatException('Invalid backup record size.');
          }
          final nonce = await input.read(12);
          final encrypted = await input.read(length);
          if (nonce.length != 12 || encrypted.length != length) {
            throw const FormatException('Incomplete backup.');
          }
          return _crypt(false, key, nonce, encrypted,
              domain: '$_workspaceMagic:$streamId:${record++}');
        }

        final paths = <String>{};
        while (true) {
          final header = await readRecord(16384);
          if (header.isEmpty) break;
          final data = jsonDecode(utf8.decode(header)) as Map;
          final path = data['path'] as String;
          var left = data['size'] as int;
          if (!isSafePath(path) || !paths.add(path) || left < 0) {
            throw const FormatException('Invalid workspace file description.');
          }
          final file = File('${staging.path}/$path');
          await file.parent.create(recursive: true);
          final output = await file.open(mode: FileMode.write);
          try {
            while (left > 0) {
              final chunk = await readRecord(min(left, _workspaceChunk));
              if (chunk.isEmpty)
                throw const FormatException('Incomplete workspace file.');
              await output.writeFrom(chunk);
              left -= chunk.length;
            }
          } finally {
            await output.close();
          }
        }
        if (await input.position() != await input.length()) {
          throw const FormatException('Unexpected data after the backup.');
        }
        for (final path in paths) {
          final base = path.startsWith('skills/') ? support : docs;
          final dest = await _workspaceDestination(base, path);
          if (dest == null) continue;
          final original = File('${staging.path}/$path');
          await dest.create(exclusive: true);
          try {
            await original.openRead().pipe(dest.openWrite());
          } catch (_) {
            await dest.delete();
            rethrow;
          }
        }
        if (Get.isRegistered<VoiceCloneStore>()) {
          await Get.find<VoiceCloneStore>().scan();
        }
      } finally {
        await input.close();
      }
    } finally {
      await staging.delete(recursive: true);
    }
  }

  static Future<File?> _workspaceDestination(
      Directory base, String path) async {
    var destination = base.path;
    final parts = path.split('/');
    for (final part in parts.take(parts.length - 1)) {
      destination = '$destination/$part';
      final type = await FileSystemEntity.type(destination, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(destination).create();
      } else if (type != FileSystemEntityType.directory) {
        throw const FormatException('Unsafe workspace destination.');
      }
    }
    final file = File('$destination/${parts.last}');
    return await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.notFound
        ? file
        : null;
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
        data['modelHelpers'] = hive.getSetting<Map>('model_helper_links') ?? {};
        data['alpineInstalled'] = Get.isRegistered<SandboxService>() &&
            Get.find<SandboxService>().installed.value;
      case ClusterBackupPart.memory:
        data['notes'] = (hive.getSetting<List>('agent_memory') ?? const [])
            .whereType<String>()
            .where((note) => !isMemoryTask(note))
            .toList();
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

  static Future<void> restore(
      ClusterBackupPart part, Uint8List key, Uint8List packet) async {
    final data =
        jsonDecode(utf8.decode(open(key, packet))) as Map<String, dynamic>;
    if (data['kind'] != part.name) {
      throw const FormatException(
          'This backup does not match the selected category.');
    }
    final hive = Get.find<HiveService>();
    switch (part) {
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
              (const {
                        'theme_mode',
                        'voice_lang',
                        'voice_stt_id',
                        'voice_tts_id',
                        AppConstants.keyGlobalSystemPrompt
                      }.contains(key) &&
                      value is String ||
                  (key == AppConstants.keyMaxTokens ||
                          key == AppConstants.keyContextSize ||
                          key == AppConstants.keyImageSteps ||
                          key == AppConstants.keyImageGenSize ||
                          key == 'voice_sid') &&
                      value is int &&
                      (key == 'voice_sid' || key == AppConstants.keyImageGenSize
                          ? value >= 0
                          : value > 0) ||
                  (key == AppConstants.keyTemperature ||
                          key == 'voice_speed' ||
                          key == AppConstants.keyFontScale) &&
                      value is double &&
                      value.isFinite ||
                  value is bool &&
                      const {
                        'voice_barge_in',
                        'auto_context',
                        'wifi_only',
                        'auto_title',
                        'auto_load_last',
                        'local_normal_thinking',
                        AppConstants.keyHapticsEnabled
                      }.contains(key))) {
            await hive.setSetting(key, value);
          }
        }
        final helperLinks = data['modelHelpers'];
        if (helperLinks is Map) {
          final existing = Map<dynamic, dynamic>.from(
              hive.getSetting<Map>('model_helper_links') ?? {});
          for (final entry in helperLinks.entries) {
            final model = entry.key;
            final link = entry.value;
            if (model is! String ||
                link is! Map ||
                !isSafePath('rag/$model') ||
                model.contains('/') ||
                modelFileRole(model).isHelper) continue;
            final helper = link['filename'];
            final url = link['url'];
            if (helper is! String ||
                url is! String ||
                helper.contains('/') ||
                !isSafePath('rag/$helper') ||
                modelFileRole(helper) != ModelFileRole.projector ||
                (url.isNotEmpty && huggingFaceRepository(url) == null))
              continue;
            existing.putIfAbsent(model, () => {'filename': helper, 'url': url});
          }
          await hive.setSetting('model_helper_links', existing);
        }
        if (data['alpineInstalled'] == true) {
          await hive.setSetting('restore_alpine_recommended', true);
        }
      case ClusterBackupPart.memory:
        final agent = Get.find<AgentService>();
        final notes = (data['notes'] as List).whereType<String>();
        for (final note in notes) {
          if (agent.memory.length >= AgentService.maxMemory) break;
          await agent.addNote(note);
        }
      case ClusterBackupPart.files:
        final docs = await getApplicationDocumentsDirectory();
        final files = data['files'] as Map<String, dynamic>;
        if (files.keys.any((path) => !isSafePath(path))) {
          throw const FormatException('Unsafe workspace file path.');
        }
        for (final entry in files.entries) {
          final file = await _workspaceDestination(docs, entry.key);
          if (file == null) continue;
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
