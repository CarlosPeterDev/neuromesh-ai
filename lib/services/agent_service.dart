import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/bm25.dart';
import '../utils/skill_context.dart';
import '../utils/memory_text.dart';
import '../utils/page_text.dart';
import '../utils/web_search_parse.dart';
import '../widgets/ask_user.dart';
import 'agent_tools.dart';
import 'device_bridge.dart';
import 'desktop_command_service.dart';
import 'scheduler_service.dart';
import 'voice_service.dart';
import 'document_extractor_service.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'mcp_client.dart';
import 'pollinations_image_service.dart';
import 'pollinations_credentials.dart';
import 'user_files.dart';
import 'web_search_service.dart';

/// Asks the user whether a tool may run. Returns true to allow.
typedef ToolConfirm = Future<bool> Function(
    String toolName, String serverName, Map<String, dynamic> args);

/// A tool the model can call. Built-in tools live in this file; other
/// services (like the Linux sandbox) register theirs with [AgentService.addTool].
class AgentTool {
  final String name;
  final String description;
  final String params;
  final FutureOr<String> Function(Map<String, dynamic> args) run;

  /// Reaches outside the app's own data (network, the user's files, a shell),
  /// so the user is asked first.
  final bool needsConfirm;

  /// Whether the tool should be offered to the model right now.
  final bool Function()? available;

  const AgentTool(this.name, this.description, this.params, this.run,
      {this.needsConfirm = false, this.available});
}

/// Result of one chat turn that may have used tools.
class ToolLoopResult {
  /// The model's final answer.
  final String answer;

  /// One short markdown line per tool the model used.
  final List<String> trace;
  final bool hitLimit;
  const ToolLoopResult(this.answer, this.trace, this.hitLimit);

  /// Marker so trace lines can be stripped out of the history sent back to
  /// the model on later turns.
  static const traceMark = '> 🔧 ';

  String get markdown =>
      trace.isEmpty ? answer : '${trace.join('\n')}\n\n$answer';
}

/// Removes tool-trace lines from a saved assistant message.
String stripToolTrace(String content) => content
    .split('\n')
    .where((l) => !l.startsWith(ToolLoopResult.traceMark))
    .join('\n')
    .trimLeft();

enum AgentChatMode { auto, always, off }

/// Lets the chat model use tools: files, memory, the web, MCP servers and
/// an optional Linux sandbox. It is part of normal chat: when the
/// model needs a tool it calls it, then keeps answering.
class AgentService extends GetxService {
  static const _serversKey = 'mcp_servers';
  static const _memoryKey = 'agent_memory';
  static const _allowKey = 'agent_always_allow'; // legacy, migrated
  static const _policyKey = 'agent_tool_policy';
  static const _modeKey = 'agent_chat_mode';
  static const _autoMemKey = 'agent_auto_memory';
  static const maxSteps = 20;
  static const finalAnswerPrompt =
      'Give the final answer to the original request using the actual tool '
      'results so far. If evidence or an action is still missing, say what '
      'could not be completed. Reply in ordinary text without tools.';
  static const maxMemory = 60;

  final HiveService _hive = Get.find<HiveService>();

  final servers = <McpServerConfig>[].obs;
  final serverStatus = <String, String>{}.obs;
  final _tools = <String, List<McpTool>>{};
  final toolsVersion = 0.obs; // bumps when a server's tool list changes
  final memory = <String>[].obs;

  /// Per-tool choice: 'allow' (never ask), 'ask' (always ask) or 'block'.
  /// Key is "server::tool". Tools with no entry use their default.
  final policy = <String, String>{}.obs;
  final mode = AgentChatMode.auto.obs;
  final autoMemory = true.obs;
  final _extra = <AgentTool>[];
  bool _cancel = false;

  // ── workspace (private folder; attachments are copied here) ──────────

  static final _workspaceKey = Object();

  String projectForChat(String chatId) => chatId.isEmpty
      ? ''
      : _hive.getSetting<String>('workspace_project_$chatId') ?? '';

  Future<void> setChatProject(String chatId, String name) async {
    if (chatId.isEmpty) throw ArgumentError('Open a chat first.');
    final project = name.trim();
    if (project.length > 60 || project.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError('Enter a project name up to 60 characters.');
    }
    await _hive.setSetting('workspace_project_$chatId', project);
  }

  Future<T> inProject<T>(String project, Future<T> Function() action) =>
      runZoned(action, zoneValues: {_workspaceKey: project});

  String get _project => Zone.current[_workspaceKey] as String? ?? '';
  String get _projectId =>
      base64Url.encode(utf8.encode(_project)).replaceAll('=', '');

