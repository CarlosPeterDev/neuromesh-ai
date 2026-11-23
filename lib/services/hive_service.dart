import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/constants.dart';

class HiveService extends GetxService {
  late Box _sessionsBox;
  late Box _messagesBox;
  late Box _tasksBox;
  late Box _settingsBox;

  Box get sessionsBox => _sessionsBox;
  Box get messagesBox => _messagesBox;
  Box get tasksBox => _tasksBox;
  Box get settingsBox => _settingsBox;

  Future<Box> _openBox(String name) async {
    // Hive 2.x completes an internal future for concurrent openers. Join that
    // future so a failed open has an error listener on both code paths.
    final opened = await Future.wait([
      Hive.openBox(name, crashRecovery: false),
      Hive.openBox(name, crashRecovery: false),
    ]);
    return opened.first;
  }

  Future<HiveService> init() async {
    _sessionsBox = await _openBox(AppConstants.chatSessionsBox);
    _messagesBox = await _openBox(AppConstants.chatMessagesBox);
    _tasksBox = await _openBox(AppConstants.tasksBox);
    _settingsBox = await _openBox(AppConstants.settingsBox);
    // Preserve current local-server settings and purge obsolete provider data.
    // Any new server_* setting must be added here or it is wiped on launch.
    const currentServerKeys = {
      AppConstants.keyServerApiKey,
      AppConstants.keyServerUseApiKey,
      AppConstants.keyServerAllowNetwork,
    };
    final obsoleteServerKeys = _settingsBox.keys.where((key) =>
        key is String &&
        key.startsWith('server_') &&
        !currentServerKeys.contains(key));
    await _settingsBox.deleteAll(obsoleteServerKeys);
    return this;
  }

  // ─── Settings helpers ───────────────────────────

  T? getSetting<T>(String key, {T? defaultValue}) {
    final value = _settingsBox.get(key);
    return value is T ? value : defaultValue;
  }

  Future<void> setSetting(String key, dynamic value) async {
    await _settingsBox.put(key, value);
  }

  // ─── Chat Sessions ─────────────────────────────

  List<Map<dynamic, dynamic>> getAllSessions() {
    return _sessionsBox.values
        .whereType<Map>()
        .map((v) => Map<dynamic, dynamic>.from(v))
        .toList();
  }

  Future<void> saveSession(String id, Map<String, dynamic> data) async {
    await _sessionsBox.put(id, data);
  }

  Future<void> deleteSession(String id) async {
    await _sessionsBox.delete(id);
    // Delete all messages for this session
    final keysToDelete = <dynamic>[];
    for (var key in _messagesBox.keys) {
      final msg = _messagesBox.get(key);
      if (msg is Map && msg['chatId'] == id) {
        keysToDelete.add(key);
      }
    }
    await _messagesBox.deleteAll(keysToDelete);
  }

  // ─── Chat Messages ─────────────────────────────

  List<Map<dynamic, dynamic>> getMessagesForChat(String chatId) {
    return _messagesBox.values
        .where((v) => v is Map && v['chatId'] == chatId)
        .map((v) => Map<dynamic, dynamic>.from(v))
        .toList();
  }

  Future<void> saveMessage(String id, Map<String, dynamic> data) async {
    await _messagesBox.put(id, data);
  }

  // ─── Tasks ─────────────────────────────────────

  List<Map<dynamic, dynamic>> getAllTasks() {
    return _tasksBox.values
        .whereType<Map>()
        .map((v) => Map<dynamic, dynamic>.from(v))
        .toList();
  }

  Future<void> saveTask(String id, Map<String, dynamic> data) async {
    await _tasksBox.put(id, data);
  }

  Future<void> deleteTask(String id) async {
    await _tasksBox.delete(id);
  }
}
