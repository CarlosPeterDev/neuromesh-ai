import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'web_search_service.dart';

import 'agent_tools.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'mcp_client.dart';

class AgentEvent {
  /// 'task', 'model', 'tool_call', 'tool_result', 'answer', 'info', 'error'
  final String kind;
  final String text;
  AgentEvent(this.kind, this.text);
}

/// Asks the user whether a tool may run. Returns true to allow.
typedef ToolConfirm = Future<bool> Function(
    String toolName, String serverName, Map<String, dynamic> args);

class _BuiltIn {
  final String name;
  final String description;
  final String params;
  final FutureOr<String> Function(Map<String, dynamic> args) run;
  /// Reaches outside the app's own data (network), so ask first.
  final bool needsConfirm;
  const _BuiltIn(this.name, this.description, this.params, this.run,
      {this.needsConfirm = false});
}

/// Runs a multi-step task: the local model may call built-in tools or tools
/// from linked MCP servers. MCP tools always need the user's confirmation.
class AgentService extends GetxService {
  static const _serversKey = 'mcp_servers';
  static const _memoryKey = 'agent_memory';
  static const _allowKey = 'agent_always_allow';
  static const maxSteps = 6;

  final HiveService _hive = Get.find<HiveService>();

  final servers = <McpServerConfig>[].obs;
  final serverStatus = <String, String>{}.obs;
  final _tools = <String, List<McpTool>>{};
  final events = <AgentEvent>[].obs;
  final isRunning = false.obs;
  final memory = <String>[].obs;
  final alwaysAllow = <String>{}.obs;
  bool _cancel = false;

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

  Future<void> addNote(String note) async {
    final n = note.trim();
    if (n.isEmpty) return;
    memory.add(n);
    if (memory.length > 30) memory.removeAt(0);
    await _hive.setSetting(_memoryKey, memory.toList());
  }

  Future<void> clearMemory() async {
    memory.clear();
    await _hive.setSetting(_memoryKey, <String>[]);
  }

  Future<void> allowAlwaysFor(String server, String tool) async {
    alwaysAllow.add('$server::$tool');
    await _hive.setSetting(_allowKey, alwaysAllow.toList());
  }

  Future<void> revokeAlways() async {
    alwaysAllow.clear();
    await _hive.setSetting(_allowKey, <String>[]);
  }

