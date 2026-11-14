import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show TextSelection;

import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../controllers/chat_controller.dart';
import '../controllers/settings_controller.dart';
import '../utils/chat_io.dart';
import 'hive_service.dart';

class RolePreset {
  final String name;
  final String emoji;
  final String prompt;
  final double temperature;
  const RolePreset(this.name, this.emoji, this.prompt, this.temperature);
}

const kRolePresets = <RolePreset>[
  RolePreset('Coder', '💻',
      'You are an expert software engineer. Give correct, minimal, working code with short explanations. Ask for missing details instead of guessing.', 0.2),
  RolePreset('Translator', '🌍',
      'You are a professional translator. Translate the user\'s text faithfully into the language they ask for. Output only the translation unless asked otherwise.', 0.2),
  RolePreset('Tutor', '🎓',
      'You are a patient tutor. Explain step by step in simple words, check understanding, and give a short example.', 0.5),
  RolePreset('Writer', '✍️',
      'You are a creative writing assistant. Write vivid, well-structured text that matches the requested tone and length.', 0.9),
  RolePreset('Summarizer', '📝',
      'You summarize text into clear bullet points, keeping key facts and numbers. Be concise.', 0.2),
  RolePreset('Voice buddy', '🎙️',
      'You are a friendly voice assistant on a phone call. Reply in one to three short, natural spoken sentences. No lists, no markdown, no emojis.', 0.6),
];

class ToolboxService extends GetxService {
  static const _kPrompts = 'prompt_library';
  static const _kProfiles = 'model_profiles';
  static const _uuid = Uuid();

  HiveService get _hive => Get.find<HiveService>();
  SettingsController get _settings => Get.find<SettingsController>();

  final prompts = <Map<String, dynamic>>[].obs;
  final profiles = <Map<String, dynamic>>[].obs;

  @override
  void onInit() {
    super.onInit();
    prompts.value = _readList(_kPrompts);
    profiles.value = _readList(_kProfiles);
    if (prompts.isEmpty) {
      prompts.value = [
        {'id': _uuid.v4(), 'title': 'Explain simply', 'text': 'Explain this in simple words, with one example:\n\n'},
        {'id': _uuid.v4(), 'title': 'Fix my code', 'text': 'Find and fix the bug in this code, then explain what was wrong:\n\n'},
        {'id': _uuid.v4(), 'title': 'Summarize', 'text': 'Summarize the following in 5 bullet points:\n\n'},
      ];
      _save(_kPrompts, prompts);
    }
  }

