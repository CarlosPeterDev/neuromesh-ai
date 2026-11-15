import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../utils/bm25.dart';
import '../utils/page_text.dart';
import '../widgets/ask_user.dart';
import 'agent_tools.dart';
import 'device_bridge.dart';
import 'voice_service.dart';
import 'document_extractor_service.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'mcp_client.dart';
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

  String get markdown => trace.isEmpty ? answer : '${trace.join('\n')}\n\n$answer';
}

/// Removes tool-trace lines from a saved assistant message.
String stripToolTrace(String content) => content
    .split('\n')
    .where((l) => !l.startsWith(ToolLoopResult.traceMark))
    .join('\n')
    .trimLeft();

enum AgentChatMode { auto, always, off }

/// Lets the chat model use tools: files, memory, the web, MCP servers and
/// (in the Pro build) a Linux sandbox. It is part of normal chat: when the
/// model needs a tool it calls it, then keeps answering.
class AgentService extends GetxService {
  static const _serversKey = 'mcp_servers';
  static const _memoryKey = 'agent_memory';
  static const _allowKey = 'agent_always_allow'; // legacy, migrated
  static const _policyKey = 'agent_tool_policy';
  static const _modeKey = 'agent_chat_mode';
  static const _autoMemKey = 'agent_auto_memory';
  static const maxSteps = 14;
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

  Future<Directory> filesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/agent_files');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Only plain file names inside the agent folder are allowed.
  Future<File> _safeFile(String name) async {
    final n = name.split('/').last.split('\\').last;
    if (n.isEmpty || n.startsWith('.')) throw Exception('Invalid file name');
    return File('${(await filesDir()).path}/$n');
  }

  /// Copies a file the user attached into the workspace so tools can read it.
  /// Returns the name it can be read by.
  Future<String> importToWorkspace(String sourcePath, String name) async {
    var clean = name.split('/').last.split('\\').last.replaceAll(RegExp(r'[^\w.\- ]'), '_');
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
    if (await f.exists()) await f.delete();
  }

  // ── memory ───────────────────────────────────────────────────────────