  late final List<_BuiltIn> _builtIns = [
    _BuiltIn(
      'calculator',
      'Evaluate an arithmetic expression exactly.',
      '{"expression":"string, e.g. (12+3)*4/5"}',
      (args) {
        final expr = (args['expression'] ?? '').toString();
        return formatNumber(evaluateExpression(expr));
      },
    ),
    _BuiltIn(
      'current_time',
      'Get the phone\'s current local date and time.',
      '{}',
      (args) => DateTime.now().toString(),
    ),
    _BuiltIn(
      'remember',
      'Save a short note that you can recall in later tasks.',
      '{"note":"string"}',
      (args) async {
        await addNote((args['note'] ?? '').toString());
        return 'Saved.';
      },
    ),
    _BuiltIn(
      'list_files',
      'List files in the agent\'s private folder.',
      '{}',
      (args) async {
        final names = (await filesDir())
            .listSync()
            .whereType<File>()
            .map((f) => f.path.split('/').last)
            .toList();
        return names.isEmpty ? '(no files)' : names.join('\n');
      },
    ),
    _BuiltIn(
      'read_file',
      'Read a text file from the agent\'s private folder.',
      '{"name":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        if (!await f.exists()) return 'Error: file not found.';
        final t = await f.readAsString();
        return t.length > 4000 ? '${t.substring(0, 4000)}\n…(truncated)' : t;
      },
    ),
    _BuiltIn(
      'write_file',
      'Write a text file into the agent\'s private folder.',
      '{"name":"string","content":"string"}',
      (args) async {
        final f = await _safeFile((args['name'] ?? '').toString());
        await f.writeAsString((args['content'] ?? '').toString());
        return 'Wrote ${f.path.split('/').last}.';
      },
    ),
    _BuiltIn(
      'web_search',
      'Search the web and return the top results (title, url, snippet).',
      '{"query":"string"}',
      (args) async {
        final r = await Get.find<WebSearchService>()
            .search((args['query'] ?? '').toString());
        if (r.isEmpty) return 'No results.';
        return r.map((e) => '${e.title}\n${e.url}\n${e.snippet}').join('\n\n');
      },
      needsConfirm: true,
    ),
    _BuiltIn(
      'fetch_url',
      'Download a web page and return its text (first 4000 characters).',
      '{"url":"https://..."}',
      (args) async {
        final uri = Uri.tryParse((args['url'] ?? '').toString());
        if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
          return 'Error: give a full http(s) URL.';
        }
        final res = await http.get(uri).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) return 'Error: server answered ${res.statusCode}.';
        final text = res.body
            .replaceAll(RegExp(r'<script[\s\S]*?</script>|<style[\s\S]*?</style>'), ' ')
            .replaceAll(RegExp(r'<[^>]+>'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        return text.length > 4000 ? '${text.substring(0, 4000)}…' : text;
      },
      needsConfirm: true,
    ),
  ];

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
    alwaysAllow.value = (_hive.getSetting<List>(_allowKey) ?? const [])
        .map((e) => e.toString())
        .toSet();
  }

  Future<void> _saveServers() =>
      _hive.setSetting(_serversKey, servers.map((s) => s.toMap()).toList());

  Future<void> addServer(String name, String url, String token) async {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final cfg = McpServerConfig(id: id, name: name.trim(), url: url.trim(), token: token.trim());
    servers.add(cfg);
    await _saveServers();
    await refreshServer(cfg);
  }

  Future<void> removeServer(String id) async {
    servers.removeWhere((s) => s.id == id);
    _tools.remove(id);
    serverStatus.remove(id);
    await _saveServers();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = servers.indexWhere((s) => s.id == id);
    if (i < 0) return;
    servers[i] = servers[i].copyWith(enabled: enabled);
    await _saveServers();
  }

  /// Connects to the server and lists its tools; updates [serverStatus].
  Future<void> refreshServer(McpServerConfig cfg) async {
    serverStatus[cfg.id] = 'Connecting…';
    final client = McpClient(cfg);
    try {
      final tools = await client.listTools();
      _tools[cfg.id] = tools;
      serverStatus[cfg.id] = 'Connected · ${tools.length} tool${tools.length == 1 ? '' : 's'}';
    } catch (e) {
      _tools.remove(cfg.id);
      serverStatus[cfg.id] = e.toString();
    } finally {
      client.dispose();
    }
  }

  List<McpTool> toolsOf(String id) => _tools[id] ?? const [];

  Iterable<McpTool> get _enabledMcpTools sync* {
    for (final s in servers.where((s) => s.enabled)) {
      yield* toolsOf(s.id);
    }
  }

  String _systemPrompt() {
    final b = StringBuffer()
      ..writeln('You are an assistant that can use tools to complete the user\'s task.')
      ..writeln('To use a tool, reply with ONLY this and nothing else:')
      ..writeln('<tool_call>{"name":"TOOL_NAME","arguments":{...}}</tool_call>')
      ..writeln('Call one tool at a time. You will then receive the result.')
      ..writeln('Use a tool only when it is needed. When you have what you need, answer the user directly without a tool call.')
      ..writeln()
      ..writeln('Available tools:');
    for (final t in _builtIns) {
      b.writeln('- ${t.name}: ${t.description} arguments: ${t.params}');
    }
    for (final t in _enabledMcpTools) {
      final schema = jsonEncode(t.inputSchema['properties'] ?? {});
      final shortSchema = schema.length > 600 ? '${schema.substring(0, 600)}…' : schema;
      b.writeln('- ${t.qualifiedName}: ${t.description.replaceAll('\n', ' ')} arguments: $shortSchema');
    }
    if (memory.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Notes you saved earlier:');
      for (final n in memory) {
        b.writeln('- $n');
      }
    }
    return b.toString();
  }

  void cancel() {
    _cancel = true;
    final inference = Get.find<InferenceService>();
    if (inference.isGenerating.value) inference.stopGeneration();
  }

  Future<void> run(String task, ToolConfirm confirm) async {
    if (isRunning.value) return;
    final inference = Get.find<InferenceService>();
    events.clear();
    events.add(AgentEvent('task', task));
    if (!inference.isModelLoaded.value) {
      events.add(AgentEvent('error', 'Load a local model first (Models tab).'));
      return;
    }
    isRunning.value = true;
    _cancel = false;
    final history = <Map<String, String>>[];
    var prompt = task;
    final system = _systemPrompt();
    try {
      for (var step = 0; step < maxSteps; step++) {
        if (_cancel) break;
        final reply = (await inference.generate(
          prompt: prompt,
          systemPrompt: system,
          conversationHistory: history,
          source: 'agent',
          maxTokens: 700,
        ))
            .trim();
        if (_cancel) break;
        if (reply.startsWith('ERROR:')) {
          events.add(AgentEvent('error', reply));
          break;
        }
        final call = parseToolCall(reply);
        if (call == null) {
          events.add(AgentEvent('answer', reply));
          return;
        }
        if (call.textBefore.isNotEmpty) events.add(AgentEvent('model', call.textBefore));
        events.add(AgentEvent('tool_call', '${call.name} ${jsonEncode(call.arguments)}'));
        final result = await _execute(call, confirm);
        events.add(AgentEvent('tool_result', result));
        history
          ..add({'role': 'user', 'content': prompt})
          ..add({'role': 'assistant', 'content': reply});
        prompt = 'Tool result for ${call.name}:\n$result\n\n'
            'Now either call another tool or give the final answer to: $task';
      }
      if (_cancel) {
        events.add(AgentEvent('info', 'Stopped.'));
      } else {
        events.add(AgentEvent('info',
            'Stopped after $maxSteps steps without a final answer. A small model may be too weak for this task.'));
      }
    } catch (e) {
      events.add(AgentEvent('error', e.toString()));
    } finally {
      isRunning.value = false;
    }
  }

  Future<String> _execute(ParsedToolCall call, ToolConfirm confirm) async {
    for (final t in _builtIns) {
      if (t.name == call.name) {
        try {
          if (t.needsConfirm &&
              !alwaysAllow.contains('built-in::${t.name}') &&
              !await confirm(t.name, 'built-in', call.arguments)) {
            return 'The user denied this tool call.';
          }
          return await t.run(call.arguments);
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
    final allowed = alwaysAllow.contains('${cfg.name}::${tool.name}') ||
        await confirm(tool.name, cfg.name, call.arguments);
    if (!allowed) return 'The user denied this tool call.';
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