  Future<Directory> filesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(_project.isEmpty
        ? '${base.path}/agent_files'
        : '${base.path}/agent_projects/$_projectId');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Directory> _versionDir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    final key = base64Url.encode(utf8.encode(name)).replaceAll('=', '');
    return Directory(
        '${base.path}/agent_revisions/${_project.isEmpty ? "_" : _projectId}/$key');
  }

  Future<void> _keepFileVersion(File file) async {
    if (!await file.exists()) return;
    final dir = await _versionDir(file.uri.pathSegments.last);
    await dir.create(recursive: true);
    final now = DateTime.now().microsecondsSinceEpoch;
    await file.copy('${dir.path}/$now');
    final revisions = await _versions(dir);
    for (final old in revisions.skip(10)) {
      await old.delete();
    }
  }

  Future<List<File>> _versions(Directory dir) async {
    if (!await dir.exists()) return [];
    return (await dir
        .list(followLinks: false)
        .where((entry) => entry is File)
        .cast<File>()
        .toList())
      ..sort((a, b) => b.path.compareTo(a.path));
  }

  Future<List<String>> archivedWorkspaceFiles() async {
    final root = (await _versionDir('file')).parent;
    if (!await root.exists()) return [];
    final names = <String>[];
    await for (final dir in root.list(followLinks: false)) {
      if (dir is! Directory) continue;
      try {
        names.add(utf8.decode(base64Url.decode(base64Url.normalize(
            dir.uri.pathSegments.where((part) => part.isNotEmpty).last))));
      } on FormatException {
        continue;
      }
    }
    return names..sort();
  }

  Future<List<int>> workspaceVersions(String name) async {
    final dir = await _versionDir(name);
    return (await _versions(dir))
        .map((file) => int.tryParse(file.uri.pathSegments.last))
        .whereType<int>()
        .toList();
  }

  Future<bool> restoreWorkspaceVersion(String name, int version) async {
    final file = await _safeFile(name);
    final dir = await _versionDir(name);
    final source = File('${dir.path}/$version');
    if (!await source.exists()) return false;
    final temp =
        File('${file.path}.restore-${DateTime.now().microsecondsSinceEpoch}');
    await source.copy(temp.path);
    try {
      await _keepFileVersion(file);
      await temp.rename(file.path);
      return true;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  /// Only plain file names inside the agent folder are allowed.
  Future<File> _safeFile(String name) async {
    final n = name.split('/').last.split('\\').last;
    if (n.isEmpty || n.startsWith('.')) throw Exception('Invalid file name');
    final path = '${(await filesDir()).path}/$n';
    if (await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw ArgumentError('Workspace tools cannot open symbolic links.');
    }
    return File(path);
  }

  Future<String?> workspaceAttachmentPath(String name) async {
    try {
      final file = await _safeFile(name);
      return await file.exists() ? file.path : null;
    } on ArgumentError {
      return null;
    } on Exception {
      return null;
    }
  }

  /// Copies a file the user attached into the workspace so tools can read it.
  /// Returns the name it can be read by.
  Future<String> importToWorkspace(String sourcePath, String name) async {
    var clean = name
        .split('/')
        .last
        .split('\\')
        .last
        .replaceAll(RegExp(r'[^\w.\- ]'), '_');
    if (clean.isEmpty || clean.startsWith('.')) clean = 'file_$clean';
    final dir = await filesDir();
    var dest = File('${dir.path}/$clean');
    var i = 1;
    while (await dest.exists()) {
      final dot = clean.lastIndexOf('.');
      final base = dot > 0 ? clean.substring(0, dot) : clean;
      final ext = dot > 0 ? clean.substring(dot) : '';
      dest = File('${dir.path}/${base}_$i$ext');
      i++;
    }
    await File(sourcePath).copy(dest.path);
    return dest.path.split('/').last;
  }

  Future<void> deleteWorkspaceFile(String name) async {
    final f = await _safeFile(name);
    if (await f.exists()) {
      await _keepFileVersion(f);
      await f.delete();
    }
  }

  // ── memory ───────────────────────────────────────────────────────────

  Future<void> addNote(String note) async {
    final n = note.trim();
    if (n.isEmpty || isMemoryTask(n)) return;
    if (memory.contains(n)) return;
    memory.add(n.length > 300 ? n.substring(0, 300) : n);
    while (memory.length > maxMemory) {
      memory.removeAt(0);
    }
    await _saveMemory();
  }

  Future<void> removeNote(String note) async {
    memory.remove(note);
    await _saveMemory();
  }

  Future<void> editNote(String old, String updated) async {
    final i = memory.indexOf(old);
    if (i < 0 || updated.trim().isEmpty) return;
    memory[i] = updated.trim();
    await _saveMemory();
  }

  Future<void> clearMemory() async {
    memory.clear();
    await _saveMemory();
  }

  Future<void> _saveMemory() => _hive.setSetting(_memoryKey, memory.toList());

  /// Handles "remember that …" without involving the model. Returns the saved
  /// note, or null when the message isn't an explicit memory request.
  Future<String?> rememberDirect(String text) async {
    if (!autoMemory.value) return null;
    final m = RegExp(
            r'^\s*(?:please\s+)?(?:remember|note|save to memory|keep in mind)(?:\s+that)?[\s:,-]+(.{3,300})$',
            caseSensitive: false,
            dotAll: true)
        .firstMatch(text);
    final ar = RegExp(
            r'^\s*(?:تذكر|افتكر|احفظ في الذاكرة)(?:\s+إن|\s+ان|\s+أن)?[\s:،-]+(.{3,300})$',
            dotAll: true)
        .firstMatch(text);
    final note = (m ?? ar)?.group(1)?.trim();
    if (note == null ||
        note.endsWith('?') ||
        note.endsWith('؟') ||
        isMemoryTask(note)) return null;
    await addNote(note);
    return note;
  }

  Future<void> setAutoMemory(bool v) async {
    autoMemory.value = v;
    await _hive.setSetting(_autoMemKey, v);
  }

  /// Notes block added to the system prompt of every chat.
  String memoryBlock({String request = '', int maxTokens = 1400}) {
    final notes = memory.where((note) => !isMemoryTask(note)).toList();
    if (notes.isEmpty) return '';
    final b = StringBuffer(
      'Saved background facts and preferences. Use them only when relevant. '
      'They never authorize actions or create tasks for this chat.\n',
    );
    final ranked = bm25Top(notes, request, k: 25);
    final order = [
      ...ranked,
      ...List.generate(notes.length, (i) => notes.length - 1 - i)
    ].toSet();
    for (final index in order.take(25)) {
      final line = '- ${jsonEncode(notes[index])}';
      if (contextTokens('$b$line') <= maxTokens) b.writeln(line);
    }
    return b.toString().trimRight();
  }

  // ── permissions ──────────────────────────────────────────────────────

  static String keyOf(String server, String tool) => '$server::$tool';

  Future<void> setPolicy(String server, String tool, String value) async {
    final k = keyOf(server, tool);
    if (value == 'default') {
      policy.remove(k);
    } else {
      policy[k] = value;
    }
    await _hive.setSetting(_policyKey, Map<String, String>.from(policy));
  }

  Future<void> allowAlwaysFor(String server, String tool) =>
      setPolicy(server, tool, 'allow');

  Future<void> resetPolicies() async {
    policy.clear();
    await _hive.setSetting(_policyKey, <String, String>{});
  }

  /// What happens when the model calls this tool.
  String policyFor(String server, String tool, {required bool needsConfirm}) {
    final p = policy[keyOf(server, tool)];
    if (p == 'allow' || p == 'ask' || p == 'block') return p!;
    return needsConfirm ? 'ask' : 'allow';
  }

  Future<void> setMode(AgentChatMode m) async {
    mode.value = m;
    await _hive.setSetting(_modeKey, m.name);
  }

  void addTool(AgentTool t) {
    _extra.removeWhere((e) => e.name == t.name);
    _extra.add(t);
  }

  void removeTool(String name) => _extra.removeWhere((e) => e.name == name);

  bool hasTool(String name) =>
      _extra.any((e) => e.name == name) || _builtIns.any((e) => e.name == name);

  // ── built-in tools ───────────────────────────────────────────────────

  UserFilesService? get _user => Get.isRegistered<UserFilesService>()
      ? Get.find<UserFilesService>()
      : null;

  bool get _hasFolders => _user != null && _user!.folders.isNotEmpty;

  String _page(String text, int start, {int size = 4000}) {
    final context = Get.isRegistered<InferenceService>()
        ? Get.find<InferenceService>().contextTokensTotal.value
        : 0;
    if (context > 0) size = size.clamp(1, (context ~/ 4).clamp(160, 4000));
    if (start < 0) start = 0;
    if (start >= text.length) return '(end of file)';
    final end = (start + size).clamp(0, text.length);
    final part = text.substring(start, end);
    return end < text.length
        ? '$part\n…(characters $start-$end of ${text.length}; call again with "start": $end for more)'
        : part;
  }

  static String _magic(List<int> b) {
    bool starts(List<int> m) =>
        b.length >= m.length &&
        List.generate(m.length, (i) => b[i] == m[i]).every((x) => x);
    if (starts([0x25, 0x50, 0x44, 0x46])) return 'PDF document';
    if (starts([0x50, 0x4B, 3, 4])) return 'ZIP archive (or docx/xlsx/apk/jar)';
    if (starts([0x89, 0x50, 0x4E, 0x47])) return 'PNG image';
    if (starts([0xFF, 0xD8, 0xFF])) return 'JPEG image';
    if (starts([0x47, 0x49, 0x46])) return 'GIF image';
    if (starts([0x7F, 0x45, 0x4C, 0x46])) return 'ELF executable';
    if (starts([0x1F, 0x8B])) return 'gzip data';
    if (starts([0x47, 0x47, 0x55, 0x46])) return 'GGUF model file';
    if (starts([0x53, 0x51, 0x4C, 0x69])) return 'SQLite database';
    return looksBinary(b) ? 'binary data' : 'text';
  }

  /// Text of a workspace file, whatever its type.
  Future<String> _textOfWorkspaceFile(File f) async {
    final name = f.path.split('/').last;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (ext == 'pdf' || ext == 'docx') {
      return DocumentExtractorService.extractText(f.path, ext);
    }
    final bytes = await f.readAsBytes();
    if (ext == 'zip' ||
        ext == 'jar' ||
        ext == 'apk' ||
        ext == 'xlsx' ||
        ext == 'pptx') {
      final arch = ZipDecoder().decodeBytes(bytes);
      final b = StringBuffer('Archive with ${arch.files.length} entries:\n');
      for (final e in arch.files.take(200)) {
        b.writeln(
            '${e.isFile ? '' : '[dir] '}${e.name}${e.isFile ? ' (${e.size} bytes)' : ''}');
      }
      return b.toString();
    }
    if (looksBinary(bytes)) {
      final head = bytes
          .take(48)
          .map((x) => x.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      return '(${_magic(bytes)}, ${bytes.length} bytes; not readable as text)\nFirst bytes: $head';
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  late final List<AgentTool> _builtIns = [
    AgentTool(
      'calculator',
      'Evaluate an arithmetic expression exactly.',
      '{"expression":"string, e.g. (12+3)*4/5"}',
      (args) => formatNumber(
          evaluateExpression((args['expression'] ?? '').toString())),
    ),
    AgentTool(
      'current_time',
      'Get the phone\'s current local date and time.',
      '{}',
      (args) => DateTime.now().toString(),
    ),
    AgentTool(
      'remember',
      'Save a short fact about the user or their preferences so you remember it in future chats.',
      '{"note":"string"}',
      (args) async {
        final note = (args['note'] ?? '').toString().trim();
        if (note.isEmpty || isMemoryTask(note)) {
          return 'Memory is for durable facts and preferences. Handle tasks in the current chat.';
        }
        await addNote(note);
        return 'Saved.';
      },
    ),
    AgentTool(
      'forget',
      'Delete saved notes that contain the given text.',
      '{"contains":"string"}',
      (args) async {
        final q = (args['contains'] ?? '').toString().toLowerCase().trim();
        if (q.isEmpty) return 'Error: say what to forget.';
        final hits = memory.where((n) => n.toLowerCase().contains(q)).toList();
        for (final n in hits) {
          await removeNote(n);
        }
        return hits.isEmpty
            ? 'Nothing matched.'
            : 'Forgot ${hits.length} note(s).';
      },
    ),
    AgentTool(
      'ask_user',
      'Ask the user a question when you need a decision or missing detail before continuing. Prefer this over guessing.',
      '{"question":"string","options":"optional list of short choices"}',
      (args) async {
        final o = args['options'];
        final opts = o is List
            ? o.map((e) => e.toString()).toList()
            : (o is String && o.trim().isNotEmpty
                ? o.split(RegExp(r'\s*[,|/]\s*'))
                : <String>[]);
        return askUserDialog((args['question'] ?? '').toString(), opts);
      },
    ),
    AgentTool(
      'device_status',
      'Read the phone\'s battery, charging state, temperature, free storage, memory and network type. Read-only.',
      '{}',
      (args) async {
        final m = await Get.find<DeviceBridge>().status();
        if (m.isEmpty) return 'Phone status is not available.';
        String gb(num? b) =>
            b == null ? '?' : '${(b / 1073741824).toStringAsFixed(1)} GB';
        return [
          'Device: ${m['model']} (Android ${m['android']}, ${m['cores']} cores)',
          'Battery: ${m['level']}%${m['charging'] == true ? ' (charging)' : ''}${m['saver'] == true ? ', battery saver on' : ''}',
          'Thermal status: ${m['thermal']} (0 normal, 3+ hot)',
          'Storage free: ${gb(m['storageFree'] as num?)} of ${gb(m['storageTotal'] as num?)}',
          'Memory free: ${gb(m['ramFree'] as num?)} of ${gb(m['ramTotal'] as num?)}',
          'Network: ${m['network']}${m['metered'] == true ? ' (metered)' : ''}',
          'Local time: ${DateTime.now()}',
        ].join('\n');
      },
    ),
    AgentTool(
      'transcribe_audio',
      'Transcribe a workspace audio file. Choose an installed listening model ID from models_status if the user requests a model or the default is unsuitable.',
      '{"name":"audio file name","language":"optional code such as en or ar","model_id":"optional installed listening model ID"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found. Use list_files.';
        final t = await Get.find<VoiceService>().transcribeFile(f.path,
            language: (args['language'] ?? '').toString(),
            modelId: (args['model_id'] ?? '').toString());
        return t.isEmpty ? '(no speech found)' : _page(t, 0);
      },
    ),
    AgentTool(
      'text_to_speech',
      'Create a WAV in the workspace. Use models_status to choose a speaking model and exact speaker when the user requests a voice or asks you to choose. Omit overrides to use the user’s defaults. Show it with [📎 name](nmfile:name).',
      '{"text":"string","name":"output file name ending in .wav","language":"optional voice language such as en or ar","model_id":"optional installed speaking model ID","speaker":"optional speaker name from that model"}',
      (args) async {
        var name = (args['name'] ?? 'speech.wav').toString();
        if (!name.toLowerCase().endsWith('.wav')) name = '$name.wav';
        final wav = await Get.find<VoiceService>().synthesizeToWav(
          (args['text'] ?? '').toString(),
          lang: (args['language'] ?? '').toString(),
          modelId: (args['model_id'] ?? '').toString(),
          speaker: (args['speaker'] ?? '').toString(),
        );
        final f = await _safeFile(name);
        await f.writeAsBytes(wav);
        return 'Saved ${f.path.split('/').last} (${wav.length ~/ 1024} KB). Show it with [📎 ${f.path.split('/').last}](nmfile:${f.path.split('/').last}).';
      },
    ),
    AgentTool(
      'schedule_task',
      'Schedule a prompt to run automatically later or repeatedly. when examples: "in 30 minutes", "daily 08:00", "every 2 hours", "weekly mon,thu 09:00", "once 2026-12-01 18:30".',
      '{"title":"string","prompt":"what to do when it runs","when":"string"}',
      (args) async {
        final s = Get.find<SchedulerService>();
        final t = parseWhen((args['when'] ?? '').toString(),
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            title: (args['title'] ?? 'Task').toString(),
            prompt: (args['prompt'] ?? '').toString());
        if (t == null || t.prompt.trim().isEmpty) {
          return 'Error: could not understand "when". Use forms like "daily 08:00" or "in 30 minutes".';
        }
        s.upsert(t);
        return 'Scheduled "${t.title}": ${t.whenText}.';
      },
      needsConfirm: true,
    ),
    AgentTool(
      'list_schedules',
      'List the scheduled tasks.',
      '{}',
      (args) async {
        final s = Get.find<SchedulerService>();
        if (s.tasks.isEmpty) return '(no scheduled tasks)';
        return s.tasks
            .map((t) =>
                '${t.id}: ${t.title} — ${t.whenText}${t.enabled ? '' : ' (off)'}')
            .join('\n');
      },
    ),
    AgentTool(
      'cancel_schedule',
      'Delete a scheduled task by id (from list_schedules).',
      '{"id":"string"}',
      (args) async {
        final s = Get.find<SchedulerService>();
        final id = (args['id'] ?? '').toString();
        if (!s.tasks.any((t) => t.id == id)) return 'Error: unknown id.';
        s.remove(id);
        return 'Deleted.';
      },
      needsConfirm: true,
    ),
    AgentTool(
      'generate_image',
      'Create an image online with Pollinations. Internet is required. Use the user’s description, ask if the subject is missing, and show the returned image.',
      '{"prompt":"image description","style":"illustration|photo|design","name":"optional output file name"}',
      (args) async {
        final image = await PollinationsImageService().create(
          (args['prompt'] ?? '').toString(),
          style: (args['style'] ?? '').toString(),
          key: await PollinationsCredentials.read()
              .onError<Exception>((_, __) => null),
        );
        return _savePollinationsImage(image, args['name'], edited: false);
      },
    ),
    AgentTool(
      'edit_image',
      'Edit an existing image online using a free Pollinations image editor. Requires the user’s Pollinations key and an existing workspace image.',
      '{"prompt":"requested edit","source":"existing workspace image filename","name":"optional output file name"}',
      (args) async {
        final key = await PollinationsCredentials.read();
        if (key == null || key.isEmpty)
          return PollinationsImageService.editKeyNotice;
        final encoded = args['attachedImage'];
        final Uint8List bytes;
        if (encoded is String) {
          if (encoded.length > (8 * 1024 * 1024 * 4 ~/ 3) + 4) {
            return 'Choose an image smaller than 8 MB to edit.';
          }
          bytes = base64Decode(encoded);
        } else {
          final source = await _safeFile((args['source'] ?? '').toString());
          if (await source.length() > 8 * 1024 * 1024) {
            return 'Choose an image smaller than 8 MB to edit.';
          }
          bytes = await source.readAsBytes();
        }
        final image = await PollinationsImageService().edit(
          (args['prompt'] ?? '').toString(),
          bytes,
          key: key,
          style: (args['style'] ?? '').toString(),
        );
        return _savePollinationsImage(image, args['name'], edited: true);
      },
    ),
    AgentTool(
      'list_files',
      'List the files in your workspace (files the user attached are here).',
      '{}',
      (args) async {
        final out = <String>[];
        for (final f in (await filesDir()).listSync().whereType<File>()) {
          out.add('${f.path.split('/').last} (${f.lengthSync()} bytes)');
        }
        return out.isEmpty ? '(no files)' : out.join('\n');
      },
    ),
    AgentTool(
      'file_info',
      'Show the size and detected type of a workspace file.',
      '{"name":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found. Use list_files.';
        final bytes = await f.openRead(0, 64).expand((x) => x).toList();
        return '${f.path.split('/').last}: ${await f.length()} bytes, ${_magic(bytes)}';
      },
    ),
    AgentTool(
      'read_file',
      'Read a workspace file. Works for text, code, PDF, DOCX and zip listings; binary files return a summary.',
      '{"name":"string","start":"optional character offset"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found. Use list_files.';
        final text = await _textOfWorkspaceFile(f);
        return _page(text, int.tryParse('${args['start'] ?? 0}') ?? 0);
      },
    ),
    AgentTool(
      'search_in_file',
      'Find the passages of a workspace file that best match a query. Use this for big files.',
      '{"name":"string","query":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found. Use list_files.';
        final text = await _textOfWorkspaceFile(f);
        final chunks = chunkText(text, size: 700, overlap: 80);
        final top = bm25Top(chunks, (args['query'] ?? '').toString(), k: 4);
        if (top.isEmpty) return 'No matching passages.';
        return top
            .map((i) => '[passage ${i + 1}/${chunks.length}]\n${chunks[i]}')
            .join('\n\n');
      },
    ),
    AgentTool(
      'write_file',
      'Create or overwrite a text file in your workspace.',
      '{"name":"string","content":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (args['create_empty'] == true) {
          try {
            await f.create(exclusive: true);
          } on FileSystemException {
            if (await f.exists())
              return 'A file with that name already exists.';
            rethrow;
          }
        } else {
          await _keepFileVersion(f);
          await f.writeAsString((args['content'] ?? '').toString());
        }
        return 'Wrote ${f.path.split('/').last}.';
      },
    ),
    AgentTool(
      'append_file',
      'Add text to the end of a workspace file (creates it if missing).',
      '{"name":"string","content":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        await _keepFileVersion(f);
        await f.writeAsString((args['content'] ?? '').toString(),
            mode: FileMode.append);
        return 'Appended to ${f.path.split('/').last}.';
      },
    ),
    AgentTool(
      'edit_file',
      'Change an existing workspace file by replacing exact text. Read the file first and copy the text exactly. Set "all":"true" to replace every match.',
      '{"name":"string","old":"exact text to find","new":"replacement text","all":"optional true"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists())
          return 'Error: no such file. Use list_files to see the names.';
        final old = (args['old'] ?? '').toString();
        final nw = (args['new'] ?? '').toString();
        if (old.isEmpty)
          return 'Error: "old" must be the exact text to replace.';
        final text = await f.readAsString();
        final n = text.split(old).length - 1;
        if (n == 0)
          return 'Error: that text was not found. Use read_file and copy the exact text.';
        final all = '${args['all'] ?? ''}' == 'true';
        if (n > 1 && !all)
          return 'Error: the text appears $n times. Add more surrounding text, or set "all":"true".';
        await _keepFileVersion(f);
        await f.writeAsString(
            all ? text.replaceAll(old, nw) : text.replaceFirst(old, nw));
        return 'Edited ${f.path.split('/').last} ($n replacement${n == 1 ? '' : 's'}).';
      },
    ),
    AgentTool(
      'delete_file',
      'Delete a file from your workspace.',
      '{"name":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: no such file.';
        await _keepFileVersion(f);
        await f.delete();
        return 'Deleted ${f.path.split('/').last}.';
      },
      needsConfirm: true,
    ),
    AgentTool(
      'edit_user_file',
      'Change a text file inside a shared folder by replacing exact text (read it first with read_user_file). Set "all":"true" to replace every match.',
      '{"folder":"shared folder name","path":"file path","old":"exact text","new":"replacement","all":"optional true"}',
      (args) async {
        final u = _user!;
        final f = u.find(args['folder']?.toString());
        if (f == null)
          return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        final path = (args['path'] ?? '').toString();
        final old = (args['old'] ?? '').toString();
        final nw = (args['new'] ?? '').toString();
        if (old.isEmpty)
          return 'Error: "old" must be the exact text to replace.';
        final text = await u.readText(f, path, maxChars: 2000000);
        final n = text.split(old).length - 1;
        if (n == 0)
          return 'Error: that text was not found. Use read_user_file and copy the exact text.';
        final all = '${args['all'] ?? ''}' == 'true';
        if (n > 1 && !all)
          return 'Error: the text appears $n times. Add more surrounding text, or set "all":"true".';
        await u.writeText(f, path,
            all ? text.replaceAll(old, nw) : text.replaceFirst(old, nw));
        return 'Edited $path ($n replacement${n == 1 ? '' : 's'}).';
      },
      needsConfirm: true,
      available: () => _hasFolders,
    ),
    AgentTool(
      'tool_help',
      'Show the full description and arguments of one tool, or of every tool when "name" is empty.',
      '{"name":"optional tool name"}',
      (args) async {
        final q = (args['name'] ?? '').toString().trim();
        final all = [
          ..._allBuiltIns,
          ..._enabledMcpTools.map((t) =>
              AgentTool(t.qualifiedName, t.description, t.signature, (_) => ''))
        ];
        final hit =
            q.isEmpty ? all : all.where((t) => t.name.contains(q)).toList();
        if (hit.isEmpty) return 'No tool matches "$q".';
        return hit
            .map((t) => '${t.name}: ${t.description}\narguments: ${t.params}')
            .join('\n\n');
      },
    ),
    AgentTool(
      'list_folder',
      'List files and folders inside a folder the user shared with you.',
      '{"folder":"shared folder name","path":"optional sub-path"}',
      (args) async {
        final u = _user!;
        final f = u.find(args['folder']?.toString());
        if (f == null)
          return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        final items = await u.list(f, (args['path'] ?? '').toString());
        if (items.isEmpty) return '(empty)';
        return items
            .map((e) =>
                '${e.isDir ? '[dir] ' : ''}${e.name}${e.isDir ? '' : ' (${e.size} bytes)'}')
            .join('\n');
      },
      available: () => _hasFolders,
    ),
    AgentTool(
      'read_user_file',
      'Read a file from a folder the user shared with you (text, code, PDF, DOCX).',
      '{"folder":"shared folder name","path":"file path inside it","start":"optional character offset"}',
      (args) async {
        final u = _user!;
        final f = u.find(args['folder']?.toString());
        if (f == null)
          return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        final start = int.tryParse('${args['start'] ?? 0}') ?? 0;
        final text = await u.readText(f, (args['path'] ?? '').toString(),
            maxChars: start + 4000);
        return _page(text, start);
      },
      available: () => _hasFolders,
    ),
    AgentTool(
      'write_user_file',
      'Create or overwrite a text file inside a folder the user shared with you.',
      '{"folder":"shared folder name","path":"file path","content":"string"}',
      (args) async {
        final u = _user!;
        final f = u.find(args['folder']?.toString());
        if (f == null)
          return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        await u.writeText(f, (args['path'] ?? '').toString(),
            (args['content'] ?? '').toString());
        return 'Wrote ${args['path']}.';
      },
      needsConfirm: true,
      available: () => _hasFolders,
    ),
    AgentTool(
      'web_search',
      'Search the web and return the top results (title, url, snippet).',
      '{"query":"string"}',
      (args) async {
        final r = await Get.find<WebSearchService>()
            .search((args['query'] ?? '').toString());
        if (r.isEmpty) return 'No results.';
        return r.map((e) => '${e.title}\n${e.url}\n${e.snippet}').join('\n\n');
      },
    ),
    AgentTool(
      'fetch_url',
      'Download a web page and return its readable text.',
      '{"url":"https://...","start":"optional character offset"}',
      (args) async {
        final uri = Uri.tryParse((args['url'] ?? '').toString());
        if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
          return 'Error: give a full http(s) URL.';
        }
        final res = await http.get(uri, headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 14) NeuroMeshAI'
        }).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200)
          return 'Error: server answered ${res.statusCode}.';
        final ct = res.headers['content-type'] ?? '';
        final body = utf8.decode(res.bodyBytes, allowMalformed: true);
        final text = ct.contains('html') ? readableText(body) : body;
        return _page(text, int.tryParse('${args['start'] ?? 0}') ?? 0);
      },
    ),
  ];

  /// Every built-in tool, including blocked or currently unavailable ones
  /// (for the permissions screen).
  /// Runs a tool by name without the model (used by the HTTP API).
  Future<String> callTool(String name, Map<String, dynamic> args) async {
    final t = catalog.firstWhere((t) => t.name == name,
        orElse: () => throw Exception('Unknown tool $name'));
    return await t.run(args);
  }

  Future<List<Map<String, dynamic>>> listWorkspace() async {
    final dir = await filesDir();
    return [
      for (final e in dir.listSync().whereType<File>())
        {
          'name': e.path.split('/').last,
          'bytes': e.lengthSync(),
          'modified': e.lastModifiedSync().toIso8601String(),
        }
    ];
  }

  Future<File?> workspaceFile(String name) async {
    final f = await _safeFile(name);
    return await f.exists() ? f : null;
  }

  Future<File> newWorkspaceFile(String name) => _safeFile(name);

  List<AgentTool> get catalog => [..._builtIns, ..._extra];

  Iterable<AgentTool> get _allBuiltIns sync* {
    for (final t in [..._builtIns, ..._extra]) {
      final desktopShell =
          t.name == 'run_shell' && Get.isRegistered<DesktopCommandService>();
      if (!desktopShell &&
          policyFor('built-in', t.name, needsConfirm: t.needsConfirm) ==
              'block') {
        continue;
      }
      if (t.available == null || t.available!()) yield t;
    }
  }

  @override
  void onInit() {
    super.onInit();
    final raw = _hive.getSetting<List>(_serversKey) ?? const [];
    servers.value = raw
        .whereType<Map>()
        .map((m) => McpServerConfig.fromMap(Map<String, dynamic>.from(m)))
        .toList();
    memory.value = (_hive.getSetting<List>(_memoryKey) ?? const [])
        .map((e) => e.toString())
        .toList();
    final saved = _hive.getSetting<Map>(_policyKey);
    if (saved != null) {
      policy.addAll({
        for (final e in saved.entries) e.key.toString(): e.value.toString()
      });
    }
    for (final e in (_hive.getSetting<List>(_allowKey) ?? const [])) {
      policy.putIfAbsent(e.toString(), () => 'allow');
    }
    final m = _hive.getSetting<String>(_modeKey) ?? 'auto';
    mode.value = AgentChatMode.values
        .firstWhere((x) => x.name == m, orElse: () => AgentChatMode.auto);
    autoMemory.value = _hive.getSetting<bool>(_autoMemKey) ?? true;
    // Reconnect to enabled servers in the background so their tools are ready.
    for (final s in servers.where((s) => s.enabled)) {
      unawaited(refreshServer(s));
    }
  }

  // ── MCP servers ──────────────────────────────────────────────────────

  Future<void> _saveServers() =>
      _hive.setSetting(_serversKey, servers.map((s) => s.toMap()).toList());

  Future<McpServerConfig> addServer(String name, String url, String token,
      {Map<String, String> headers = const {}}) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final cfg = McpServerConfig(
        id: id,
        name: name.trim(),
        url: url.trim(),
        token: token.trim(),
        headers: headers);
    servers.add(cfg);
    await _saveServers();
    unawaited(refreshServer(cfg));
    return cfg;
  }

  Future<void> updateServer(McpServerConfig cfg) async {
    final i = servers.indexWhere((s) => s.id == cfg.id);
    if (i < 0) return;
    servers[i] = cfg;
    await _saveServers();
    await refreshServer(cfg);
  }

  Future<void> removeServer(String id) async {
    servers.removeWhere((s) => s.id == id);
    _tools.remove(id);
    serverStatus.remove(id);
    toolsVersion.value++;
    await _saveServers();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = servers.indexWhere((s) => s.id == id);
    if (i < 0) return;
    servers[i] = servers[i].copyWith(enabled: enabled);
    await _saveServers();
    if (enabled && !_tools.containsKey(id)) await refreshServer(servers[i]);
    toolsVersion.value++;
  }

  Future<void> setToolEnabled(
      String serverId, String tool, bool enabled) async {
    final i = servers.indexWhere((s) => s.id == serverId);
    if (i < 0) return;
    final off = {...servers[i].disabledTools};
    enabled ? off.remove(tool) : off.add(tool);
    servers[i] = servers[i].copyWith(disabledTools: off);
    await _saveServers();
    toolsVersion.value++;
  }

  /// Connects to the server and lists its tools; updates [serverStatus].
  Future<void> refreshServer(McpServerConfig cfg) async {
    serverStatus[cfg.id] = 'Connecting…';
    final client = McpClient(cfg);
    try {
      final tools = await client.listTools();
      _tools[cfg.id] = tools;
      serverStatus[cfg.id] =
          'Connected · ${tools.length} tool${tools.length == 1 ? '' : 's'}';
    } catch (e) {
      _tools.remove(cfg.id);
      serverStatus[cfg.id] = e.toString();
    } finally {
      client.dispose();
      toolsVersion.value++;
    }
  }

  /// Tries a connection without saving anything. Returns tool names or throws.
  Future<List<McpTool>> testServer(McpServerConfig cfg) async {
    final client = McpClient(cfg);
    try {
      return await client.listTools();
    } finally {
      client.dispose();
    }
  }

  List<McpTool> toolsOf(String id) => _tools[id] ?? const [];

  Iterable<McpTool> get _enabledMcpTools sync* {
    for (final s in servers.where((s) => s.enabled)) {
      for (final t in toolsOf(s.id)) {
        if (!s.disabledTools.contains(t.name) &&
            policyFor(s.name, t.name, needsConfirm: true) != 'block') {
          yield t;
        }
      }
    }
  }

  // ── when and how tools are offered ───────────────────────────────────

  static final _intent = RegExp(
      r'\b(model|helper|projector|mmproj|fastmtp|file|files|folder|directory|document|attached|attachment|read|open|list|create|write|save|edit|search|look up|find|calculate|compute|remember|forget|note|run|execute|command|shell|script|install|deploy|build|github|repo|supabase|database|vercel|url|http|website|web ?page|download|time is it|date today|zip|pdf|csv|json)\b|مجلد|ملف|اقرا|افتح|احفظ|اكتب|ابحث|احسب|تذكر|انسى|شغل|نفذ|ارفع|حمل|موقع',
      caseSensitive: false);

  static final _actionOnly = RegExp(
      r'\b(create|write|save|edit|delete|remove|run|execute|install|folder|file|zip|convert|draw|schedule|remind)\b|ملف|مجلد|احفظ|اكتب|شغل|نفذ',
      caseSensitive: false);
  static final _askingAboutSelf =
      RegExp(r'\b(you|your|yourself|my|me|i)\b', caseSensitive: false);
  // Only real fact questions trigger the (slow) automatic web research.
  // "How do I…", "explain…", "why…", code and chit-chat are answered directly.
  static final _question = RegExp(
      r'^\s*(what|who|whom|whose|when|where|which)\b|^\s*(ما|ماذا|من|متى|اين|أين|كم|إيه|ايه|مين|فين|امتى)(\s|$)',
      caseSensitive: false);
  static final _notFactual = RegExp(
      r'\b(explain|how (do|to|can|does)|why|write|code|translate|define|difference|example|story|poem|joke|summari[sz]e|rewrite|fix|debug)\b|```|اشرح|ترجم|اكتب|لخص',
      caseSensitive: false);

  /// Questions that ask for information must be answered from the web, not
  /// from the model's (out of date) memory.
  bool needsResearch(String text) {
    final t = text.trim();
    if (t.length < 12 || t.length > 400) return false;
    if (explicitlyRequestsWebSearch(t)) return true;
    if (_gFiles.hasMatch(t) && !_question.hasMatch(t)) return false;
    final fresh = needsWebSearch(t);
    if (_actionOnly.hasMatch(t) && !fresh) return false;
    if (fresh) return true;
    if (_notFactual.hasMatch(t) || _askingAboutSelf.hasMatch(t)) return false;
    return _question.hasMatch(t);
  }

  static final _simpleGreeting = RegExp(
    r'^\s*(?:hi|hello|helli|hey|good morning|good evening|مرحبا|مرحبًا|أهلا|أهلًا|اهلا|السلام عليكم|صباح الخير|مساء الخير)[!?.؟،\s]*$',
    caseSensitive: false,
  );

  /// Whether this chat turn should offer tools to the model.
  bool wantsTools(String text, {bool hasFile = false}) {
    if (!hasFile && _simpleGreeting.hasMatch(text)) return false;
    switch (mode.value) {
      case AgentChatMode.off:
        return false;
      case AgentChatMode.always:
        return true;
      case AgentChatMode.auto:
        if (hasFile || text.contains('@skill:') || text.contains('@file:'))
          return true;
        if (_intent.hasMatch(text) || _gVoiceAction.hasMatch(text)) return true;
        if (needsResearch(text)) return true;
        for (final s in servers.where((s) => s.enabled)) {
          if (text.toLowerCase().contains(s.name.toLowerCase())) return true;
        }
        return false;
    }
  }

  static const _coreTools = {
    'web_search',
    'fetch_url',
    'list_files',
    'read_file',
    'write_file',
    'edit_file',
    'ask_user',
    'calculator',
    'current_time',
    'tool_help',
    'read_context',
    'search_context',
    'list_skill_files',
  };
  static final _gVoice = RegExp(
      r'\b(speak|voice|audio|say|read aloud|aloud|transcrib(?:e|ing)|transcription|mp3|wav|m4a|podcast|speech|tts|stt|subtitle)\b|صوت|انطق|فرغ|اقرا بصوت|سجل',
      caseSensitive: false);
  static final _gVoiceAction = RegExp(
    r'\b(?:tts|stt|transcrib(?:e|ing)|text.to.speech|speech.to.text|read aloud)\b|انطق|فرغ الصوت',
    caseSensitive: false,
  );
  static final _gImage = RegExp(
      r'\b(draw|image|picture|photo|logo|illustration|wallpaper|generate an? )\b|صورة|ارسم|رسم|لوجو',
      caseSensitive: false);
  static final _gFiles = RegExp(
      r'\b(file|files|attached|attachment|zip|unzip|archive|download|copy|rename|append|delete|folder|csv|pdf|docx|json|save)\b|ملف|احفظ|حمل',
      caseSensitive: false);
  static final _gMemory = RegExp(
      r'\b(remember|forget|memory|note)\b|تذكر|انسى|فاكر',
      caseSensitive: false);
  static final _gSched = RegExp(
      r'\b(remind|schedule|every|daily|weekly|later|automat|timer|alarm)\b|ذكرني|جدول|كل يوم|بعد',
      caseSensitive: false);
  static final _gDevice = RegExp(
      r'\b(battery|storage|ram|phone status|temperature|network|wifi)\b|بطارية|ذاكرة',
      caseSensitive: false);
  static final _gHttp = RegExp(
      r'\b(api|http|request|webhook|endpoint|rest|post|curl)\b',
      caseSensitive: false);
  static final _gSandbox = RegExp(
      r'\b(run|execute|command|shell|terminal|install|python|pip|node|npm|script|compile|build|apk|ffmpeg|convert|git|sandbox|linux|tool|program|bash|scrape|ocr|pandoc|imagemagick)\b|شغل|نفذ|ثبت|برنامج|سكربت',
      caseSensitive: false);
  static final _gFolders = RegExp(
      r'\b(folder|directory|project|repo|shared)\b|مجلد|مشروع',
      caseSensitive: false);

  static bool _isSandboxTool(String n) =>
      n == 'run_shell' ||
      n.startsWith('sandbox_') ||
      n == 'install_packages' ||
      n == 'run_script' ||
      n == 'convert_file' ||
      n == 'create_tool' ||
      n == 'list_my_tools' ||
      n == 'delete_my_tool' ||
      n.startsWith('x_');

  /// Which tools to describe for this request. Describing all of them costs a
  /// small phone model a minute of reading, so only the likely ones are listed;
  /// the rest stay callable and are named in a short "also available" line.
  Set<String> _toolsFor(String request, {bool withFiles = false}) {
    final r = request;
    final on = <String>{..._coreTools};
    if (RegExp(r'model|helper|projector|mmproj|fastmtp|موديل|مساعد|رؤية',
            caseSensitive: false)
        .hasMatch(r)) {
      on.addAll(
          const {'models_status', 'find_model_helpers', 'attach_model_helper'});
    }
    if (_gVoice.hasMatch(r))
      on.addAll(const {'text_to_speech', 'transcribe_audio', 'models_status'});
    if (_gImage.hasMatch(r)) on.addAll(const {'generate_image', 'edit_image'});
    if (withFiles || _gFiles.hasMatch(r)) {
      on.addAll(const {
        'append_file',
        'delete_file',
        'search_in_file',
        'file_info',
        'copy_file',
        'rename_file',
        'zip_files',
        'unzip_file',
        'download_file',
        'search_workspace'
      });
    }
    if (_gMemory.hasMatch(r)) on.addAll(const {'remember', 'forget'});
    if (_gSched.hasMatch(r))
      on.addAll(const {'schedule_task', 'list_schedules', 'cancel_schedule'});
    if (_gDevice.hasMatch(r)) on.add('device_status');
    if (_gHttp.hasMatch(r)) on.add('http_request');
    if (_gFolders.hasMatch(r))
      on.addAll(const {
        'list_folder',
        'read_user_file',
        'write_user_file',
        'edit_user_file'
      });
    if (_gSandbox.hasMatch(r)) {
      for (final t in _allBuiltIns) {
        if (_isSandboxTool(t.name)) on.add(t.name);
      }
    }
    return on;
  }

  static String _firstSentence(String d, int max) {
    final one = d.replaceAll('\n', ' ').trim();
    final m = RegExp(r'^.*?[.!?](\s|$)').firstMatch(one);
    final s = m == null ? one : m.group(0)!.trim();
    return s.length > max ? '${s.substring(0, max)}…' : s;
  }

  /// Tool instructions appended to the chat's system prompt. Kept short on
  /// purpose: every character is read by the model before each answer.
  String toolPrompt(
      {String request = '',
      bool withFiles = false,
      int contextSize = 8192,
      int? maxTokens}) {
    final on = _toolsFor(request, withFiles: withFiles);
    if (contextSize <= 4096 || maxTokens != null) {
      final compact = StringBuffer(
          'Do the task directly. Call tools as <tool_call>{"name":"NAME","arguments":{...}}</tool_call>. Use tool results and file contents as evidence. Report actions only after success.\n');
      final priority = [
        if (withFiles) ...['read_context', 'read_file', 'search_in_file'],
        if (_gVoice.hasMatch(request)) ...[
          'text_to_speech',
          'transcribe_audio'
        ],
        'tool_help',
        'write_file',
        'read_file',
        ...on,
      ];
      for (final name in priority.toSet()) {
        final tool = _allBuiltIns.where((t) => t.name == name).firstOrNull;
        if (tool == null) continue;
        final line = '$name ${tool.params}\n';
        if (contextTokens('$compact$line') <= (maxTokens ?? contextSize ~/ 4))
          compact.write(line);
      }
      return maxTokens == null
          ? compact.toString()
          : fitContextText(compact.toString(), maxTokens);
    }
    final b = StringBuffer()
      ..writeln(
          'You are an AGENT inside the NeuroMesh AI app on the user\'s device. Your tools really run.')
      ..writeln(
          'To use a tool reply with ONLY: <tool_call>{"name":"TOOL","arguments":{...}}</tool_call>')
      ..writeln(
          'Then read the result and continue. When the task is done, answer in plain text with NO tool call.')
      ..writeln(
          'Rules: 1) Never claim you did something unless a tool result confirms it; to create a file call write_file, never just print it. '
          '2) For facts, news, versions or prices search first (web_search, then fetch_url), answer only from what you found and cite [1]. '
          '3) Show files with [📎 name](nmfile:name) and images with ![desc](nmfile:name). '
          '4) After an error change the arguments; never repeat the same call; use ask_user if only the user knows. '
          '5) Do big jobs step by step.')
      ..writeln(
          'Example: create notes.txt saying hi -> <tool_call>{"name":"write_file","arguments":{"name":"notes.txt","content":"hi"}}</tool_call>')
      ..writeln('Tools:');
    final listed = <String>{};
    for (final t in _allBuiltIns) {
      if (!on.contains(t.name)) continue;
      listed.add(t.name);
      final params =
          t.params.length > 160 ? '${t.params.substring(0, 160)}…' : t.params;
      b.writeln(
          '- ${t.name}: ${_firstSentence(t.description, 170)} ${t.params == '{}' ? '' : params}');
    }
    final mentioned = <String>{};
    final lower = request.toLowerCase();
    final mcp = _enabledMcpTools.toList();
    for (final t in mcp) {
      final srv = servers.where((s) => s.id == t.serverId);
      final name = srv.isEmpty ? '' : srv.first.name.toLowerCase();
      if (mode.value == AgentChatMode.always && mcp.length <= 8 ||
          (name.isNotEmpty && lower.contains(name))) {
        mentioned.add(t.qualifiedName);
        final d = t.description.replaceAll('\n', ' ');
        b.writeln(
            '- ${t.qualifiedName}: ${d.length > 140 ? '${d.substring(0, 140)}…' : d} ${t.signature}');
      }
    }
    final others = [
      for (final t in _allBuiltIns)
        if (!listed.contains(t.name) && t.name != 'tool_help') t.name,
      for (final t in mcp)
        if (!mentioned.contains(t.qualifiedName)) t.qualifiedName,
    ];
    if (others.isNotEmpty) {
      final shown = others.take(40).join(', ');
      b.writeln(
          'Also available (call tool_help with a name for details, or just call them): $shown${others.length > 40 ? ', …' : ''}');
    }
    if (_hasFolders)
      b.writeln(
          'Shared folders: ${_user!.folders.map((f) => f.name).join(', ')}');
    if (on.any(_isSandboxTool)) {
      if (Get.isRegistered<DesktopCommandService>()) {
        b.writeln(
            'Use run_shell for the selected desktop or SSH VM target. The user controls command approvals.');
      } else {
        b.writeln(
            'The sandbox is one shared Linux for all chats: install what you need (install_packages), run code with run_script, and save reusable tools with create_tool.');
      }
    }
    return b.toString().trimRight();
  }

  static int contextBudget(int contextSize) =>
      (contextSize * 0.72).floor() - 64;

  /// Keeps the current user request intact while fitting generated context.
  static ({
    String system,
    String prompt,
    List<Map<String, String>> history,
  }) fitTurn({
    required String baseSystem,
    required String system,
    required String prompt,
    required List<Map<String, String>> history,
    required int contextSize,
    required String request,
    String? continuationRequest,
    String Function(int budget)? compactTools,
    bool needsEvidence = false,
  }) {
    final budget = contextBudget(contextSize);
    final originalPrompt = prompt;
    if (continuationRequest != null) {
      system = '$system\n\n$continuationRequest';
    }
    if (contextSize > 0 &&
        contextTokens(system) + contextTokens(prompt) > budget) {
      final required = continuationRequest ?? request;
      final spare =
          budget - contextTokens(baseSystem) - contextTokens(required);
      final tools = compactTools?.call((spare ~/ 3).clamp(0, 260)) ?? '';
      system = tools.isEmpty ? baseSystem : '$baseSystem\n\n$tools';
      final remaining =
          budget - contextTokens(system) - contextTokens(required) - 12;
      final optional = continuationRequest == null && prompt.startsWith(request)
          ? prompt.substring(request.length).trimLeft()
          : prompt;
      final supportingText = fitContextText(optional, remaining);
      if (needsEvidence &&
          supportingText.length < 80 &&
          optional.length >= 80) {
        throw StateError(
            'This model has too little room for the source text. Shorten the chat instructions or increase the context size.');
      }
      prompt =
          supportingText.isEmpty ? required : '$required\n\n$supportingText';
    }
    final fittedHistory = List<Map<String, String>>.of(history);
    if (fittedHistory.lastOrNull?['role'] == 'user' &&
        fittedHistory.last['content'] == originalPrompt) {
      fittedHistory[fittedHistory.length - 1] = {
        'role': 'user',
        'content': prompt
      };
    } else {
      fittedHistory.add({'role': 'user', 'content': prompt});
    }
    fitToContext(system, fittedHistory, prompt, contextSize);
    return (system: system, prompt: prompt, history: fittedHistory);
  }

  /// Trims [hist] and [prompt] so the whole request fits the model's context
  /// with room left to answer; an overflow makes small models fail or go silent.
  /// Keeps the latest request intact; reports an oversized mandatory context.
  static String fitToContext(String system, List<Map<String, String>> hist,
      String prompt, int ctxTokens) {
    if (ctxTokens <= 0) return prompt;
    final budget = contextBudget(ctxTokens);
    int total() =>
        contextTokens(system) +
        hist.fold<int>(0, (a, m) => a + contextTokens(m['content'] ?? ''));
    // Strict chat templates require history to start with a user turn.
    while (hist.length > 1 && hist.first['role'] != 'user') {
      hist.removeAt(0);
    }
    while (total() > budget && hist.length > 1) {
      hist.removeAt(0);
      while (hist.length > 1 && hist.first['role'] != 'user') {
        hist.removeAt(0);
      }
    }
    // User instructions are mandatory: never silently crop the current request.
    if (total() > budget ||
        contextTokens(system) + contextTokens(prompt) > budget) {
      throw StateError(
          'The current instructions and message exceed this model’s context. Use @file: references for large documents, shorten the pinned rules, or increase context size.');
    }
    return prompt;
  }

  /// System prompt for a chat turn: the chat's own prompt, saved memory, and
  /// (when [withTools]) the tool instructions.
  String composeSystem(String base,
      {required bool withTools,
      String request = '',
      bool withFiles = false,
      int contextSize = 8192}) {
    final b = StringBuffer(base)
      ..write(
          '\n\nAnswer the user’s task directly. Use only available evidence for claims about files and current facts.');
    final mem = memoryBlock(request: request, maxTokens: contextSize ~/ 10);
    if (mem.isNotEmpty) b.write('\n\n$mem');
    if (withTools)
      b.write(
          '\n\n${toolPrompt(request: request, withFiles: withFiles, contextSize: contextSize)}');
    return b.toString();
  }

  void cancel() {
    _cancel = true;
    final inference = Get.find<InferenceService>();
    if (inference.isGenerating.value) inference.stopGeneration();
  }

  /// One chat turn with tools. [generate] runs the model (streaming tokens to
  /// the callback it is given); the loop calls it until the model answers
  /// without a tool call, or [maxSteps] is reached.
  ///
  /// [history] must end with the user's message (as the chat already builds it).
  Future<ToolLoopResult> runToolLoop({
    required Future<String> Function(String prompt,
            List<Map<String, String>> history, void Function(String) onToken)
        generate,
    required String prompt,
    required List<Map<String, String>> history,
    required ToolConfirm confirm,
    bool allowDirectActions = true,
    required void Function(String visible) onVisible,
    required void Function(String status) onStatus,
    required bool Function() cancelled,
    void Function(List<String> trace)? onTrace,
    String? researchQuestion,
    String? userText,
  }) async {
    _cancel = false;
    final hist = history.map((m) => Map<String, String>.from(m)).toList();
    if (hist.isNotEmpty && hist.last['role'] == 'user') {
      hist.last['content'] = prompt;
    }
    final trace = <String>[];
    final seen = <String>{};
    var current = prompt;
    var last = '';
    final sources = <WebResult>[];
    var ranTool = false;
    var nudges = 0;
    var contextCalls = 0;
    var contextMisses = 0;
    final request = userText ?? prompt;
    final speech = literalSpeechText(request);
    final fileName = namedWorkspaceFile(request);
    final directCall = speech != null
        ? ParsedToolCall(
            'text_to_speech',
            {
              'text': speech,
              'name': 'speech-${DateTime.now().microsecondsSinceEpoch}.wav',
            },
            '')
        : fileName != null
            ? ParsedToolCall(
                'write_file', {'name': fileName, 'create_empty': true}, '')
            : null;
    if (allowDirectActions && directCall != null && !cancelled()) {
      final tool = directCall.name;
      final args = directCall.arguments;
      final label =
          speech != null ? 'Creating an audio file' : stepLabel(tool, args);
      final timer = Stopwatch()..start();
      onTrace?.call([stepLine(tool, args, label, null, running: true)]);
      final result = await executeTool(directCall, confirm);
      final steps = [
        stepLine(tool, args, label, result, ms: timer.elapsedMilliseconds)
      ];
      onTrace?.call(steps);
      return ToolLoopResult(
        _autoLinkFiles(result.replaceFirst('Show it with ', ''), steps),
        steps,
        false,
      );
    }
    if (researchQuestion != null && !cancelled() && !_cancel) {
      final msg = await _autoResearch(
          researchQuestion, trace, onTrace, onStatus, sources, cancelled);
      if (msg == null && !cancelled() && !_cancel) {
        return ToolLoopResult(
            'Web search returned no usable sources. I couldn’t verify the answer.',
            trace,
            false);
      }
      if (msg != null) {
        ranTool = true;
        hist.add({
          'role': 'assistant',
          'content': '<tool_call>${jsonEncode({
                'name': 'web_search',
                'arguments': {'query': searchQuery(researchQuestion)}
              })}</tool_call>'
        });
        hist.add({'role': 'user', 'content': msg});
        current = msg;
      }
    }
    final printedToolNames = {for (final tool in _allBuiltIns) tool.name};
    for (var step = 0; step < maxSteps; step++) {
      if (cancelled() || _cancel) break;
      final buf = StringBuffer();
      var calling = false;
      last = await generate(current, hist, (tok) {
        buf.write(tok);
        final text = buf.toString();
        final i = text.indexOf('<tool_call>');
        if (i >= 0) {
          if (!calling) {
            calling = true;
            onStatus('Using a tool…');
          }
          onVisible(text.substring(0, i).trimRight());
        } else {
          // Hold back a partial opening tag so it never flashes on screen.
          final tail = text.lastIndexOf('<');
          final partial =
              tail >= 0 && '<tool_call>'.startsWith(text.substring(tail));
          onVisible(_stripPrintedTools(
              partial ? text.substring(0, tail) : text, printedToolNames));
        }
      });
      last = last.trim();
      if (cancelled() || _cancel) break;
      if (last.startsWith('ERROR:')) return ToolLoopResult(last, trace, false);
      final call = parseToolCall(last);
      if (call == null) {
        last = _stripPrintedTools(last, printedToolNames);
        if (nudges == 0 && !ranTool && isGenericOffer(last)) {
          nudges++;
          hist.add({'role': 'assistant', 'content': last});
          current =
              'Answer the original request directly. If an action is required, call the relevant tool. Ask only for information needed to proceed.';
          hist.add({'role': 'user', 'content': current});
          continue;
        }
        // The model answered without a tool. For action requests (make a file,
        // run a command) that usually means a small model is only describing
        // the work, so push it to actually do it.
        if (!ranTool && nudges < 2) {
          final n = _nudgeFor(request);
          if (n != null) {
            nudges++;
            onVisible('');
            onStatus('Making sure it is really done…');
            hist.add({'role': 'assistant', 'content': last});
            current = n;
            hist.add({'role': 'user', 'content': current});
            continue;
          }
        }
        if (!ranTool) {
          final fb =
              await _fallbackFile(request, last, confirm, trace, onTrace);
          if (fb != null) return fb;
        }
        if (last.trim().isEmpty && ranTool && nudges < 3) {
          // The model ran its tools and then said nothing: ask once more.
          nudges++;
          onStatus('Writing the answer…');
          hist.add({'role': 'assistant', 'content': '(no answer)'});
          current =
              'Write the final answer for the user now, in plain text, using the tool results above. Do not call a tool.';
          hist.add({'role': 'user', 'content': current});
          continue;
        }
        if (last.trim().isEmpty) {
          return ToolLoopResult(
              'The model produced no answer. This usually means the model ran out of memory or context. Try a smaller question, a new chat, or a lower context size in Settings.',
              trace,
              false);
        }
        return ToolLoopResult(
            _autoLinkFiles(_withSources(last, sources), trace), trace, false);
      }
      final contextCall =
          call.name == 'search_context' || call.name == 'read_context';
      final arguments = Map.fromEntries(call.arguments.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key)));
      final key = '${call.name}${jsonEncode(arguments)}';
      if (!seen.add(key) ||
          (contextCall &&
              (contextCalls >= 5 ||
                  contextMisses >= 2 ||
                  !printedToolNames.contains(call.name)))) {
        onVisible('');
        onStatus('Writing the answer…');
        final finalHistory = [
          ...hist,
          {'role': 'user', 'content': finalAnswerPrompt},
        ];
        final written = await generate(finalAnswerPrompt, finalHistory, (_) {});
        if (cancelled() || _cancel) return ToolLoopResult('', trace, false);
        final answer = _stripPrintedTools(
            parseToolCall(written)?.textBefore ?? stripCall(written),
            printedToolNames);
        return ToolLoopResult(
            _autoLinkFiles(
                _withSources(
                    answer.trim().isEmpty || isGenericOffer(answer)
                        ? 'I couldn’t finish the request with the information I found.'
                        : answer,
                    sources),
                trace),
            trace,
            false);
      }
      ranTool = true;
      final label = stepLabel(call.name, call.arguments);
      onStatus(label);
      final idx = trace.length;
      final sw = Stopwatch()..start();
      trace
          .add(stepLine(call.name, call.arguments, label, null, running: true));
      onTrace?.call(List.of(trace));
      final result = await executeTool(call, confirm);
      if (contextCall) {
        contextCalls++;
        if (result.startsWith('No ') ||
            result.startsWith('Error:') ||
            result.startsWith('Unknown ') ||
            result.startsWith('Select ')) contextMisses++;
      }
      trace[idx] = stepLine(call.name, call.arguments, label, result,
          ms: sw.elapsedMilliseconds);
      onTrace?.call(List.of(trace));
      hist.add({'role': 'assistant', 'content': last});
      current = 'Tool result for ${call.name}:\n$result\n\n'
          'Now either call another tool or give the final answer to the user\'s request.';
      hist.add({'role': 'user', 'content': current});
    }
    if (cancelled() || _cancel) {
      return ToolLoopResult(last.isEmpty ? '' : stripCall(last), trace, false);
    }
    return ToolLoopResult(
        'I used $maxSteps tool steps without reaching an answer. A small model may be too weak for this request; try a bigger model or a simpler request.',
        trace,
        true);
  }

  static final _genericOffer = RegExp(
      r'^(?:of course[!. ]*|sure[!. ]*)?i can (?:help|assist)(?: you)?(?: with (?:that|this|any questions or tasks[^.!?]*))?[.! ]*(?:if there[^.!?]*[.!?]|(?:feel free|please let me know)[^.!?]*[.!?])?$',
      caseSensitive: false);

  static bool isGenericOffer(String answer) =>
      _genericOffer.hasMatch(answer.trim());

  static final _printedTool = RegExp(r'^\s*([a-z][a-z_0-9]+)\s*\{[^\n]*\}\s*$');

  static String _stripPrintedTools(String reply, Set<String> names) {
    if (!reply.contains('{')) return reply;
    return reply
        .split('\n')
        .where((line) {
          final name = _printedTool.firstMatch(line)?.group(1);
          return name == null || !names.contains(name);
        })
        .join('\n')
        .trim();
  }

  static final _wantsFile = RegExp(
      r'(create|make|write|save|generate|put|store)\b[^\n]{0,80}(\bfile\b|\.[a-z0-9]{1,5}\b)|(اكتب|انشئ|أنشئ|اعمل|احفظ)[^\n]{0,60}(ملف|\.[a-z0-9]{2,5})',
      caseSensitive: false);
  static final _wantsAudioFile = RegExp(
    r'\b(?:tts|text.to.speech)\b[^\n]{0,80}\bfile\b|\b(create|make|generate|save)\b[^\n]{0,80}\b(audio file|wav file|voice recording|speech file)\b|(?:اعمل|انشئ|احفظ)[^\n]{0,60}ملف صوت',
    caseSensitive: false,
  );
  static final _wantsCmd = RegExp(
      r'\b(run|execute)\b[^\n]{0,60}\b(command|shell|terminal|script)\b|\b(ls|pip|npm|git|python|cat|mkdir|curl)\s',
      caseSensitive: false);
  static final _fileName = RegExp(
      r'([\w\-]+\.(?:txt|md|csv|json|html|css|py|js|ts|dart|xml|ya?ml|log|sh|java|kt|c|cpp|sql))\b',
      caseSensitive: false);

  String? _nudgeFor(String request) {
    final names = {for (final t in _allBuiltIns) t.name};
    if (_wantsAudioFile.hasMatch(request)) {
      return 'Use text_to_speech to create the audio file. Pass the requested text and a WAV name. '
          'Use models_status first if asked to choose a voice.';
    }
    if (_wantsFile.hasMatch(request) && names.contains('write_file')) {
      final fn = _fileName.firstMatch(request)?.group(1) ?? 'notes.txt';
      return 'You did not call a tool, so NO file was created — printing text in the chat saves nothing. '
          'Create it now by replying with ONLY this tool call (put the real content in "content"):\n'
          '<tool_call>{"name":"write_file","arguments":{"name":"$fn","content":"..."}}</tool_call>';
    }
    if (_wantsCmd.hasMatch(request) && names.contains('run_shell')) {
      return 'You did not call a tool, so nothing was run. Run it now by replying with ONLY: '
          '<tool_call>{"name":"run_shell","arguments":{"command":"..."}}</tool_call>';
    }
    return null;
  }

  /// Last resort for tiny models: they were asked to make a file and only
  /// printed its content, so save that content ourselves.
  Future<ToolLoopResult?> _fallbackFile(
      String request,
      String reply,
      ToolConfirm confirm,
      List<String> trace,
      void Function(List<String>)? onTrace) async {
    if (!_wantsFile.hasMatch(request) || _wantsAudioFile.hasMatch(request))
      return null;
    final fn = _fileName.firstMatch(request)?.group(1);
    if (fn == null) return null;
    var content = reply;
    final fence = RegExp(r'```[\w+\-]*\n([\s\S]*?)```').firstMatch(reply);
    if (fence != null) content = fence.group(1)!;
    content = content.trim();
    if (content.isEmpty || isGenericOffer(content)) return null;
    final args = <String, dynamic>{'name': fn, 'content': content};
    final label = stepLabel('write_file', args);
    final idx = trace.length;
    final sw = Stopwatch()..start();
    trace.add(stepLine('write_file', args, label, null, running: true));
    onTrace?.call(List.of(trace));
    final result =
        await executeTool(ParsedToolCall('write_file', args, ''), confirm);
    trace[idx] =
        stepLine('write_file', args, label, result, ms: sw.elapsedMilliseconds);
    onTrace?.call(List.of(trace));
    final ok = result.startsWith('Wrote');
    return ToolLoopResult(
        ok ? 'Done — I created **$fn**.\n\n[📎 $fn](nmfile:$fn)' : result,
        trace,
        false);
  }

  String _withSources(String answer, List<WebResult> sources) {
    if (sources.isEmpty || answer.contains('Sources:')) return answer;
    final b = StringBuffer(answer.trimRight())..write('\n\nSources:\n');
    for (var i = 0; i < sources.length; i++) {
      b.writeln(
          '${i + 1}. [${sources[i].title.replaceAll(RegExp(r'[\[\]]'), '')}](${sources[i].url})');
    }
    return b.toString().trimRight();
  }

  /// Files the agent wrote or spoke are linked in the answer even when the
  /// model forgot to mention them.
  String _autoLinkFiles(String answer, List<String> trace) {
    final extra = <String>[];
    for (final line in trace) {
      if (!line.startsWith(ToolLoopResult.traceMark)) continue;
      try {
        final m =
            jsonDecode(line.substring(ToolLoopResult.traceMark.length)) as Map;
        final n = m['n'];
        final res = '${m['r'] ?? ''}';
        final success = switch (n) {
          'write_file' => res.startsWith('Wrote '),
          'text_to_speech' => res.startsWith('Saved '),
          'append_file' => res.startsWith('Appended to '),
          'edit_file' => res.startsWith('Edited '),
          _ => false,
        };
        if (success) {
          final a = m['a'];
          var name = a is Map ? '${a['name'] ?? ''}' : '';
          if (n == 'text_to_speech' &&
              name.isNotEmpty &&
              !name.toLowerCase().endsWith('.wav')) {
            name = '$name.wav';
          }
          if (name.isNotEmpty &&
              !answer.contains('nmfile:$name') &&
              !extra.contains(name)) {
            extra.add(name);
          }
        }
      } catch (_) {}
    }
    if (extra.isEmpty) return answer;
    return '${answer.trimRight()}\n\n${extra.map((n) => '[📎 $n](nmfile:$n)').join('\n')}';
  }

  /// Searches the web for the question and reads the best pages, showing each
  /// step in the trace. Returns the message handed to the model, or null when
  /// nothing was found.
  Future<String?> _autoResearch(
      String question,
      List<String> trace,
      void Function(List<String>)? onTrace,
      void Function(String) onStatus,
      List<WebResult> sourcesOut,
      bool Function() cancelled) async {
    final web = Get.find<WebSearchService>();
    final fresh = web.freshnessFor(question);
    final all = <WebResult>[];
    for (final q in web.researchQueries(question).take(2)) {
      if (cancelled()) return null;
      final args = {'query': q};
      final label = stepLabel('web_search', args);
      onStatus(label);
      final idx = trace.length;
      final sw = Stopwatch()..start();
      trace.add(stepLine('web_search', args, label, null, running: true));
      onTrace?.call(List.of(trace));
      final r = await web.search(q, max: 6, freshness: fresh);
      all.addAll(r);
      trace[idx] = stepLine(
          'web_search',
          args,
          label,
          r.isEmpty
              ? 'No results.'
              : r.map((e) => '${e.title}\n${e.url}\n${e.snippet}').join('\n\n'),
          ms: sw.elapsedMilliseconds);
      onTrace?.call(List.of(trace));
    }
    final results = dedupeByHost(all, (r) => r.url).take(5).toList();
    if (results.isEmpty) return null;
    final query = searchQuery(question);
    final texts = <String>[];
    for (final r in results.take(2)) {
      if (cancelled()) return null;
      final args = {'url': r.url};
      final label = stepLabel('fetch_url', args);
      onStatus(label);
      final idx = trace.length;
      final sw = Stopwatch()..start();
      trace.add(stepLine('fetch_url', args, label, null, running: true));
      onTrace?.call(List.of(trace));
      final t = await web.pageText(r.url, query, maxChars: 1300);
      texts.add(t);
      trace[idx] = stepLine('fetch_url', args, label,
          t.isEmpty ? '(could not read this page)' : t,
          ms: sw.elapsedMilliseconds);
      onTrace?.call(List.of(trace));
    }
    sourcesOut.addAll(results);
    final b = StringBuffer(
        'Web research done for the user\'s question. Today is ${DateTime.now().toIso8601String().substring(0, 10)}.\n');
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      final body = i < texts.length && texts[i].length > r.snippet.length
          ? texts[i]
          : r.snippet;
      b.writeln('\n[${i + 1}] ${r.title} (${r.url})\n$body');
    }
    b.writeln(
        '\nAnswer in the user\'s language, specific (names, versions, dates, numbers from the sources), newest information first, cite [1]. '
        'If the sources lack the answer, search again with other words; do not guess.');
    return b.toString();
  }

  /// Human wording for what a tool call is doing right now.
  static String stepLabel(String name, Map<String, dynamic> a) {
    String q(String k) => (a[k] ?? '').toString();
    switch (name) {
      case 'web_search':
        return 'Searching the web: ${q('query')}';
      case 'fetch_url':
        return 'Reading ${q('url')}';
      case 'run_shell':
        return 'Running command: ${q('command')}';
      case 'install_packages':
        return 'Installing ${q('packages')}';
      case 'run_script':
        return 'Running a ${q('language')} script';
      case 'create_tool':
        return 'Creating my own tool: ${q('name')}';
      case 'sandbox_setup':
        return 'Setting up the Linux sandbox';
      case 'convert_file':
        return 'Converting ${q('name')} to ${q('output')}';
      case 'download_file':
        return 'Downloading ${q('url')}';
      case 'http_request':
        return '${q('method').isEmpty ? 'GET' : q('method')} ${q('url')}';
      case 'read_file':
      case 'read_user_file':
        return 'Reading ${q('name').isNotEmpty ? q('name') : q('path')}';
      case 'write_file':
      case 'write_user_file':
        return 'Writing ${q('name').isNotEmpty ? q('name') : q('path')}';
      case 'search_context':
        return 'Searching attached context';
      case 'read_context':
        return 'Reading attached context';
      case 'search_in_file':
        return 'Searching ${q('name')} for "${q('query')}"';
      case 'list_files':
      case 'list_folder':
        return 'Looking through files';
      case 'transcribe_audio':
        return 'Transcribing ${q('name')}';
      case 'text_to_speech':
        return 'Speaking to ${q('name')}';
      case 'generate_image':
        return 'Creating an image';
      case 'device_status':
        return 'Checking the phone status';
      case 'ask_user':
        return 'Asking you a question';
      case 'remember':
        return 'Saving to memory';
      case 'calculator':
        return 'Calculating ${q('expression')}';
      default:
        return 'Using $name';
    }
  }

  /// One saved trace line: the marker followed by a JSON step.
  static String stepLine(
      String name, Map<String, dynamic> args, String label, String? result,
      {bool running = false, int ms = 0}) {
    var r = result ?? '';
    if (r.length > 3000)
      r = '${r.substring(0, 3000)}\n… (${result!.length - 3000} more characters)';
    return '${ToolLoopResult.traceMark}${jsonEncode({
          'n': name,
          'l': label,
          'a': args,
          'r': r,
          'run': running,
          'ms': ms,
        })}';
  }

  static String stripCall(String reply) {
    final i = reply.indexOf('<tool_call>');
    return i < 0 ? reply : reply.substring(0, i).trim();
  }

  Future<String> _savePollinationsImage(PollinationsImage image, Object? name,
      {required bool edited}) async {
    var stem = name?.toString().trim() ?? '';
    stem = stem.replaceFirst(
        RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false), '');
    if (stem.isEmpty) stem = 'image_${DateTime.now().microsecondsSinceEpoch}';
    final file = await _safeFile('$stem.${image.extension}');
    await file.writeAsBytes(image.bytes);
    final filename = file.uri.pathSegments.last;
    return '${edited ? 'Edited' : 'Generated'} online with Pollinations (${image.model}).'
        '\n\n![${edited ? 'Edited' : 'Generated'} image](nmfile:$filename)';
  }

  /// Runs one tool call (asking the user first when required).
  Future<String> executeTool(ParsedToolCall call, ToolConfirm confirm,
      {bool userRequestedOnlineImage = false}) async {
    for (final t in _allBuiltIns) {
      if (t.name == call.name) {
        try {
          if (t.name == 'run_shell' &&
              Get.isRegistered<DesktopCommandService>()) {
            return await Get.find<DesktopCommandService>()
                .execute(call.arguments, filesDir, confirm);
          }
          final pol =
              policyFor('built-in', t.name, needsConfirm: t.needsConfirm);
          if (pol == 'block') return 'The user has blocked this tool.';
          final onlineImage =
              t.name == 'generate_image' || t.name == 'edit_image';
          final confirmationArgs = {...call.arguments}..remove('attachedImage');
          if ((pol == 'ask' || (onlineImage && !userRequestedOnlineImage)) &&
              !await confirm(t.name, 'built-in', confirmationArgs)) {
            return 'The user denied this tool call.';
          }
          final out = await t.run(call.arguments);
          return out.length > 6000
              ? '${out.substring(0, 6000)}\n…(truncated)'
              : out;
        } catch (e) {
          return 'Error: $e';
        }
      }
    }
    McpTool? tool;
    for (final t in _enabledMcpTools) {
      if (t.qualifiedName == call.name) tool = t;
    }
    if (tool == null) {
      return 'Error: unknown tool "${call.name}". Use only the listed tools.';
    }
    final cfg = servers.firstWhere((s) => s.id == tool!.serverId);
    final pol = policyFor(cfg.name, tool.name, needsConfirm: true);
    if (pol == 'block') return 'The user has blocked this tool.';
    if (pol == 'ask' && !await confirm(tool.name, cfg.name, call.arguments)) {
      return 'The user denied this tool call.';
    }
    final client = McpClient(cfg);
    try {
      final out = await client.callTool(tool.name, call.arguments);
      return out.length > 4000
          ? '${out.substring(0, 4000)}\n…(truncated)'
          : out;
    } catch (e) {
      return 'Error: $e';
    } finally {
      client.dispose();
    }
  }
}