  List<Map<String, dynamic>> _readList(String key) {
    final raw = _hive.getSetting<String>(key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(String key, List<Map<String, dynamic>> v) =>
      _hive.setSetting(key, jsonEncode(v));

  // ── Prompt library ──
  Future<void> addPrompt(String title, String text) async {
    prompts.add({'id': _uuid.v4(), 'title': title, 'text': text});
    await _save(_kPrompts, prompts);
  }

  Future<void> removePrompt(String id) async {
    prompts.removeWhere((p) => p['id'] == id);
    await _save(_kPrompts, prompts);
  }

  /// Puts a prompt into the chat input box.
  void usePrompt(String text) {
    final chat = Get.find<ChatController>();
    chat.textController.text = text;
    chat.textController.selection =
        TextSelection.collapsed(offset: text.length);
  }

  // ── Roles & profiles ──
  Future<void> applyRole(RolePreset r) async {
    await _settings.setGlobalSystemPrompt(r.prompt);
    await _settings.setTemperature(r.temperature);
  }

  Future<void> saveProfile(String name) async {
    profiles.add({
      'id': _uuid.v4(),
      'name': name,
      'temperature': _settings.temperature.value,
      'maxTokens': _settings.maxTokens.value,
      'contextSize': _settings.contextSize.value,
      'systemPrompt': _settings.globalSystemPrompt.value,
    });
    await _save(_kProfiles, profiles);
  }

  Future<void> applyProfile(Map<String, dynamic> p) async {
    await _settings.setTemperature((p['temperature'] as num).toDouble());
    await _settings.setMaxTokens((p['maxTokens'] as num).toInt());
    await _settings.setContextSize((p['contextSize'] as num).toInt());
    await _settings.setGlobalSystemPrompt('${p['systemPrompt']}');
  }

  Future<void> removeProfile(String id) async {
    profiles.removeWhere((p) => p['id'] == id);
    await _save(_kProfiles, profiles);
  }

  // ── Export / import ──
  Future<File> _tempFile(String name, String content) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$name');
    await f.writeAsString(content);
    return f;
  }

  String _safe(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '').trim().replaceAll(' ', '_');

  Future<void> exportChat(String sessionId, {required bool markdown}) async {
    final session = _hive.getAllSessions().firstWhere((s) => s['id'] == sessionId);
    final msgs = _hive.getMessagesForChat(sessionId)
      ..sort((a, b) => '${a['timestamp']}'.compareTo('${b['timestamp']}'));
    final base = _safe('${session['title']}');
    final f = await _tempFile(
        '${base.isEmpty ? 'chat' : base}.${markdown ? 'md' : 'json'}',
        markdown ? chatToMarkdown(session, msgs) : chatToJson(session, msgs));
    await Share.shareXFiles([XFile(f.path)]);
  }

  /// Returns a message for the UI.
  Future<String> importChat() async {
    final res = await FilePicker
        .pickFiles(type: FileType.any, withData: false);
    final path = res?.files.single.path;
    if (path == null) return 'Cancelled.';
    try {
      final parsed = parseChatJson(await File(path).readAsString());
      final id = _uuid.v4(); // never overwrite an existing chat
      final s = Map<String, dynamic>.from(parsed.session)
        ..['id'] = id
        ..['updatedAt'] = DateTime.now().toIso8601String();
      await _hive.saveSession(id, s);
      for (final m in parsed.messages) {
        final mid = _uuid.v4();
        await _hive.saveMessage(mid, {...m, 'id': mid, 'chatId': id});
      }
      Get.find<ChatController>().loadSessions();
      return 'Imported "${s['title']}" (${parsed.messages.length} messages).';
    } on FormatException catch (e) {
      return e.message;
    } catch (e) {
      return 'Import failed: $e';
    }
  }

  // ── Backup / restore ──
  Future<void> createBackup() async {
    final settings = stripSecrets(_hive.settingsBox.toMap());
    final json = buildBackup(
      sessions: _hive.getAllSessions(),
      messages: _hive.messagesBox.values
          .whereType<Map>()
          .map((m) => Map<dynamic, dynamic>.from(m))
          .toList(),
      settings: settings,
    );
    final stamp = DateTime.now().toIso8601String().substring(0, 10);
    final f = await _tempFile('neuromesh-backup-$stamp.json', json);
    await Share.shareXFiles([XFile(f.path)],
        text: 'NeuroMesh AI backup (API keys are not included).');
  }

  Future<String> restoreBackup() async {
    final res = await FilePicker
        .pickFiles(type: FileType.any, withData: false);
    final path = res?.files.single.path;
    if (path == null) return 'Cancelled.';
    try {
      final b = parseBackup(await File(path).readAsString());
      for (final s in b.sessions) {
        await _hive.saveSession('${s['id']}', s);
      }
      for (final m in b.messages) {
        await _hive.saveMessage('${m['id']}', m);
      }
      for (final e in b.settings.entries) {
        if (!isSecretSettingKey(e.key)) await _hive.setSetting(e.key, e.value);
      }
      Get.find<ChatController>().loadSessions();
      return 'Restored ${b.sessions.length} chats. Restart the app to apply settings.';
    } on FormatException catch (e) {
      return e.message;
    } catch (e) {
      return 'Restore failed: $e';
    }
  }
}