  Future<void> addNote(String note) async {
    final n = note.trim();
    if (n.isEmpty) return;
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
            r'^\s*(?:please\s+)?(?:remember|note|save|keep in mind)(?:\s+that)?[\s:,-]+(.{3,300})$',
            caseSensitive: false,
            dotAll: true)
        .firstMatch(text);
    final ar = RegExp(r'^\s*(?:تذكر|افتكر|احفظ)(?:\s+إن|\s+ان|\s+أن)?[\s:،-]+(.{3,300})$',
            dotAll: true)
        .firstMatch(text);
    final note = (m ?? ar)?.group(1)?.trim();
    if (note == null || note.endsWith('?') || note.endsWith('؟')) return null;
    await addNote(note);
    return note;
  }

  Future<void> setAutoMemory(bool v) async {
    autoMemory.value = v;
    await _hive.setSetting(_autoMemKey, v);
  }

  /// Notes block added to the system prompt of every chat.
  String memoryBlock() {
    if (memory.isEmpty) return '';
    final b = StringBuffer('Things to remember about the user (saved by them or by you earlier):\n');
    for (final n in memory.reversed.take(25).toList().reversed) {
      b.writeln('- $n');
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

  // ── built-in tools ───────────────────────────────────────────────────

  UserFilesService? get _user =>
      Get.isRegistered<UserFilesService>() ? Get.find<UserFilesService>() : null;

  bool get _hasFolders => _user != null && _user!.folders.isNotEmpty;

  String _page(String text, int start, {int size = 4000}) {
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
        b.length >= m.length && List.generate(m.length, (i) => b[i] == m[i]).every((x) => x);
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
    if (ext == 'zip' || ext == 'jar' || ext == 'apk' || ext == 'xlsx' || ext == 'pptx') {
      final arch = ZipDecoder().decodeBytes(bytes);
      final b = StringBuffer('Archive with ${arch.files.length} entries:\n');
      for (final e in arch.files.take(200)) {
        b.writeln('${e.isFile ? '' : '[dir] '}${e.name}${e.isFile ? ' (${e.size} bytes)' : ''}');
      }
      return b.toString();
    }
    if (looksBinary(bytes)) {
      final head = bytes.take(48).map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
      return '(${_magic(bytes)}, ${bytes.length} bytes; not readable as text)\nFirst bytes: $head';
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  late final List<AgentTool> _builtIns = [
    AgentTool(
      'calculator',
      'Evaluate an arithmetic expression exactly.',
      '{"expression":"string, e.g. (12+3)*4/5"}',
      (args) => formatNumber(evaluateExpression((args['expression'] ?? '').toString())),
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
        await addNote((args['note'] ?? '').toString());
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
        return hits.isEmpty ? 'Nothing matched.' : 'Forgot ${hits.length} note(s).';
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
        String gb(num? b) => b == null ? '?' : '${(b / 1073741824).toStringAsFixed(1)} GB';
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
      'Turn a workspace audio file (mp3, m4a, ogg, wav, video) into text with the on-device speech model.',
      '{"name":"audio file name","language":"optional code such as en or ar"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found. Use list_files.';
        final t = await Get.find<VoiceService>()
            .transcribeFile(f.path, language: (args['language'] ?? '').toString());
        return t.isEmpty ? '(no speech found)' : _page(t, 0);
      },
    ),
    AgentTool(
      'text_to_speech',
      'Speak text with the on-device voice model and save it as a WAV file in the workspace. Show it to the user with [📎 name](nmfile:name).',
      '{"text":"string","name":"output file name ending in .wav"}',
      (args) async {
        var name = (args['name'] ?? 'speech.wav').toString();
        if (!name.toLowerCase().endsWith('.wav')) name = '$name.wav';
        final wav = await Get.find<VoiceService>().synthesizeToWav((args['text'] ?? '').toString());
        final f = await _safeFile(name);
        await f.writeAsBytes(wav);
        return 'Saved ${f.path.split('/').last} (${wav.length ~/ 1024} KB). Show it with [📎 ${f.path.split('/').last}](nmfile:${f.path.split('/').last}).';
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
        return top.map((i) => '[passage ${i + 1}/${chunks.length}]\n${chunks[i]}').join('\n\n');
      },
    ),
    AgentTool(
      'write_file',
      'Create or overwrite a text file in your workspace.',
      '{"name":"string","content":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        await f.writeAsString((args['content'] ?? '').toString());
        return 'Wrote ${f.path.split('/').last}.';
      },
    ),
    AgentTool(
      'list_folder',
      'List files and folders inside a folder the user shared with you.',
      '{"folder":"shared folder name","path":"optional sub-path"}',
      (args) async {
        final u = _user!;
        final f = u.find(args['folder']?.toString());
        if (f == null) return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        final items = await u.list(f, (args['path'] ?? '').toString());
        if (items.isEmpty) return '(empty)';
        return items.map((e) => '${e.isDir ? '[dir] ' : ''}${e.name}${e.isDir ? '' : ' (${e.size} bytes)'}').join('\n');
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
        if (f == null) return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        final start = int.tryParse('${args['start'] ?? 0}') ?? 0;
        final text = await u.readText(f, (args['path'] ?? '').toString(), maxChars: start + 4000);
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
        if (f == null) return 'Error: unknown folder. Shared folders: ${u.folders.map((x) => x.name).join(', ')}';
        await u.writeText(f, (args['path'] ?? '').toString(), (args['content'] ?? '').toString());
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
        final r = await Get.find<WebSearchService>().search((args['query'] ?? '').toString());
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
        if (res.statusCode != 200) return 'Error: server answered ${res.statusCode}.';
        final ct = res.headers['content-type'] ?? '';
        final body = utf8.decode(res.bodyBytes, allowMalformed: true);
        final text = ct.contains('html') ? readableText(body) : body;
        return _page(text, int.tryParse('${args['start'] ?? 0}') ?? 0);
      },
    ),
  ];

  /// Every built-in tool, including blocked or currently unavailable ones
  /// (for the permissions screen).
  List<AgentTool> get catalog => [..._builtIns, ..._extra];

  Iterable<AgentTool> get _allBuiltIns sync* {
    for (final t in [..._builtIns, ..._extra]) {
      if (policyFor('built-in', t.name, needsConfirm: t.needsConfirm) == 'block') continue;
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
      policy.addAll({for (final e in saved.entries) e.key.toString(): e.value.toString()});
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

  Future<void> setToolEnabled(String serverId, String tool, bool enabled) async {
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
      r'\b(file|files|folder|directory|document|attached|attachment|read|open|list|create|write|save|edit|search|look up|find|calculate|compute|remember|forget|note|run|execute|command|shell|script|install|deploy|build|github|repo|supabase|database|vercel|url|http|website|web ?page|download|time is it|date today|zip|pdf|csv|json)\b|مجلد|ملف|اقرا|افتح|احفظ|اكتب|ابحث|احسب|تذكر|انسى|شغل|نفذ|ارفع|حمل|موقع',
      caseSensitive: false);

  /// Whether this chat turn should offer tools to the model.
  bool wantsTools(String text, {bool hasFile = false}) {
    switch (mode.value) {
      case AgentChatMode.off:
        return false;
      case AgentChatMode.always:
        return true;
      case AgentChatMode.auto:
        if (hasFile) return true;
        if (_intent.hasMatch(text)) return true;
        for (final s in servers.where((s) => s.enabled)) {
          if (text.toLowerCase().contains(s.name.toLowerCase())) return true;
        }
        return false;
    }
  }

  /// Tool instructions appended to the chat's system prompt.
  String toolPrompt() {
    final b = StringBuffer()
      ..writeln('You can use tools to act on the user\'s request. To use a tool, reply with ONLY this and nothing else:')
      ..writeln('<tool_call>{"name":"TOOL_NAME","arguments":{...}}</tool_call>')
      ..writeln('Call one tool at a time and wait for its result. Use a tool only when it is needed; otherwise answer directly.')
      ..writeln('After you have the information you need, give the final answer in normal text.')
      ..writeln('For questions that need current or detailed facts, search more than once: run several web_search calls with different wording, then fetch_url the best pages before answering. Never repeat an identical call.')
      ..writeln()
      ..writeln('Tools:');
    for (final t in _allBuiltIns) {
      b.writeln('- ${t.name}: ${t.description} arguments: ${t.params}');
    }
    for (final t in _enabledMcpTools) {
      final d = t.description.replaceAll('\n', ' ');
      b.writeln('- ${t.qualifiedName}: ${d.length > 220 ? '${d.substring(0, 220)}…' : d} arguments: ${t.signature}');
    }
    if (_hasFolders) {
      b
        ..writeln()
        ..writeln('Shared folders: ${_user!.folders.map((f) => f.name).join(', ')}');
    }
    return b.toString().trimRight();
  }

  /// System prompt for a chat turn: the chat's own prompt, saved memory, and
  /// (when [withTools]) the tool instructions.
  String composeSystem(String base, {required bool withTools}) {
    final b = StringBuffer(base);
    final mem = memoryBlock();
    if (mem.isNotEmpty) b.write('\n\n$mem');
    if (withTools) b.write('\n\n${toolPrompt()}');
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
    required void Function(String visible) onVisible,
    required void Function(String status) onStatus,
    required bool Function() cancelled,
    void Function(List<String> trace)? onTrace,
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
          final partial = tail >= 0 && '<tool_call>'.startsWith(text.substring(tail));
          onVisible(partial ? text.substring(0, tail) : text);
        }
      });
      last = last.trim();
      if (cancelled() || _cancel) break;
      if (last.startsWith('ERROR:')) return ToolLoopResult(last, trace, false);
      final call = parseToolCall(last);
      if (call == null) return ToolLoopResult(last, trace, false);

      final label = stepLabel(call.name, call.arguments);
      onStatus(label);
      final key = '${call.name}${jsonEncode(call.arguments)}';
      final idx = trace.length;
      final sw = Stopwatch()..start();
      trace.add(stepLine(call.name, call.arguments, label, null, running: true));
      onTrace?.call(List.of(trace));
      String result;
      if (!seen.add(key)) {
        result = 'You already ran this exact call. Use a different query or argument, or answer now.';
      } else {
        result = await executeTool(call, confirm);
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
      case 'read_file':
      case 'read_user_file':
        return 'Reading ${q('name').isNotEmpty ? q('name') : q('path')}';
      case 'write_file':
      case 'write_user_file':
        return 'Writing ${q('name').isNotEmpty ? q('name') : q('path')}';
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
  static String stepLine(String name, Map<String, dynamic> args, String label, String? result,
      {bool running = false, int ms = 0}) {
    var r = result ?? '';
    if (r.length > 3000) r = '${r.substring(0, 3000)}\n… (${result!.length - 3000} more characters)';
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

  /// Runs one tool call (asking the user first when required).
  Future<String> executeTool(ParsedToolCall call, ToolConfirm confirm) async {
    for (final t in _allBuiltIns) {
      if (t.name == call.name) {
        try {
          final pol = policyFor('built-in', t.name, needsConfirm: t.needsConfirm);
          if (pol == 'block') return 'The user has blocked this tool.';
          if (pol == 'ask' && !await confirm(t.name, 'built-in', call.arguments)) {
            return 'The user denied this tool call.';
          }
          final out = await t.run(call.arguments);
          return out.length > 6000 ? '${out.substring(0, 6000)}\n…(truncated)' : out;
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
      return out.length > 4000 ? '${out.substring(0, 4000)}\n…(truncated)' : out;
    } catch (e) {
      return 'Error: $e';
    } finally {
      client.dispose();
    }
  }
}
