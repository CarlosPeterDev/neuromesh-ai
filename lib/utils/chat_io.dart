import 'dart:convert';

/// Pure helpers for chat export/import and full-app backup.
/// Messages are plain maps (ChatMessage.toMap) so this stays testable.

const String kChatExportFormat = 'neuromesh-chat';
const String kBackupFormat = 'neuromesh-backup';

String chatToMarkdown(Map<dynamic, dynamic> session,
    List<Map<dynamic, dynamic>> messages) {
  final b = StringBuffer();
  b.writeln('# ${session['title'] ?? 'Chat'}');
  b.writeln();
  b.writeln('_Exported from NeuroMesh AI_');
  for (final m in messages) {
    final role = m['role'];
    final content = (m['content'] ?? '').toString();
    if (content.trim().isEmpty && m['fileName'] == null) continue;
    final who = switch (role) {
      'user' => 'You',
      'assistant' => 'Assistant',
      'system' => 'System',
      _ => '$role',
    };
    b.writeln();
    b.writeln('### $who');
    b.writeln();
    if (m['fileName'] != null) b.writeln('📎 ${m['fileName']}\n');
    b.writeln(content.trim());
  }
  return b.toString();
}

String chatToJson(
    Map<dynamic, dynamic> session, List<Map<dynamic, dynamic>> messages) {
  final cleaned = messages.map((m) {
    final c = Map<String, dynamic>.from(m);
    // Inline images make files huge; keep text only.
    c.remove('imageBase64');
    return c;
  }).toList();
  return const JsonEncoder.withIndent('  ').convert({
    'format': kChatExportFormat,
    'version': 1,
    'session': Map<String, dynamic>.from(session),
    'messages': cleaned,
  });
}

class ParsedChat {
  final Map<String, dynamic> session;
  final List<Map<String, dynamic>> messages;
  ParsedChat(this.session, this.messages);
}

/// Throws FormatException on anything that is not a NeuroMesh chat export.
ParsedChat parseChatJson(String text) {
  final dynamic data;
  try {
    data = jsonDecode(text);
  } catch (_) {
    throw const FormatException('This file is not valid JSON.');
  }
  if (data is! Map || data['format'] != kChatExportFormat) {
    throw const FormatException('This is not a NeuroMesh chat export.');
  }
  final session = Map<String, dynamic>.from(data['session'] as Map? ?? {});
  final msgs = (data['messages'] as List? ?? [])
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList();
  return ParsedChat(session, msgs);
}

String buildBackup({
  required List<Map<dynamic, dynamic>> sessions,
  required List<Map<dynamic, dynamic>> messages,
  required Map<String, dynamic> settings,
}) {
  return jsonEncode({
    'format': kBackupFormat,
    'version': 1,
    'createdAt': DateTime.now().toIso8601String(),
    'sessions': sessions,
    'messages': messages,
    'settings': settings,
  });
}

class ParsedBackup {
  final List<Map<String, dynamic>> sessions;
  final List<Map<String, dynamic>> messages;
  final Map<String, dynamic> settings;
  ParsedBackup(this.sessions, this.messages, this.settings);
}

ParsedBackup parseBackup(String text) {
  final dynamic data;
  try {
    data = jsonDecode(text);
  } catch (_) {
    throw const FormatException('This file is not valid JSON.');
  }
  if (data is! Map || data['format'] != kBackupFormat) {
    throw const FormatException('This is not a NeuroMesh backup.');
  }
  List<Map<String, dynamic>> list(String k) => (data[k] as List? ?? [])
      .whereType<Map>()
      .map((m) => Map<String, dynamic>.from(m))
      .toList();
  return ParsedBackup(list('sessions'), list('messages'),
      Map<String, dynamic>.from(data['settings'] as Map? ?? {}));
}

/// Settings keys that must never leave the device in a backup/diagnostic.
bool isSecretSettingKey(String key) {
  final k = key.toLowerCase();
  return k.contains('key') || k.contains('token') || k.contains('secret');
}

// Internal diagnostic history is local and has its own reviewed export.
bool canTransferSetting(String key) =>
    !isSecretSettingKey(key) && !key.startsWith('diagnostics_model_load_');

Map<String, dynamic> stripSecrets(Map<dynamic, dynamic> settings) {
  final out = <String, dynamic>{};
  settings.forEach((k, v) {
    final key = '$k';
    if (canTransferSetting(key)) out[key] = v;
  });
  return out;
}

/// Masks things that look like secrets in free text (log lines etc.).
String sanitizeLog(String text) {
  var t = text;
  t = t.replaceAll(RegExp(r'(sk|hf|ghp|xox[a-z])[-_][A-Za-z0-9_\-]{12,}'), '[redacted]');
  t = t.replaceAll(
      RegExp(r'(Bearer\s+)[A-Za-z0-9._\-]{8,}', caseSensitive: false), r'$1[redacted]');
  t = t.replaceAll(
      RegExp(r'(api[_-]?key|token|password)(["\s:=]+)[^\s,"}]+', caseSensitive: false),
      r'$1$2[redacted]');
  return t;
}
